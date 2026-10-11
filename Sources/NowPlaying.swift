import AppKit

/// How the buddy reacts to what you're listening to.
enum Vibe: Equatable {
    case quran   // still, eyes closed, listening respectfully
    case sad     // droopy, slow sway, a tear now and then
    case romantic // blushing, dreamy, floating hearts
    case happy   // dancing
    case groove  // nodding along
}

/// Finds out what's playing in Music, Spotify, or a YouTube / Spotify / SoundCloud tab in Safari
/// or Chrome, by reading the song or video title. It doesn't record or listen to any audio.
/// The first time, macOS asks once per app whether Mac Buddy may read it.
enum NowPlaying {
    private static let queue = DispatchQueue(label: "macbuddy.nowplaying")

    /// Calls back on the main thread with the current title, or nil if nothing is playing.
    @MainActor
    static func check(_ completion: @escaping @MainActor (String?) -> Void) {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var script = "set out to \"\"\n"
        // Only mention apps that are already running, so checking never launches anything.
        if running.contains("com.apple.Music") {
            script += """
            try
                tell application "Music" to if player state is playing then set out to out & "PLAYER:" & (name of current track) & " - " & (artist of current track) & linefeed
            end try

            """
        }
        if running.contains("com.spotify.client") {
            script += """
            try
                tell application "Spotify" to if player state is playing then set out to out & "PLAYER:" & (name of current track) & " - " & (artist of current track) & linefeed
            end try

            """
        }
        for (id, name) in [("com.google.Chrome", "Google Chrome"), ("com.brave.Browser", "Brave Browser"),
                           ("com.microsoft.edgemac", "Microsoft Edge")] where running.contains(id) {
            script += """
            try
                tell application "\(name)" to repeat with w in windows
                    set out to out & "TAB:" & (title of active tab of w) & linefeed
                end repeat
            end try

            """
        }
        if running.contains("com.apple.Safari") {
            script += """
            try
                tell application "Safari" to repeat with w in windows
                    set out to out & "TAB:" & (name of current tab of w) & linefeed
                end repeat
            end try

            """
        }
        script += "return out"

        guard script.contains("tell application") else {
            completion(nil)
            return
        }
        queue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            var text = ""
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                text = String(decoding: data, as: UTF8.self)
            }
            let title = pick(from: text)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(title) }
            }
        }
    }

    /// A playing track wins; otherwise the first media tab (YouTube, Spotify web, SoundCloud).
    private static func pick(from output: String) -> String? {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let track = lines.first(where: { $0.hasPrefix("PLAYER:") }) {
            return String(track.dropFirst("PLAYER:".count))
        }
        for line in lines where line.hasPrefix("TAB:") {
            var title = String(line.dropFirst("TAB:".count))
            let lower = title.lowercased()
            guard lower.hasSuffix("- youtube") || lower.contains("youtube music") || lower.contains("spotify")
                    || lower.contains("soundcloud") else { continue }
            // "(3) Song name - YouTube" → "Song name"
            if title.hasPrefix("("), let close = title.firstIndex(of: ")") {
                title = String(title[title.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            for suffix in [" - YouTube Music", " - YouTube", " | Spotify", " - Spotify", " | Free Listening on SoundCloud"]
            where title.hasSuffix(suffix) {
                title = String(title.dropLast(suffix.count))
            }
            if title.isEmpty || title.lowercased() == "youtube" { continue }
            return title
        }
        return nil
    }

    /// Guesses the mood from the title.
    static func vibe(for title: String) -> Vibe {
        let t = " " + title.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }
            .reduce(into: "") { $0.append($1) } + " "
        func has(_ words: [String]) -> Bool { words.contains { t.contains(" \($0) ") } }

        if has(["quran", "qur'an", "quraan", "koran", "surah", "surat", "sura", "tilawat", "tilawah", "tilawa",
                "recitation", "qari", "qiraat", "qirat", "ayatul", "kursi", "yaseen", "yasin", "fatiha", "fatihah",
                "baqarah", "mishary", "alafasy", "sudais", "shuraim", "minshawi", "basit", "juz", "naat", "hamd",
                "nasheed"]) {
            return .quran
        }
        if has(["sad", "broken", "heartbreak", "breakup", "alone", "lonely", "tears", "cry", "crying", "pain",
                "painful", "miss", "missing", "judai", "bewafa", "tanha", "tanhai", "dard", "rona", "udaas", "udas",
                "gham", "alvida", "emotional", "toota", "tootay", "hurt", "goodbye", "lost", "dukh", "aansu"]) {
            return .sad
        }
        if has(["love", "lover", "romantic", "romance", "ishq", "pyar", "pyaar", "mohabbat", "muhabbat", "dil",
                "jaan", "jaana", "sanam", "mehboob", "mehbooba", "piya", "saiyaan", "saiyan", "humsafar", "valentine",
                "darling", "kesariya", "raanjhana", "ranjha", "heer", "aashiqui", "ashiqui", "aashiq", "deewana",
                "diwana", "chahat", "pehli", "nazar", "beloved", "perfect", "kiss", "crush", "jaanu", "hamsafar"]) {
            return .romantic
        }
        if has(["party", "dance", "dancing", "happy", "celebration", "celebrate", "wedding", "shaadi", "shadi",
                "mehndi", "bhangra", "dhol", "remix", "club", "birthday", "upbeat", "disco", "edm", "workout",
                "naach", "nach", "dj", "mashup", "hype", "summer"]) {
            return .happy
        }
        return .groove
    }
}
