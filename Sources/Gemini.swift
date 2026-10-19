import Foundation

/// The buddy's brain: Google's Antigravity CLI (`agy`), signed in with your Google account, so it
/// uses your Gemini plan (Google AI Pro). It answers questions and, when allowed, runs commands on
/// this Mac to do what you asked. Follow-ups continue the same conversation for 15 minutes.
@MainActor
final class GeminiBrain {
    private var conversationID: String?
    private var conversationWithCursor = false
    private var lastUsed = Date.distantPast
    private var current: GeminiJob?

    /// `cursor`: use the Cursor agent (your Cursor plan) instead of Antigravity.
    func ask(_ request: String, canAct: Bool, language: String, cursor: Bool = false, cursorModel: String = "",
             completion: @escaping @MainActor (String) -> Void) {
        if Date().timeIntervalSince(lastUsed) > 15 * 60 || conversationWithCursor != cursor { conversationID = nil }
        conversationWithCursor = cursor
        lastUsed = Date()
        current?.cancel()
        let job = GeminiJob(request: request, conversation: conversationID, canAct: canAct, language: language,
                            cursor: cursor, cursorModel: cursorModel)
        current = job
        Task.detached {
            let reply = job.run()
            await MainActor.run {
                guard self.current === job else { return }   // cancelled or replaced
                self.current = nil
                self.conversationID = reply.conversation
                if !reply.text.isEmpty { completion(reply.text) }
            }
        }
    }

    func cancel() {
        current?.cancel()
        current = nil
    }

    /// A one-off line for the buddy to say on its own (not part of the chat). nil if Gemini isn't
    /// available or fails, so the caller can use a built-in line instead.
    func remark(_ prompt: String, cursor: Bool = false, cursorModel: String = "",
                completion: @escaping @MainActor (String?) -> Void) {
        let job = GeminiJob(request: prompt, conversation: nil, canAct: false, raw: true, cursor: cursor, cursorModel: cursorModel)
        Task.detached {
            let reply = job.run()
            await MainActor.run { completion(reply.ok ? reply.text : nil) }
        }
    }

    /// Forget the conversation so the next request starts fresh.
    func reset() { conversationID = nil }
}

// MARK: - One request (runs off the main thread)

final class GeminiJob: @unchecked Sendable {
    struct Reply {
        let text: String
        let conversation: String?
        var ok = false
    }

    static var persona: String { """
    You are Mac Buddy, a little companion living on the user's Mac, and their close friend. \
    Their name is \(Personality.userName). \(Personality.tone()) Use their name now and then. The user is talking to \
    you by voice: their words come from speech recognition and may contain small mistakes, so work \
    out what they most likely meant. Your reply is read aloud by a text-to-speech voice, so answer \
    in plain spoken language in one or two short sentences, with no markdown, lists, emoji, \
    links or file paths unless they ask for them.

    You are running on the user's macOS computer. Their files are in \(NSHomeDirectory()). When they ask you to do \
    something, do it yourself with shell commands, then say in one sentence what you did. Useful \
    commands: `open -a "App Name"` to open apps, `open "https://..."` for websites, and `osascript` \
    with AppleScript to control apps such as Music, Finder, Safari, Google Chrome, Notes, \
    Reminders, Calendar and System Events (volume, dark mode, and so on). Prefer the simplest \
    command that works.

    Safety rules: never delete or overwrite files, empty the Trash, send messages or emails, post \
    anything online, buy anything, enter passwords, or change security or privacy settings, \
    unless the user clearly asked for exactly that. If a request is unclear and could be harmful, \
    ask a short question instead of acting.
    """ }

    private let request: String
    private let conversation: String?
    private let canAct: Bool
    /// Send the request exactly as given: no persona, no conversation, never acts.
    private let raw: Bool
    private let language: String
    /// Run Cursor's agent (`cursor-agent`) instead of Antigravity (`agy`).
    private let cursor: Bool
    private let cursorModel: String
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    init(request: String, conversation: String?, canAct: Bool, raw: Bool = false, language: String = "auto",
         cursor: Bool = false, cursorModel: String = "") {
        self.request = request
        self.language = language
        self.cursor = cursor
        self.cursorModel = cursorModel.trimmingCharacters(in: .whitespaces)
        self.conversation = conversation
        self.canAct = canAct && !raw
        self.raw = raw
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func run() -> Reply {
        let tool = cursor ? AgyLocator.find(["cursor-agent", "agent"]) : AgyLocator.find(["agy"])
        guard let agy = tool else {
            return Reply(text: cursor
                         ? "I need the Cursor agent to think. Open Terminal, install the Cursor CLI, and run agent login. Then ask me again."
                         : "I need Gemini to think. Open Terminal, install the Antigravity CLI, and run agy once to sign in with your Google account.",
                         conversation: nil)
        }
        let started = Date()
        var result = attempt(agy, conversation: conversation, fast: true)
        // If the speed setting isn't supported by this version of agy, try once without it.
        if result.retryPlain, !isCancelled {
            result = attempt(agy, conversation: conversation, fast: false)
        }
        // If an old conversation can't be continued, quietly start a new one.
        if result.retryFresh, conversation != nil, !isCancelled {
            result = attempt(agy, conversation: nil, fast: true)
        }
        voiceLog("\(cursor ? "cursor" : "gemini") \(raw ? "remark" : "reply") took \(String(format: "%.1f", Date().timeIntervalSince(started)))s ok=\(result.reply.ok)")
        return result.reply
    }

    private func attempt(_ agy: AgyLocator.Found, conversation: String?, fast: Bool)
        -> (reply: Reply, retryFresh: Bool, retryPlain: Bool) {
        // The persona goes with the first message of a conversation; follow-ups just send the request.
        let prompt = raw ? request
            : conversation == nil
            ? "\(Self.persona)\n\n\(Lingo.rules(language))\n\nThe user said: \(request)"
            : "The user said: \(request)"
        // A small empty folder: running in the home folder makes the agent look through all your files first.
        let workspace = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mac-buddy/workspace")
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        var args: [String]
        if cursor {
            // Cursor agent: ask mode only answers; --force lets it run commands and edit files without asking.
            args = ["-p", "--output-format", "json", "--trust", "--workspace", workspace.path]
            if let conversation { args += ["--resume", conversation] }
            args += canAct ? ["--force"] : ["--mode", "ask"]
            if !cursorModel.isEmpty { args += ["--model", cursorModel] }
            args.append(prompt.hasPrefix("-") ? " " + prompt : prompt)
        } else {
            args = ["-p", prompt, "--output-format", "json"]
            if let conversation { args += ["--conversation", conversation] }
            if canAct { args.append("--dangerously-skip-permissions") }   // lets it run commands without asking
            if fast { args += ["--effort", "low"] }   // much quicker answers; plenty for a chatty assistant
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: agy.path)
        p.arguments = args
        p.currentDirectoryURL = workspace
        p.environment = agy.environment

        let stdout = Pipe()
        let errURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macbuddy-gemini-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errURL) }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = stdout
        p.standardError = try? FileHandle(forWritingTo: errURL)

        lock.lock()
        if cancelled { lock.unlock(); return (Reply(text: "", conversation: nil), false, false) }
        do {
            try p.run()
        } catch {
            lock.unlock()
            return (Reply(text: "I couldn't start Gemini.", conversation: nil), false, false)
        }
        process = p
        lock.unlock()

        // Don't let a stuck request hang the buddy forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + (raw ? 40 : 180)) { [weak p] in
            if let p, p.isRunning { p.terminate() }
        }

        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if isCancelled { return (Reply(text: "", conversation: nil), false, false) }

        // agy:    {"conversation_id": "...", "status": "SUCCESS", "response": "...", "error": ...}
        // Cursor: {"type": "result", "is_error": false, "result": "...", "session_id": "..."}
        let json = Self.lastJSONObject(in: out)
        let id = (json?["conversation_id"] as? String) ?? (json?["session_id"] as? String)
        let status = (json?["status"] as? String)?.uppercased()
        let isError = (json?["is_error"] as? Bool) == true
        let answer = (json?["response"] as? String) ?? (json?["result"] as? String)
        if let text = answer, !text.isEmpty, !isError, status == nil || status == "SUCCESS" {
            return (Reply(text: text.trimmingCharacters(in: .whitespacesAndNewlines), conversation: id, ok: true), false, false)
        }

        let err = ((try? String(contentsOf: errURL, encoding: .utf8)) ?? "") + " "
            + String(describing: json?["error"] ?? "") + " " + String(decoding: out, as: UTF8.self)
        let lower = err.lowercased()
        if lower.contains("authentication") || lower.contains("sign in") || lower.contains("login") || lower.contains("log in")
            || lower.contains("not logged") || lower.contains("api key") {
            return (Reply(text: cursor
                          ? "The Cursor agent isn't logged in. Open Terminal, run agent login, then ask me again."
                          : "Gemini isn't signed in yet. Open Terminal, run agy, and sign in with your Google account. Then ask me again.",
                          conversation: nil), false, false)
        }
        if cursor, !cursorModel.isEmpty, lower.contains("model") {
            return (Reply(text: "Cursor doesn't know the model \(cursorModel). Check the name in my Voice settings, or leave it empty.",
                          conversation: nil), false, false)
        }
        if lower.contains("quota") || lower.contains("rate limit") || lower.contains("resource_exhausted") || lower.contains("429") {
            return (Reply(text: "I've used up today's Gemini limit. Try again a bit later.", conversation: id), false, false)
        }
        if p.terminationReason == .uncaughtSignal || status == "CANCELED" || status == "INTERRUPTED" {
            return (Reply(text: "That took too long, so I stopped. Try asking in a simpler way.", conversation: id), false, false)
        }
        if status == "WAITING" {
            return (Reply(text: "Gemini wanted permission to do that. Turn on Let Gemini do things for me in my settings, then ask again.",
                          conversation: id), false, false)
        }
        // agy didn't accept the speed setting: retry without it.
        if fast, lower.contains("effort") { return (Reply(text: "", conversation: id), false, true) }
        if conversation != nil { return (Reply(text: "", conversation: nil), true, false) }
        return (Reply(text: "Sorry, something went wrong while I was thinking. Please try again.", conversation: nil), false, false)
    }

    /// The JSON envelope, even if something printed a stray line before it.
    private static func lastJSONObject(in data: Data) -> [String: Any]? {
        if let whole = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return whole }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") else { continue }
            if let obj = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] { return obj }
        }
        return nil
    }
}

// MARK: - Finding the agy command

/// Apps opened from Finder don't get your shell's PATH, so look for `agy` the way your Terminal
/// would, plus its usual install location (~/.local/bin).
enum AgyLocator {
    struct Found: Sendable { let path: String; let environment: [String: String] }

    private static let lock = NSLock()

    nonisolated(unsafe) private static var cache: [String: Found] = [:]

    /// The first of `names` found, e.g. ["agy"] or ["cursor-agent", "agent"].
    static func find(_ names: [String] = ["agy"]) -> Found? {
        lock.lock(); defer { lock.unlock() }
        let key = names.joined(separator: ",")
        if let hit = cache[key], FileManager.default.isExecutableFile(atPath: hit.path) { return hit }

        let home = NSHomeDirectory()
        let shell = askShell(names)
        var dirs = (shell.path ?? "").split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        dirs = dirs.filter { !$0.isEmpty && seen.insert($0).inserted }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = dirs.joined(separator: ":")

        var candidates: [String] = shell.found
        for name in names {
            // "agent" is a common name, so only trust it from Cursor's own install folder.
            candidates += name == "agent" ? ["\(home)/.local/bin/agent"] : dirs.map { "\($0)/\(name)" }
        }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let found = Found(path: path, environment: env)
        cache[key] = found
        return found
    }

    /// Runs your login shell to read its PATH and where the commands live.
    private static func askShell(_ names: [String]) -> (path: String?, found: [String]) {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        let lookups = names
            .map { "printf '__MB_CMD__%s\\n' \"$(command -v \($0) 2>/dev/null)\"" }.joined(separator: "; ")
        p.arguments = ["-ilc", "printf '\\n__MB_PATH__%s\\n' \"$PATH\"; " + lookups]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (nil, []) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [weak p] in
            if let p, p.isRunning { p.terminate() }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var path: String?, found: [String] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if let r = line.range(of: "__MB_PATH__") { path = String(line[r.upperBound...]) }
            if let r = line.range(of: "__MB_CMD__") {
                let v = String(line[r.upperBound...])
                if v.hasPrefix("/") { found.append(v) }   // ignore aliases
            }
        }
        return (path, found)
    }
}
