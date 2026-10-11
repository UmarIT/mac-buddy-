import AppKit

/// Things the buddy can do for you instantly, for free, without any AI: open apps and websites,
/// search, change the volume, control music, set timers, tell the time, and more.
@MainActor
enum QuickCommands {
    /// Returns what to say if `text` was a command it handled, or nil to let the AI answer.
    static func handle(_ text: String) -> String? {
        let s = clean(text)
        guard !s.isEmpty else { return nil }

        // Small talk
        if ["thanks", "thank you", "thank you buddy", "thanks buddy"].contains(s) { return "You're welcome!" }
        if ["stop", "never mind", "nevermind", "cancel", "nothing"].contains(s) { return "Okay!" }
        if s == "help" || s.contains("what can you do") {
            return "I can open apps and websites, search Google or YouTube, change the volume, play or pause music, set timers, and tell you the time. Or just ask me a question."
        }

        // Time and date
        if s.contains("what time") || s == "time" || s.contains("the time") {
            return "It's " + format(Date(), "h:mm a") + "."
        }
        if s.contains("what day") || s.contains("the date") || s.contains("todays date") || s.contains("what's today") {
            return "Today is " + format(Date(), "EEEE, MMMM d") + "."
        }

        // Timers: "set a timer for 5 minutes"
        if s.contains("timer") || s.hasPrefix("remind me in") {
            if let seconds = duration(in: s) {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    MainActor.assumeIsolated { Speaker.shared.say("Time's up! Your timer is done.") }
                }
                return "Okay, timer set for \(spoken(seconds))."
            }
            return "How long should the timer be? Say something like, set a timer for 5 minutes."
        }

        // Volume
        let words = Set(s.split(separator: " ").map(String.init))
        if words.contains("unmute") { return appleScript("set volume without output muted") ? "Sound is back on." : nil }
        if words.contains("mute") { return appleScript("set volume with output muted") ? "Muted." : nil }
        if let level = number(after: "volume to", in: s) ?? number(after: "volume at", in: s) {
            let v = max(0, min(100, level))
            return appleScript("set volume output volume \(v)") ? "Volume set to \(v) percent." : nil
        }
        if s.contains("volume up") || s.contains("louder") || s.contains("increase volume") || s.contains("increase the volume") {
            return appleScript("set volume output volume ((output volume of (get volume settings)) + 15)") ? "Turning it up." : nil
        }
        if s.contains("volume down") || s.contains("quieter") || s.contains("lower the volume") || s.contains("decrease volume") || s.contains("decrease the volume") {
            return appleScript("set volume output volume ((output volume of (get volume settings)) - 15)") ? "Turning it down." : nil
        }

        // Music (asks once for permission to control the Music app)
        if s.contains("next song") || s.contains("next track") || s.contains("skip song") {
            return appleScript("tell application \"Music\" to next track") ? "Next song." : nil
        }
        if s.contains("pause music") || s.contains("stop music") || s.contains("pause the music") || s == "pause" {
            return appleScript("tell application \"Music\" to pause") ? "Paused." : nil
        }
        if s.contains("play music") || s.contains("resume music") || s.contains("play some music") {
            return appleScript("tell application \"Music\" to play") ? "Playing music." : nil
        }

        // Screenshot
        if s.contains("screenshot") || s.contains("screen shot") {
            let file = NSHomeDirectory() + "/Desktop/Buddy Screenshot " + format(Date(), "yyyy-MM-dd 'at' HH.mm.ss") + ".png"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", file]
            return (try? p.run()) != nil ? "Screenshot saved to your Desktop." : nil
        }

        // Searches: "search for cats", "google cats", "youtube cats", "play cats on youtube"
        if let q = rest(of: s, after: ["search youtube for", "search on youtube for", "youtube search for", "youtube"])
            ?? suffixQuery(s, prefix: "play", suffix: "on youtube") {
            return open("https://www.youtube.com/results?search_query=" + encode(q)) ? "Here's YouTube for \(q)." : nil
        }
        if let q = rest(of: s, after: ["search google for", "google search for", "search for", "search", "google", "look up", "lookup"]) {
            return open("https://www.google.com/search?q=" + encode(q)) ? "Searching for \(q)." : nil
        }

        // Folders
        for (word, path) in [("downloads", "Downloads"), ("desktop", "Desktop"), ("documents", "Documents")]
        where s.hasPrefix("open") && s.contains(word) && (s.contains("folder") || s.hasSuffix(word)) {
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/" + path))
            return "Opening your \(word) folder."
        }

        // Quit an app: "close safari", "quit spotify"
        if let name = rest(of: s, after: ["quit", "close", "exit"]) {
            let target = name.replacingOccurrences(of: " app", with: "")
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                ($0.localizedName ?? "").lowercased() == target
            }) ?? NSWorkspace.shared.runningApplications.first(where: {
                $0.activationPolicy == .regular && ($0.localizedName ?? "").lowercased().contains(target)
            }) {
                if app.bundleIdentifier == Bundle.main.bundleIdentifier { return "I'll stay right here!" }
                app.terminate()
                return "Closing \(app.localizedName ?? target)."
            }
            // Not a running app: let the AI handle it.
        }

        // Open an app or a website: "open safari", "open youtube", "go to github.com"
        if let name = rest(of: s, after: ["open up", "open", "launch", "go to"]) {
            let target = name.replacingOccurrences(of: " app", with: "").replacingOccurrences(of: " website", with: "")
            if target.contains("."), !target.contains(" ") {          // a web address like github.com
                return open("https://" + target) ? "Opening \(target)." : nil
            }
            // An app with exactly that name wins, then a well-known website, then a close app match.
            if let app = findApp(target, exactOnly: true) {
                return launch(app)
            }
            if let site = sites[target] {
                return open(site) ? "Opening \(target.capitalized)." : nil
            }
            if let app = findApp(target, exactOnly: false) {
                return launch(app)
            }
            // Not an app or a site: let the AI handle it.
        }

        return nil
    }

    // MARK: Helpers

    private static let sites: [String: String] = [
        "youtube": "https://www.youtube.com", "google": "https://www.google.com",
        "gmail": "https://mail.google.com", "github": "https://github.com",
        "facebook": "https://www.facebook.com", "instagram": "https://www.instagram.com",
        "twitter": "https://x.com", "x": "https://x.com", "whatsapp": "https://web.whatsapp.com",
        "linkedin": "https://www.linkedin.com", "reddit": "https://www.reddit.com",
        "netflix": "https://www.netflix.com", "amazon": "https://www.amazon.com",
        "wikipedia": "https://www.wikipedia.org", "google maps": "https://maps.google.com",
        "chatgpt": "https://chatgpt.com", "claude": "https://claude.ai", "upwork": "https://www.upwork.com",
        "fiverr": "https://www.fiverr.com", "daraz": "https://www.daraz.pk", "spotify": "https://open.spotify.com",
    ]

    /// Lowercases and drops punctuation and polite filler ("hey buddy, can you please …").
    private static func clean(_ text: String) -> String {
        var s = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "." || $0 == "'" }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let fillers = ["hey buddy", "hi buddy", "okay buddy", "ok buddy", "buddy", "hey", "please", "can you",
                       "could you", "would you", "will you", "i want you to", "i want to", "for me", "now"]
        var changed = true
        while changed {
            changed = false
            for f in fillers {
                if s.hasPrefix(f + " ") { s = String(s.dropFirst(f.count + 1)); changed = true }
                if s.hasSuffix(" " + f) { s = String(s.dropLast(f.count + 1)); changed = true }
            }
            s = s.trimmingCharacters(in: .whitespaces)
        }
        return s.split(separator: " ").joined(separator: " ")
    }

    /// The words after the first matching command word, e.g. "open safari" → "safari".
    private static func rest(of s: String, after commands: [String]) -> String? {
        for c in commands where s.hasPrefix(c + " ") {
            var r = String(s.dropFirst(c.count + 1)).trimmingCharacters(in: .whitespaces)
            for article in ["the ", "a ", "my "] where r.hasPrefix(article) { r = String(r.dropFirst(article.count)) }
            if !r.isEmpty { return r }
        }
        return nil
    }

    private static func suffixQuery(_ s: String, prefix: String, suffix: String) -> String? {
        guard s.hasPrefix(prefix + " "), s.hasSuffix(" " + suffix) else { return nil }
        let q = s.dropFirst(prefix.count + 1).dropLast(suffix.count + 1).trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? nil : q
    }

    private static func launch(_ app: URL) -> String {
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        return "Opening \(app.deletingPathExtension().lastPathComponent)."
    }

    private static func findApp(_ name: String, exactOnly: Bool) -> URL? {
        let fm = FileManager.default
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var apps: [URL] = []
        for folder in folders {
            let items = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)) ?? []
            apps += items.filter { $0.pathExtension == "app" }
        }
        let wanted = name.replacingOccurrences(of: " ", with: "")
        func key(_ url: URL) -> String {
            url.deletingPathExtension().lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "")
        }
        // Exact name first ("notes"), then a name that starts with it ("chrome" → none, "google chrome" ✓),
        // then one that contains it ("code" → "Visual Studio Code").
        if let exact = apps.first(where: { key($0) == wanted }) { return exact }
        if exactOnly { return nil }
        return apps.first { key($0).hasPrefix(wanted) }
            ?? apps.first { wanted.count >= 3 && key($0).contains(wanted) }
    }

    private static func open(_ link: String) -> Bool {
        guard let url = URL(string: link) else { return false }
        return NSWorkspace.shared.open(url)
    }

    private static func encode(_ q: String) -> String {
        q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "&", with: "%26") ?? q
    }

    @discardableResult
    private static func appleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.dateFormat = pattern
        return f.string(from: date)
    }

    private static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40,
        "forty five": 45, "fifty": 50, "sixty": 60, "half an": 30,
    ]

    private static func value(_ word: String) -> Int? { Int(word) ?? numberWords[word] }

    /// "5 minutes", "an hour", "30 seconds", "half an hour" → seconds.
    private static func duration(in s: String) -> TimeInterval? {
        let words = s.split(separator: " ").map(String.init)
        if s.contains("half an hour") { return 1800 }
        for (i, w) in words.enumerated() where i > 0 {
            let unit: Double
            if w.hasPrefix("second") || w == "sec" || w == "secs" { unit = 1 }
            else if w.hasPrefix("minute") || w == "min" || w == "mins" { unit = 60 }
            else if w.hasPrefix("hour") { unit = 3600 }
            else { continue }
            if let n = value(words[i - 1]) { return Double(n) * unit }
        }
        return nil
    }

    private static func spoken(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s % 3600 == 0 { return s == 3600 ? "1 hour" : "\(s / 3600) hours" }
        if s % 60 == 0 { return s == 60 ? "1 minute" : "\(s / 60) minutes" }
        return "\(s) seconds"
    }

    private static func number(after phrase: String, in s: String) -> Int? {
        guard let r = s.range(of: phrase + " ") else { return nil }
        let word = s[r.upperBound...].split(separator: " ").first.map(String.init) ?? ""
        return Int(word.replacingOccurrences(of: "%", with: "")) ?? numberWords[word]
    }
}
