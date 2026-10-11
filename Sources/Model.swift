import AppKit
import Foundation
import SwiftUI

struct SessionEvent: Decodable {
    let event: String
    let tool: String?
    let target: String?
    let desc: String?
    let cwd: String?
}

enum Mood: String, CaseIterable, Hashable {
    case idle, working, attention, done, sleeping
}

/// Which coding agent a session belongs to. Cursor sessions are written by the Cursor bridge
/// with a "cursor-" file name prefix; everything else comes from Claude Code.
enum Agent: Equatable {
    case claude, cursor

    init(sessionFile url: URL) {
        self = url.lastPathComponent.hasPrefix("cursor-") ? .cursor : .claude
    }

    var name: String { self == .cursor ? "Cursor" : "Claude" }

    /// A generic SF Symbol shown in the bubble (not a brand logo).
    var icon: String { self == .cursor ? "cursorarrow.rays" : "sparkle" }

    /// Whole-body colors while this agent is working or in front (Claude keeps your own colors).
    static let cursorBody = RGB(hex: "4A8FE7")!
    static let cursorLimb = RGB(hex: "2F67B8")!

    /// Bubble icon and antenna color while this agent works.
    var tint: Color {
        self == .cursor ? Color(red: 0.25, green: 0.65, blue: 1.0)   // blue for Cursor
                        : Color(red: 0.90, green: 0.50, blue: 0.30)  // warm orange for Claude
    }
}

enum ReactionKind: CaseIterable {
    case spin, backflip, boing, wave, giggle, dizzy

    var duration: Double {
        switch self {
        case .spin: 1.2
        case .backflip: 1.1
        case .boing: 1.1
        case .wave: 1.5
        case .giggle: 1.3
        case .dizzy: 2.0
        }
    }

    /// A different tap reaction than last time; dizzy is saved for rapid-fire clicking.
    static func random(excluding last: ReactionKind?) -> ReactionKind {
        allCases.filter { $0 != .dizzy && $0 != last }.randomElement() ?? .spin
    }
}

struct Reaction {
    let kind: ReactionKind
    let elapsed: Double
}

@MainActor
final class BuddyModel: ObservableObject {
    @Published private(set) var mood: Mood = .idle
    /// Projects Claude is working in right now, most recent first.
    @Published private(set) var projects: [String] = []
    /// Agents working right now, most recent first.
    @Published private(set) var agents: [Agent] = []
    /// The agent that finished most recently (for the "done" bubble).
    @Published private(set) var doneAgent: Agent = .claude
    /// Cursor when it's the app you're using right now, else nil.
    @Published private(set) var focusAgent: Agent?
    /// Voice conversation with you (listening / thinking / answering).
    @Published private(set) var voice: VoiceState = .off

    /// Pupil offset toward the cursor, updated by the app delegate.
    var cursorLook = CGSize.zero

    private let settings: BuddySettings
    private var phrase: String?
    private var phraseUntil = Date.distantPast
    private var reactionStart = Date.distantPast
    private var reactionKind = ReactionKind.spin
    private var clickTimes: [Date] = []

    private var lastActivity = Date()
    private var newestStopSeen = Date.distantPast
    private var doneUntil = Date.distantPast

    private let sessionsDir = ClaudeHooks.sessionsDir

    init(settings: BuddySettings) {
        self.settings = settings
    }

    /// Reads the per-session state files written by the Claude Code hook.
    func refresh() {
        let now = Date()
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let filter = settings.projectFilter.trimmingCharacters(in: .whitespaces)

        var working: [(Date, SessionEvent, Agent)] = []
        var waiting = false
        var newestStop = Date.distantPast
        var newestStopAgent = Agent.claude

        for url in files where url.pathExtension == "json" {
            guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { continue }
            let age = now.timeIntervalSince(mtime)
            if age > 86_400 {
                try? fm.removeItem(at: url)
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let ev = try? JSONDecoder().decode(SessionEvent.self, from: data) else { continue }
            if !filter.isEmpty, !(ev.cwd ?? "").localizedCaseInsensitiveContains(filter) { continue }

            lastActivity = max(lastActivity, mtime)
            let agent = Agent(sessionFile: url)

            // Stop doesn't fire when a turn is interrupted, so "working" goes stale after a while.
            let staleAfter: TimeInterval? = switch ev.event {
            case "PreToolUse": 900
            case "UserPromptSubmit", "PostToolUse", "PostToolUseFailure": 300
            default: nil
            }
            if let staleAfter, age < staleAfter {
                working.append((mtime, ev, agent))
            } else if ev.event == "PermissionRequest", age < 900 {
                waiting = true
            } else if ev.event == "Stop" {
                if mtime > newestStop { newestStop = mtime; newestStopAgent = agent }
            }
        }

        if newestStop > newestStopSeen {
            if settings.celebrate, now.timeIntervalSince(newestStop) < 5 {
                doneUntil = now.addingTimeInterval(3.5)
            }
            newestStopSeen = newestStop
            if doneAgent != newestStopAgent { doneAgent = newestStopAgent }
            if settings.speakAloud, voice == .off, now.timeIntervalSince(newestStop) < 5 {
                Speaker.shared.say("\(newestStopAgent.name) is done!")
            }
        }

        let newMood: Mood
        if waiting {
            newMood = .attention
        } else if !working.isEmpty {
            newMood = .working
        } else if now < doneUntil {
            newMood = .done
        } else if settings.sleepEnabled, now.timeIntervalSince(lastActivity) > settings.sleepMinutes * 60 {
            newMood = .sleeping
        } else {
            newMood = .idle
        }

        var newProjects: [String] = []
        var newAgents: [Agent] = []
        for (_, ev, agent) in working.sorted(by: { $0.0 > $1.0 }) {
            if !newAgents.contains(agent) { newAgents.append(agent) }
            let name = ((ev.cwd ?? "") as NSString).lastPathComponent
            if !name.isEmpty, !newProjects.contains(name) { newProjects.append(name) }
        }
        if settings.speakAloud, voice == .off, newMood != mood {
            if newMood == .attention {
                Speaker.shared.say("Claude needs your OK!")
            } else if newMood == .working, mood != .attention, settings.announceStart, let lead = newAgents.first {
                if let project = newProjects.first {
                    Speaker.shared.say("\(lead.name) is working on \(project)")
                } else {
                    Speaker.shared.say("\(lead.name) is working")
                }
            }
        }
        if mood != newMood { mood = newMood }
        if projects != newProjects { projects = newProjects }
        if agents != newAgents { agents = newAgents }

        let front = NSWorkspace.shared.frontmostApplication
        let cursorInFront = front?.localizedName == "Cursor"
            || front?.bundleIdentifier == "com.todesktop.230313mzl4w4u92"
        let newFocus: Agent? = cursorInFront ? .cursor : nil
        if focusAgent != newFocus { focusAgent = newFocus }
    }

    /// Which agent's look the buddy wears: whoever is working, whoever just finished,
    /// otherwise Cursor while you're using it.
    var themeAgent: Agent? {
        if let working = agents.first { return working }
        if mood == .done { return doneAgent }
        return focusAgent
    }

    func setVoice(_ state: VoiceState) {
        if voice != state { voice = state }
        lastActivity = Date()   // a chat keeps the buddy awake
    }

    /// Called when the buddy is clicked.
    func poke() {
        let now = Date()
        let wasSleeping = mood == .sleeping
        lastActivity = now
        if wasSleeping { mood = .idle }
        guard settings.clickReactions else { return }

        clickTimes = clickTimes.filter { now.timeIntervalSince($0) < 2 } + [now]
        reactionKind = clickTimes.count >= 5 ? .dizzy : .random(excluding: reactionKind)
        reactionStart = now

        let lines: [String]
        if reactionKind == .dizzy {
            lines = ["Whoa, too many boops!", "The room is spinning…", "Okay okay, I'm awake!"]
        } else if wasSleeping {
            lines = ["Huh? I'm up! I'm up!", "Five more minutes…", "*yawn* Hi!"]
        } else if mood == .working {
            lines = ["Shh, Claude's cooking!", "Working on it…", "Almost there, probably!", "Watching every keystroke 👀"]
        } else if mood == .attention {
            lines = ["Claude needs your OK!", "Check the terminal 👉"]
        } else if !settings.phrases.isEmpty {
            lines = settings.phrases
        } else {
            lines = ["Hi there! 👋", "Boop!", "Hehe, that tickles", "Ship it! 🚀", "Need a break? ☕️",
                     "I believe in you!", "*happy wiggle*", "What are we building?"]
        }
        phrase = lines.randomElement()
        if settings.speakAloud, let phrase { Speaker.shared.say(phrase) }
        phraseUntil = now.addingTimeInterval(2.5)
    }

    func reaction(at date: Date) -> Reaction? {
        let elapsed = date.timeIntervalSince(reactionStart)
        return elapsed < reactionKind.duration ? Reaction(kind: reactionKind, elapsed: elapsed) : nil
    }

    func activePhrase(at date: Date) -> String? {
        date < phraseUntil ? phrase : nil
    }
}
