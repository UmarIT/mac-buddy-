import Foundation

/// Which command-line agent answers your questions.
enum Brain: String, CaseIterable, Identifiable, Sendable {
    case auto, claude, cursor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Automatic"
        case .claude: "Claude Code"
        case .cursor: "Cursor"
        }
    }
}

/// The buddy's brain: sends what you said to Claude Code (`claude -p`) or Cursor's agent
/// (`agent -p`) on this Mac and returns the answer. Uses your existing login for that tool, so no
/// API key is needed. Follow-up questions continue the same conversation for 15 minutes.
@MainActor
final class Assistant {
    private var sessionID: String?
    private var sessionBrain: Brain?
    private var lastUsed = Date.distantPast
    private var current: AssistantJob?

    var isBusy: Bool { current != nil }

    func ask(_ question: String, brain: Brain, allowActions: Bool, folder: String,
             completion: @escaping @MainActor (_ text: String, _ notFound: Bool) -> Void) {
        // Start fresh after a break, or when you switch brains.
        if Date().timeIntervalSince(lastUsed) > 15 * 60 || sessionBrain != brain { sessionID = nil }
        lastUsed = Date()
        current?.cancel()
        let job = AssistantJob(question: question, brain: brain, resume: sessionID,
                               allowActions: allowActions, folder: folder)
        current = job
        Task.detached {
            let reply = job.run()
            await MainActor.run {
                guard self.current === job else { return }   // cancelled or replaced
                self.current = nil
                self.sessionID = reply.sessionID
                self.sessionBrain = brain
                completion(reply.text, reply.notFound)
            }
        }
    }

    func cancel() {
        current?.cancel()
        current = nil
    }

    /// Forget the conversation so the next question starts fresh.
    func reset() { sessionID = nil }
}

// MARK: - One request (runs off the main thread)

final class AssistantJob: @unchecked Sendable {
    struct Reply { let text: String; let sessionID: String?; var notFound = false }

    static let persona = """
    You are Mac Buddy, a cheerful little desktop companion living on the user's Mac, talking with \
    them by voice. Their words come from speech recognition and may contain small mistakes, so \
    work out what they most likely meant. Your reply is read aloud by a text-to-speech voice: \
    answer in plain spoken language, at most three short sentences, with no markdown, lists, \
    code blocks, emoji, URLs or file paths unless they ask for them. Reply in the language they \
    spoke. If they ask you to do something on their Mac and your tools allow it, do it, then say \
    in one sentence what you did. If you can't do it, say so briefly and suggest how they could.
    You are running on the user's macOS computer, in their home folder. To control apps and the \
    system, use shell commands such as `open -a "App Name"`, `open "https://…"`, and `osascript` \
    with AppleScript (for example to control Music, Finder, Safari, Notes, Reminders, Calendar \
    or System Events). Never delete files, empty the Trash, send messages or emails, buy \
    anything, or change system security settings unless the user clearly asked for exactly that.
    """

    private let question: String
    private let brain: Brain
    private let resume: String?
    private let allowActions: Bool
    private let folder: String
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    init(question: String, brain: Brain, resume: String?, allowActions: Bool, folder: String) {
        self.question = question
        self.brain = brain
        self.resume = resume
        self.allowActions = allowActions
        self.folder = folder
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }

    func run() -> Reply {
        let tool: CLILocator.Found
        switch brain {
        case .claude:
            guard let t = CLILocator.find(.claude) else {
                return Reply(text: "I couldn't find Claude Code on this Mac. Install it and log in, or switch my brain to Cursor in Settings.",
                             sessionID: nil)
            }
            tool = t
        case .cursor:
            guard let t = CLILocator.find(.cursor) else {
                return Reply(text: "I couldn't find the Cursor agent on this Mac. Install the Cursor CLI and run agent login, then ask me again.",
                             sessionID: nil)
            }
            tool = t
        case .auto:
            guard let t = CLILocator.find(.claude) ?? CLILocator.find(.cursor) else {
                return Reply(text: "", sessionID: nil, notFound: true)
            }
            tool = t
        }

        let first = attempt(with: tool, resume: resume)
        // If an old conversation can't be continued, quietly start a new one.
        if first.failedResume, resume != nil, !isCancelled {
            return attempt(with: tool, resume: nil).reply
        }
        return first.reply
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func attempt(with tool: CLILocator.Found, resume: String?) -> (reply: Reply, failedResume: Bool) {
        var args: [String]
        var stdinText: String?
        switch tool.kind {
        case .claude:
            args = ["-p", "--output-format", "json", "--append-system-prompt", Self.persona]
            if let resume { args += ["--resume", resume] }
            if allowActions {
                // Lets the buddy run commands and change files without asking. Off by default.
                args += ["--permission-mode", "acceptEdits",
                         "--allowedTools", "Bash,Edit,Write,Read,Glob,Grep,WebSearch,WebFetch"]
            } else {
                // Answers only: it can read and look things up, but not change anything.
                args += ["--allowedTools", "Read,Glob,Grep,WebSearch,WebFetch"]
            }
            stdinText = question   // on stdin, so nothing in it can look like an option
        case .cursor:
            args = ["-p", "--output-format", "json", "--trust", "--workspace", folder]
            if let resume { args += ["--resume", resume] }
            // Ask mode only answers; --force lets it edit files and run commands without asking.
            args += allowActions ? ["--force"] : ["--mode", "ask"]
            // The Cursor agent has no system-prompt option, so the persona leads the prompt.
            // It never starts with "-", so it can't be mistaken for an option.
            args.append(resume == nil ? "\(Self.persona)\n\nThe user said: \(question)" : question.hasPrefix("-") ? " \(question)" : question)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool.path)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: folder)
        var env = tool.environment
        env["MAC_BUDDY_ASSISTANT"] = "1"   // tells our own hooks to ignore this session
        p.environment = env

        let stdin = Pipe(), stdout = Pipe()
        let errURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macbuddy-assistant-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errURL) }
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = try? FileHandle(forWritingTo: errURL)

        lock.lock()
        if cancelled { lock.unlock(); return (Reply(text: "", sessionID: nil), false) }
        do {
            try p.run()
        } catch {
            lock.unlock()
            return (Reply(text: "I couldn't start \(tool.kind.name).", sessionID: nil), false)
        }
        process = p
        lock.unlock()

        if let stdinText { stdin.fileHandleForWriting.write(Data(stdinText.utf8)) }
        try? stdin.fileHandleForWriting.close()

        // Don't let a stuck request hang the buddy forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + (allowActions ? 300 : 120)) { [weak p] in
            if let p, p.isRunning { p.terminate() }
        }

        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        if isCancelled { return (Reply(text: "", sessionID: nil), false) }

        // Both tools print one JSON object: {"result": "...", "session_id": "...", "is_error": false}
        let json = Self.lastJSONObject(in: out)
        let session = json?["session_id"] as? String
        if let text = json?["result"] as? String, !text.isEmpty, (json?["is_error"] as? Bool) != true {
            return (Reply(text: text.trimmingCharacters(in: .whitespacesAndNewlines), sessionID: session), false)
        }

        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        let combined = (err + " " + String(decoding: out, as: UTF8.self)).lowercased()
        if combined.contains("login") || combined.contains("log in") || combined.contains("auth")
            || combined.contains("api key") {
            let fix = tool.kind == .cursor ? "run agent login" : "run claude and log in"
            return (Reply(text: "\(tool.kind.name) isn't logged in. Open Terminal, \(fix), then ask me again.",
                          sessionID: nil), false)
        }
        if p.terminationReason == .uncaughtSignal {
            return (Reply(text: "That took too long, so I stopped. Try asking in a simpler way.", sessionID: session), false)
        }
        if resume != nil, combined.contains("session") || combined.contains("chat") || combined.contains("resume") {
            return (Reply(text: "", sessionID: nil), true)
        }
        return (Reply(text: "Sorry, something went wrong while I was thinking. Please try again.", sessionID: nil), resume != nil)
    }

    /// The JSON result, even if a tool prints a stray line before it.
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

// MARK: - Finding the command-line tools

/// Apps opened from Finder don't get your shell's PATH, so look for the tools the way your
/// Terminal would, plus the usual install locations.
enum CLILocator {
    enum Kind: Sendable {
        case claude, cursor
        var name: String { self == .cursor ? "Cursor" : "Claude Code" }
    }

    struct Found: Sendable {
        let kind: Kind
        let path: String
        let environment: [String: String]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var shellInfo: (path: String?, claude: String?, cursor: String?)?
    nonisolated(unsafe) private static var cache: [String: Found] = [:]

    static func find(_ kind: Kind) -> Found? {
        lock.lock(); defer { lock.unlock() }
        let key = kind == .cursor ? "cursor" : "claude"
        if let hit = cache[key], FileManager.default.isExecutableFile(atPath: hit.path) { return hit }

        let home = NSHomeDirectory()
        let info = shellInfo ?? askShell()
        shellInfo = info

        var dirs = (info.path ?? "").split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
                 "\(home)/.npm-global/bin", "\(home)/.volta/bin", "\(home)/.bun/bin",
                 "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        dirs = dirs.filter { !$0.isEmpty && seen.insert($0).inserted }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = dirs.joined(separator: ":")

        var candidates: [String] = []
        switch kind {
        case .claude:
            if let p = info.claude { candidates.append(p) }
            candidates += dirs.map { "\($0)/claude" }
        case .cursor:
            // Cursor's CLI is called `cursor-agent` (older) or `agent` (newer). "agent" is a
            // common name, so only trust it from Cursor's own install folder.
            if let p = info.cursor { candidates.append(p) }
            candidates += dirs.map { "\($0)/cursor-agent" }
            candidates.append("\(home)/.local/bin/agent")
        }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let found = Found(kind: kind, path: path, environment: env)
        cache[key] = found
        return found
    }

    /// Runs your login shell once to read its PATH and where the tools live.
    private static func askShell() -> (path: String?, claude: String?, cursor: String?) {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", """
            printf '\\n__MB_PATH__%s\\n' "$PATH"; \
            printf '__MB_CLAUDE__%s\\n' "$(command -v claude 2>/dev/null)"; \
            printf '__MB_CURSOR__%s\\n' "$(command -v cursor-agent 2>/dev/null)"
            """]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (nil, nil, nil) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [weak p] in
            if let p, p.isRunning { p.terminate() }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var path: String?, claude: String?, cursor: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            func value(_ marker: String) -> String? {
                guard let r = line.range(of: marker) else { return nil }
                return String(line[r.upperBound...])
            }
            if let v = value("__MB_PATH__") { path = v }
            // Ignore aliases (they don't start with "/"); the folder search covers those.
            if let v = value("__MB_CLAUDE__"), v.hasPrefix("/") { claude = v }
            if let v = value("__MB_CURSOR__"), v.hasPrefix("/") { cursor = v }
        }
        return (path, claude, cursor)
    }
}
