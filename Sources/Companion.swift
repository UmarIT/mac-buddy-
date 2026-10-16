import AppKit

/// Makes the buddy start talking by itself, like a friend sitting next to you: it greets you,
/// reacts to what you're watching or doing, reminds you to take breaks, and tells you to sleep when
/// it's very late. Gemini writes each line fresh (with a built-in line as backup), and when a line
/// asks you something, the buddy listens for your reply.
@MainActor
final class Companion {
    private let model: BuddyModel
    private let settings: BuddySettings
    private let voice: VoiceBuddy

    private var lastSpoke = Date()                 // don't chat right after launch… the greeting handles that
    private var lastTopic = ""                     // what it last commented on
    private var topicSince = Date()
    private var candidateTopic = ""
    private var activeSince = Date()               // for break reminders
    private var lastBreakReminder = Date()
    private var lastLateNight = Date.distantPast
    private var lastMood: Mood = .idle
    private var waitingForGemini = false

    private lazy var name: String = NSFullUserName().split(separator: " ").first.map(String.init) ?? "friend"

    init(model: BuddyModel, settings: BuddySettings, voice: VoiceBuddy) {
        self.model = model
        self.settings = settings
        self.voice = voice
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.greet(back: true) }
        }
    }

    /// Minimum seconds between things it says on its own.
    private var gap: TimeInterval {
        switch settings.chattiness {
        case 1: return 30 * 60   // now and then
        case 3: return 5 * 60    // chatty
        default: return 15 * 60  // normal
        }
    }

    private var enabled: Bool { settings.chattiness > 0 }

    // MARK: Greeting

    private var lastGreeting = Date.distantPast

    func greet(back: Bool = false) {
        guard enabled, Date().timeIntervalSince(lastGreeting) > 3 * 3600 else { return }   // at most every 3 hours
        lastGreeting = Date()
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "morning" : hour < 17 ? "afternoon" : "evening"
        let fallback = back ? "Welcome back, \(name)! I missed you." : "Good \(part), \(name)! I'm right here if you need me."
        say(event: back ? "\(name) just came back to the Mac after a break." : "\(name) just turned on the Mac. It's the \(part).",
            fallback: fallback, asks: false, force: true)
    }

    // MARK: Called every few seconds

    func tick() {
        guard enabled, !voice.isBusy, !waitingForGemini else { return }
        guard !inACall else { return }

        let now = Date()
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle > 5 * 60 { activeSince = now }   // you stepped away: the work clock starts over
        guard idle < 120 else { return }          // don't talk to an empty room

        // A coding agent just finished.
        if model.mood == .done, lastMood != .done {
            lastMood = model.mood
            say(event: "", fallback: "\(model.doneAgent.name) is done, \(name)!", asks: false, force: true, useGemini: false)
            return
        }
        lastMood = model.mood

        // Never talk over Quran recitation.
        if case .quran? = model.vibe { return }

        // Very late at night (once a night).
        let hour = Calendar.current.component(.hour, from: now)
        if (1...4).contains(hour), now.timeIntervalSince(lastLateNight) > 6 * 3600, now.timeIntervalSince(lastSpoke) > gap {
            lastLateNight = now
            say(event: "It's \(hour) at night and \(name) is still on the Mac.",
                fallback: "It's really late, \(name). Maybe get some sleep soon?", asks: true)
            return
        }

        // Long stretch of work: suggest a break.
        if now.timeIntervalSince(activeSince) > 55 * 60, now.timeIntervalSince(lastBreakReminder) > 55 * 60 {
            lastBreakReminder = now
            activeSince = now
            say(event: "\(name) has been working on the Mac for about an hour without a break.",
                fallback: "You've been at it for an hour, \(name). Stretch a little and drink some water?", asks: true)
            return
        }

        // Something new on screen: comment once it has stayed for a few seconds.
        guard let current = currentTopic() else { return }
        let (topic, event, fallback, asks) = current
        if topic != candidateTopic {
            candidateTopic = topic
            topicSince = now
            return
        }
        guard topic != lastTopic, now.timeIntervalSince(topicSince) > 8, now.timeIntervalSince(lastSpoke) > gap else { return }
        lastTopic = topic
        say(event: event, fallback: fallback, asks: asks)
    }

    // MARK: What's going on

    /// (topic key, what happened for Gemini, backup line, does it invite a reply)
    private func currentTopic() -> (String, String, String, Bool)? {
        guard model.mood == .idle || model.mood == .sleeping, let vibe = model.vibe else { return nil }
        let title = model.nowPlaying ?? ""
        switch vibe {
        case .quran:
            return nil
        case .sad:
            return ("sad:\(title)", "\(name) is listening to a sad song: \(title).",
                    "That's a sad one, \(name). Everything okay?", true)
        case .romantic:
            return ("romantic:\(title)", "\(name) is listening to a romantic song: \(title).",
                    "Ooh, a love song! Thinking about someone special, \(name)?", true)
        case .happy:
            return ("happy:\(title)", "\(name) is playing an upbeat party song: \(title).",
                    "This one's a banger! Let's dance, \(name)!", false)
        case .groove:
            return nil   // any song: just nod along, no need to talk
        case .sport(let sport):
            return ("sport:\(sport.name)", "\(name) is watching \(sport.name): \(title).",
                    "Ooh, \(sport.name)! Who do you think will win, \(name)?", true)
        case .work(_):
            return nil   // don't interrupt work
        case .browse(let kind, let site):
            switch kind {
            case .food:
                return ("browse:\(site)", "\(name) is looking at food on \(site).", "Food time! What are you ordering, \(name)?", true)
            case .movie:
                return ("browse:\(site)", "\(name) opened \(site) to watch something.", "Movie time! What are we watching, \(name)?", true)
            case .travel:
                return ("browse:\(site)", "\(name) is planning travel on \(site).", "Planning a trip, \(name)? Where to?", true)
            case .social, .shopping, .news, .learning, .games, .chat, .search, .money, .other:
                return nil   // too frequent or private to comment on
            }
        }
    }

    /// Calls and meetings: stay silent.
    private var inACall: Bool {
        let callApps: Set<String> = ["us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime",
                                     "com.cisco.webexmeetingsapp", "com.hnc.Discord"]
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        return callApps.contains(front)
    }

    // MARK: Saying it

    private func say(event: String, fallback: String, asks: Bool, force: Bool = false, useGemini: Bool = true) {
        guard force || Date().timeIntervalSince(lastSpoke) > gap else { return }
        lastSpoke = Date()
        guard useGemini, settings.geminiRemarks, !event.isEmpty else {
            voice.speakUp(fallback, invitesReply: asks)
            return
        }
        waitingForGemini = true
        let prompt = """
        You are Mac Buddy, a cute little companion who lives on \(name)'s Mac screen and is their close, caring friend. \
        Something just happened: \(event) \
        Say ONE short, warm, casual sentence to \(name) about it, like a friend sitting next to them \
        (at most 18 words, no emoji, no quotes, no markdown). \
        \(asks ? "End with a light, friendly question." : "Don't ask a question.") \
        \(Lingo.rules(settings.language == "auto" ? "en" : settings.language))
        Reply with only that sentence\(settings.language == "en" || settings.language == "auto" ? "" : " (in the SHOW/SAY format)").
        """
        let finish: @MainActor (String?) -> Void = { [weak self] line in
            guard let self else { return }
            self.waitingForGemini = false
            let text = (line?.isEmpty == false && line!.count < 600) ? line! : fallback
            self.voice.speakUp(text, invitesReply: asks || text.hasSuffix("?"))
        }
        if FastGemini.isAvailable {
            Task { finish(await FastGemini.oneShot(prompt)) }   // about a second
        } else {
            voice.gemini.remark(prompt, completion: finish)
        }
    }
}
