import Foundation

/// The buddy's brain: sends what you said to Claude Code (`claude -p`) on this Mac and returns
/// the answer. Uses your existing Claude Code login, so no API key is needed. Follow-up
/// questions continue the same conversation for 15 minutes.
@MainActor
final class Assistant {
    private var sessionID: String?
    private var lastUsed = Date.distantPast
    private var current: AssistantJob?

    var isBusy: Bool { current != nil }

    func ask(_ question: String, allowActions: Bool, folder: String,
             completion: @escaping @MainActor (String) -> Void) {
        if Date().timeIntervalSince(lastUsed) > 15 * 60 { sessionID = nil }   // start fresh after a break
        lastUsed = Date()
        current?.cancel()
        let job = AssistantJob(question: question, resume: sessionID, allowActions: allowActions, folder: folder)
        current = job
        Task.detached {
            let reply = job.run()
            await MainActor.run {
                guard self.current === job else { return }   // cancelled or replaced
                self.current = nil
                if let id = reply.sessionID { self.sessionID = id }
                completion(reply.text)
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

// MARK: - One request to Claude Code (runs off the main thread)

final class AssistantJob: @unchecked Sendable {
    struct Reply { let text: String; let sessionID: String? }

    static let persona = """
    You are Mac Buddy, a cheerful little desktop companion living on the user's Mac, talking with \
    them by voice. Their words come from speech recognition and may contain small mistakes, so \
    work out what they most likely meant. Your reply is read aloud by a text-to-speech voice: \
    answer in plain spoken language, at most three short sentences, with no markdown, lists, \
    code blocks, emoji, URLs or file paths unless they ask for them. Reply in the language they \
    spoke. If they ask you to do something on their Mac and your tools allow it, do it, then say \
    in one sentence what you did. If you can't do it, say so briefly and suggest how they could.
    """

    private let question: String
    private let resume: String?
    private let allowActions: Bool
    private let folder: String
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    init(question: String, resume: String?, allowActions: Bool, folder: String) {
        self.question = question
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
        guard let claude = ClaudeLocator.find() else {
            return Reply(text: "I couldn't find Claude Code on this Mac. Install it and log in, then ask me again.",
                         sessionID: nil)
        }

        var args = ["-p", "--output-format", "json", "--append-system-prompt", Self.persona]
        if let resume { args += ["--resume", resume] }
        if allowActions {
            // Lets the buddy run commands and change files without asking. Off by default.
            args += ["--permission-mode", "acceptEdits",
                     "--allowedTools", "Bash,Edit,Write,Read,Glob,Grep,WebSearch,WebFetch"]
        } else {
            // Answers only: it can read and look things up, but not change anything.
            args += ["--allowedTools", "Read,Glob,Grep,WebSearch,WebFetch"]
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude.path)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: folder)
        var env = claude.environment
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
        if cancelled { lock.unlock(); return Reply(text: "", sessionID: nil) }
        do {
            try p.run()
        } catch {
            lock.unlock()
            return Reply(text: "I couldn't start Claude Code.", sessionID: nil)
        }
        process = p
        lock.unlock()

        // The question goes in on stdin, so nothing in it can be mistaken for a command-line option.
        stdin.fileHandleForWriting.write(Data(question.utf8))
        try? stdin.fileHandleForWriting.close()

        // Don't let a stuck request hang the buddy forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + (allowActions ? 300 : 120)) { [weak p] in
            if let p, p.isRunning { p.terminate() }
        }

        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { return Reply(text: "", sessionID: nil) }

        let json = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any]
        let session = json?["session_id"] as? String
        if let text = json?["result"] as? String, !text.isEmpty, (json?["is_error"] as? Bool) != true {
            return Reply(text: text.trimmingCharacters(in: .whitespacesAndNewlines), sessionID: session)
        }

        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        let combined = (err + " " + String(decoding: out, as: UTF8.self)).lowercased()
        if combined.contains("login") || combined.contains("log in") || combined.contains("auth") {
            return Reply(text: "Claude Code isn't logged in. Open Terminal, run claude, and log in, then ask me again.",
                         sessionID: nil)
        }
        if p.terminationReason == .uncaughtSignal {
            return Reply(text: "That took too long, so I stopped. Try asking in a simpler way.", sessionID: session)
        }
        if resume != nil, combined.contains("session") {
            return Reply(text: "I lost track of our conversation. Please ask me again.", sessionID: nil)
        }
        return Reply(text: "Sorry, something went wrong while I was thinking. Please try again.", sessionID: session)
    }
}

// MARK: - Finding the claude command

/// Apps opened from Finder don't get your shell's PATH, so look for `claude` the way your
/// Terminal would, plus the usual install locations.
enum ClaudeLocator {
    struct Found { let path: String; let environment: [String: String] }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Found?

    static func find() -> Found? {
        lock.lock(); defer { lock.unlock() }
        if let cached, FileManager.default.isExecutableFile(atPath: cached.path) { return cached }

        let home = NSHomeDirectory()
        let shellInfo = askShell()
        var dirs = (shellInfo.path ?? "").split(separator: ":").map(String.init)
        dirs += ["\(home)/.claude/local", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                 "\(home)/.npm-global/bin", "\(home)/.volta/bin", "\(home)/.bun/bin",
                 "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        dirs = dirs.filter { !$0.isEmpty && seen.insert($0).inserted }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = dirs.joined(separator: ":")

        var candidates: [String] = []
        if let p = shellInfo.claude { candidates.append(p) }
        candidates += dirs.map { "\($0)/claude" }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let found = Found(path: path, environment: env)
        cached = found
        return found
    }

    /// Runs your login shell once to read its PATH and where `claude` lives.
    private static func askShell() -> (path: String?, claude: String?) {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", "printf '\\n__MB_PATH__%s\\n' \"$PATH\"; printf '__MB_CLAUDE__%s\\n' \"$(command -v claude 2>/dev/null)\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (nil, nil) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [weak p] in
            if let p, p.isRunning { p.terminate() }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var path: String?, claude: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if let r = line.range(of: "__MB_PATH__") { path = String(line[r.upperBound...]) }
            if let r = line.range(of: "__MB_CLAUDE__") {
                let value = String(line[r.upperBound...])
                if value.hasPrefix("/") { claude = value }   // ignore aliases; the folder search covers those
            }
        }
        return (path, claude)
    }
}
