import AppKit

/// A sport the buddy can recognise from a page title or address.
enum Sport: Equatable {
    case cricket, football, basketball, tennis, hockey, racing, fighting, other

    var name: String {
        switch self {
        case .cricket: "cricket"
        case .football: "football"
        case .basketball: "basketball"
        case .tennis: "tennis"
        case .hockey: "hockey"
        case .racing: "racing"
        case .fighting: "the fight"
        case .other: "sports"
        }
    }

    /// SF Symbol used in the bubble and as the bouncing ball.
    var icon: String {
        switch self {
        case .cricket: "cricket.ball"
        case .football: "soccerball"
        case .basketball: "basketball"
        case .tennis: "tennisball"
        case .hockey: "hockey.puck"
        case .racing: "flag.checkered"
        case .fighting: "figure.boxing"
        case .other: "sportscourt"
        }
    }
}

/// How the buddy reacts to what you're doing.
enum Vibe: Equatable {
    case quran          // still, eyes closed, listening respectfully
    case sad            // droopy, slow sway, a tear now and then
    case romantic       // blushing, dreamy, floating hearts
    case happy          // dancing
    case groove         // nodding along
    case sport(Sport)   // watching excitedly, cheering now and then
    case work(String)   // typing on its laptop; the name of the site or app
}

/// What the buddy noticed: a title to show in the bubble, and how to react.
struct Activity: Equatable {
    let title: String
    let vibe: Vibe
}

/// Finds out what you're listening to, watching or working on, by reading the song or tab title
/// (and the tab's web address) from Music, Spotify, Safari, Chrome, Brave or Edge, plus which app
/// is in front. It doesn't record audio or look at the screen. macOS asks once per app for permission.
enum NowPlaying {
    private static let queue = DispatchQueue(label: "macbuddy.nowplaying")

    private static let browsers: [(id: String, name: String, safari: Bool)] = [
        ("com.google.Chrome", "Google Chrome", false), ("com.brave.Browser", "Brave Browser", false),
        ("com.microsoft.edgemac", "Microsoft Edge", false), ("com.apple.Safari", "Safari", true),
    ]

    /// Apps that count as working when they're in front.
    private static let workApps: [String: String] = [
        "com.microsoft.VSCode": "VS Code", "com.apple.dt.Xcode": "Xcode", "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.microsoft.Word": "Word", "com.microsoft.Excel": "Excel", "com.microsoft.Powerpoint": "PowerPoint",
        "com.apple.iWork.Pages": "Pages", "com.apple.iWork.Numbers": "Numbers", "com.apple.iWork.Keynote": "Keynote",
        "com.figma.Desktop": "Figma", "com.tinyspeck.slackmacgap": "Slack", "notion.id": "Notion",
        "com.microsoft.teams2": "Teams", "com.microsoft.Outlook": "Outlook", "com.jetbrains.intellij": "IntelliJ",
        "com.google.android.studio": "Android Studio", "com.sublimetext.4": "Sublime Text",
        "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm", "dev.warp.Warp-Stable": "Warp",
    ]

    /// Calls back on the main thread with what's going on, or nil if nothing interesting.
    @MainActor
    static func check(_ completion: @escaping @MainActor (Activity?) -> Void) {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let frontWorkApp = workApps[frontID]

        var script = "set out to \"\"\nset sep to ASCII character 9\n"
        // Only mention apps that are already running, so checking never launches anything.
        for (id, name) in [("com.apple.Music", "Music"), ("com.spotify.client", "Spotify")] where running.contains(id) {
            script += """
            try
                tell application "\(name)" to if player state is playing then set out to out & "PLAYER" & sep & (name of current track) & " - " & (artist of current track) & linefeed
            end try

            """
        }
        for b in browsers where running.contains(b.id) {
            let tabRef = b.safari ? "current tab of w" : "active tab of w"
            let titleRef = b.safari ? "name of \(tabRef)" : "title of \(tabRef)"
            // The first window listed is the front one; mark it so work only counts when you're looking at it.
            let front = b.id == frontID ? "FRONT" : "BACK"
            script += """
            try
                tell application "\(b.name)"
                    set n to 0
                    repeat with w in windows
                        set n to n + 1
                        set pos to "BACK"
                        if n is 1 then set pos to "\(front)"
                        set out to out & "TAB" & sep & pos & sep & (\(titleRef)) & sep & (URL of \(tabRef)) & linefeed
                    end repeat
                end tell
            end try

            """
        }
        script += "return out"

        guard script.contains("tell application") else {
            completion(frontWorkApp.map { Activity(title: $0, vibe: .work($0)) })
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
            let activity = pick(from: text, frontWorkApp: frontWorkApp)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(activity) }
            }
        }
    }

    /// Priority: music playing in an app → a sports or music tab → a work tab you're looking at → a work app in front.
    private static func pick(from output: String, frontWorkApp: String?) -> Activity? {
        let lines = output.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }

        if let track = lines.first(where: { $0.first == "PLAYER" && $0.count >= 2 }) {
            let title = track[1]
            return Activity(title: title, vibe: sport(in: title, url: "").map(Vibe.sport) ?? musicVibe(for: title))
        }

        var work: Activity?
        for line in lines where line.first == "TAB" && line.count >= 4 {
            let isFront = line[1] == "FRONT"
            let title = cleanTitle(line[2])
            let url = line[3].lowercased()
            if let s = sport(in: title, url: url) {
                return Activity(title: title, vibe: .sport(s))
            }
            if isMedia(title: line[2], url: url), !title.isEmpty {
                return Activity(title: title, vibe: musicVibe(for: title))
            }
            if isFront, work == nil, let site = workSite(url: url, title: title) {
                work = Activity(title: site, vibe: .work(site))
            }
        }
        if let work { return work }
        return frontWorkApp.map { Activity(title: $0, vibe: .work($0)) }
    }

    private static func isMedia(title: String, url: String) -> Bool {
        let lower = title.lowercased()
        return url.contains("youtube.com/watch") || url.contains("music.youtube.com") || url.contains("open.spotify.com")
            || url.contains("soundcloud.com/") || lower.hasSuffix("- youtube")
    }

    /// "(3) Song name - YouTube" → "Song name"
    private static func cleanTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespaces)
        if title.hasPrefix("("), let close = title.firstIndex(of: ")") {
            title = String(title[title.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        for suffix in [" - YouTube Music", " - YouTube", " | Spotify", " - Spotify", " | Free Listening on SoundCloud"]
        where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
        }
        return title.lowercased() == "youtube" ? "" : title
    }

    // MARK: Recognising things

    /// " some words " with punctuation turned into spaces, for whole-word matching.
    private static func words(_ text: String) -> String {
        " " + String(text.lowercased().replacingOccurrences(of: "’", with: "'")
            .map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }) + " "
    }

    private static func sport(in title: String, url: String) -> Sport? {
        // Look at the title and the words in the web address (".../sri-lanka-tour-of-pakistan-t20i/...").
        let path = url.components(separatedBy: "?").first ?? url
        let t = words(title + " " + path)
        func has(_ list: [String]) -> Bool { list.contains { t.contains(" \($0) ") } }
        func site(_ list: [String]) -> Bool { list.contains { url.contains($0) } }

        // Cricket teams; "Pakistan vs Sri Lanka" style matches count as cricket.
        let teams = ["pak", "pakistan", "ind", "india", "sl", "sri lanka", "aus", "australia", "eng", "england",
                     "nz", "new zealand", "ban", "bangladesh", "afg", "afghanistan", "wi", "west indies",
                     "sa", "south africa", "zim", "zimbabwe", "ire", "ireland", "ned", "netherlands", "uae", "usa",
                     "lahore qalandars", "karachi kings", "islamabad united", "peshawar zalmi", "quetta gladiators",
                     "multan sultans"]
        let teamMatch = teams.contains { a in teams.contains { b in a != b && t.contains(" \(a) vs \(b) ") } }
            || teams.contains { a in teams.contains { b in a != b && t.contains(" \(a) v \(b) ") } }

        if has(["cricket", "psl", "ipl", "bbl", "cpl", "t20", "t20i", "t20is", "odi", "odis", "cricinfo", "cricbuzz",
                "wicket", "wickets", "innings", "babar", "rizwan", "shaheen", "fakhar", "kohli", "rohit", "bumrah",
                "ashes", "test match", "asia cup", "champions trophy"])
            || teamMatch
            // A cricket score like "PAK 44/0 (5.4)" (runs/wickets and overs).
            || title.range(of: #"\d{1,3}/\d{1,2}\s*\(\d{1,2}(\.\d)?"#, options: .regularExpression) != nil
            || site(["cricinfo", "cricbuzz", "icc-cricket", "psl-t20", "iplt20", "pcb.com.pk", "ptvsports",
                     "willow.tv", "fancode", "crictime", "smartcric"]) {
            return .cricket
        }
        if has(["football", "soccer", "fifa", "uefa", "epl", "laliga", "bundesliga", "messi", "ronaldo", "neymar",
                "mbappe", "haaland"]) || t.contains(" premier league ") || t.contains(" champions league ")
            || t.contains(" la liga ") || site(["premierleague.com", "uefa.com", "fifa.com", "goal.com"]) {
            return .football
        }
        if has(["nba", "basketball", "lebron", "curry"]) || site(["nba.com"]) { return .basketball }
        if has(["tennis", "wimbledon", "atp", "wta", "djokovic", "nadal", "alcaraz", "sinner"]) || t.contains(" us open ") {
            return .tennis
        }
        if has(["hockey", "nhl"]) { return .hockey }
        if has(["f1", "formula", "motogp", "nascar", "prix"]) || site(["formula1.com"]) { return .racing }
        if has(["ufc", "boxing", "mma", "wwe", "knockout"]) || site(["ufc.com"]) { return .fighting }
        if has(["espn", "highlights", "scorecard"]) || t.contains(" live score ") || site(["espn.", "skysports", "bbc.co.uk/sport"]) {
            return .other
        }
        return nil
    }

    /// Friendly name of a work site, or nil.
    private static func workSite(url: String, title: String) -> String? {
        let sites: [(String, String)] = [
            ("docs.google.com/document", "Google Docs"), ("docs.google.com/spreadsheets", "Google Sheets"),
            ("docs.google.com/presentation", "Google Slides"), ("mail.google.com", "Gmail"),
            ("outlook.", "Outlook"), ("github.com", "GitHub"), ("gitlab.com", "GitLab"), ("bitbucket.org", "Bitbucket"),
            ("notion.so", "Notion"), ("figma.com", "Figma"), ("atlassian.net", "Jira"), ("trello.com", "Trello"),
            ("asana.com", "Asana"), ("linear.app", "Linear"), ("app.slack.com", "Slack"), ("teams.microsoft", "Teams"),
            ("upwork.com", "Upwork"), ("fiverr.com", "Fiverr"), ("canva.com", "Canva"), ("stackoverflow.com", "Stack Overflow"),
            ("chatgpt.com", "ChatGPT"), ("claude.ai", "Claude"), ("vercel.com", "Vercel"), ("console.aws", "AWS"),
            ("console.cloud.google", "Google Cloud"), ("localhost", "localhost"), ("127.0.0.1", "localhost"),
            ("overleaf.com", "Overleaf"), ("airtable.com", "Airtable"), ("clickup.com", "ClickUp"),
            ("monday.com", "monday.com"), ("miro.com", "Miro"), ("linkedin.com/jobs", "job hunting"),
            ("office.com", "Office"), ("sharepoint.com", "SharePoint"), ("replit.com", "Replit"),
            ("codepen.io", "CodePen"), ("leetcode.com", "LeetCode"), ("supabase.com", "Supabase"),
            ("firebase.google.com", "Firebase"), ("calendar.google.com", "Calendar"),
        ]
        return sites.first { url.contains($0.0) }?.1
    }

    /// Guesses the mood of a song or video from its title.
    static func musicVibe(for title: String) -> Vibe {
        let t = words(title)
        func has(_ list: [String]) -> Bool { list.contains { t.contains(" \($0) ") } }

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
