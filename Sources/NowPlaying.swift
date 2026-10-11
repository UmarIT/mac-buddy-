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

/// Kinds of websites the buddy reacts to.
enum SiteKind: Equatable {
    case social, chat, shopping, news, learning, search, food, movie, travel, money, games, other

    var icon: String {
        switch self {
        case .social: "hand.thumbsup.fill"
        case .chat: "bubble.left.and.bubble.right.fill"
        case .shopping: "bag.fill"
        case .news: "newspaper.fill"
        case .learning: "graduationcap.fill"
        case .search: "magnifyingglass"
        case .food: "fork.knife"
        case .movie: "popcorn.fill"
        case .travel: "airplane"
        case .money: "dollarsign.circle.fill"
        case .games: "gamecontroller.fill"
        case .other: "globe"
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
    case browse(SiteKind, String)   // reacting to the website in front; its name
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
        var browsing: Activity?
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
            if isFront, browsing == nil, let site = siteKind(url: url, title: line[2]) {
                browsing = Activity(title: site.1, vibe: .browse(site.0, site.1))
            }
        }
        if let work { return work }
        if let browsing { return browsing }
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

    /// What kind of website this is, and a friendly name for the bubble.
    private static func siteKind(url: String, title: String) -> (SiteKind, String)? {
        guard let parsed = URL(string: url), let rawHost = parsed.host?.lowercased(),
              ["http", "https"].contains(parsed.scheme ?? "") else { return nil }   // skip new tabs, settings pages
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let path = parsed.path.lowercased()
        func on(_ domain: String) -> Bool {
            domain.hasSuffix(".") ? host.contains(domain) : (host == domain || host.hasSuffix("." + domain))
        }

        // Searches: "biryani recipe - Google Search" → "biryani recipe"
        if (on("google.") && path.hasPrefix("/search")) || (on("bing.com") && path.hasPrefix("/search"))
            || on("duckduckgo.com") || on("perplexity.ai") {
            var q = title
            for suffix in [" - Google Search", " - Search", " at DuckDuckGo", " - Bing", " - Perplexity"] where q.hasSuffix(suffix) {
                q = String(q.dropLast(suffix.count))
            }
            return (.search, q)
        }
        if (on("google.") && path.hasPrefix("/maps")) || on("maps.google.") { return (.travel, "Google Maps") }

        let table: [(SiteKind, [(String, String)])] = [
            (.social, [("linkedin.com", "LinkedIn"), ("facebook.com", "Facebook"), ("instagram.com", "Instagram"),
                       ("x.com", "X"), ("twitter.com", "X"), ("reddit.com", "Reddit"), ("tiktok.com", "TikTok"),
                       ("pinterest.com", "Pinterest"), ("threads.net", "Threads"), ("quora.com", "Quora"),
                       ("snapchat.com", "Snapchat"), ("tumblr.com", "Tumblr")]),
            (.chat, [("web.whatsapp.com", "WhatsApp"), ("messenger.com", "Messenger"), ("web.telegram.org", "Telegram"),
                     ("discord.com", "Discord"), ("chat.google.com", "Google Chat")]),
            (.shopping, [("daraz.pk", "Daraz"), ("amazon.", "Amazon"), ("aliexpress.", "AliExpress"), ("ebay.", "eBay"),
                         ("etsy.com", "Etsy"), ("temu.com", "Temu"), ("shein.", "Shein"), ("olx.com.pk", "OLX"),
                         ("alibaba.com", "Alibaba"), ("walmart.com", "Walmart"), ("khaadi.com", "Khaadi"),
                         ("sapphireonline.pk", "Sapphire"), ("outfitters.com.pk", "Outfitters"), ("priceoye.pk", "PriceOye"),
                         ("gulahmedshop.com", "Gul Ahmed"), ("jdot.com", "J."), ("ikea.com", "IKEA")]),
            (.news, [("dawn.com", "Dawn"), ("geo.tv", "Geo"), ("bbc.com", "BBC"), ("bbc.co.uk", "BBC"), ("cnn.com", "CNN"),
                     ("aljazeera.com", "Al Jazeera"), ("tribune.com.pk", "Express Tribune"), ("arynews.tv", "ARY News"),
                     ("samaa.tv", "Samaa"), ("thenews.com.pk", "The News"), ("reuters.com", "Reuters"),
                     ("nytimes.com", "NY Times"), ("theguardian.com", "The Guardian"), ("apnews.com", "AP News"),
                     ("news.google.com", "Google News"), ("propakistani.pk", "ProPakistani"), ("express.pk", "Express"),
                     ("urdupoint.com", "UrduPoint"), ("bloomberg.com", "Bloomberg"), ("techcrunch.com", "TechCrunch"),
                     ("theverge.com", "The Verge")]),
            (.learning, [("wikipedia.org", "Wikipedia"), ("coursera.org", "Coursera"), ("udemy.com", "Udemy"),
                         ("khanacademy.org", "Khan Academy"), ("w3schools.com", "W3Schools"),
                         ("geeksforgeeks.org", "GeeksforGeeks"), ("developer.mozilla.org", "MDN"), ("medium.com", "Medium"),
                         ("dev.to", "DEV"), ("freecodecamp.org", "freeCodeCamp"), ("edx.org", "edX"),
                         ("duolingo.com", "Duolingo"), ("brilliant.org", "Brilliant"), ("developer.apple.com", "Apple Docs"),
                         ("docs.python.org", "Python Docs"), ("britannica.com", "Britannica"), ("quizlet.com", "Quizlet")]),
            (.food, [("foodpanda.", "foodpanda"), ("ubereats.com", "Uber Eats"), ("doordash.com", "DoorDash"),
                     ("deliveroo.", "Deliveroo"), ("kfc.", "KFC"), ("kfcpakistan.com", "KFC"), ("cheezious.com", "Cheezious"), ("mcdonalds.", "McDonald's"), ("dominos.", "Domino's"),
                     ("pizzahut.", "Pizza Hut"), ("cheetay.pk", "Cheetay"), ("grubhub.com", "Grubhub"),
                     ("allrecipes.com", "recipes"), ("tasty.co", "recipes")]),
            (.movie, [("netflix.com", "Netflix"), ("primevideo.com", "Prime Video"), ("disneyplus.com", "Disney+"),
                      ("hulu.com", "Hulu"), ("max.com", "Max"), ("hotstar.com", "Hotstar"), ("tamashaweb.com", "Tamasha"),
                      ("mxplayer.in", "MX Player"), ("crunchyroll.com", "Crunchyroll"), ("imdb.com", "IMDb"),
                      ("tv.apple.com", "Apple TV"), ("zee5.com", "ZEE5"), ("rottentomatoes.com", "Rotten Tomatoes")]),
            (.travel, [("booking.com", "Booking.com"), ("airbnb.", "Airbnb"), ("skyscanner.", "Skyscanner"),
                       ("expedia.", "Expedia"), ("piac.com.pk", "PIA"), ("tripadvisor.", "Tripadvisor"),
                       ("emirates.com", "Emirates"), ("qatarairways.com", "Qatar Airways"), ("agoda.com", "Agoda")]),
            (.money, [("paypal.com", "PayPal"), ("wise.com", "Wise"), ("binance.com", "Binance"),
                      ("tradingview.com", "TradingView"), ("investing.com", "Investing.com"), ("psx.com.pk", "PSX"),
                      ("jazzcash.com.pk", "JazzCash"), ("easypaisa.com.pk", "Easypaisa"), ("meezanbank.com", "Meezan Bank"),
                      ("hbl.com", "HBL"), ("ubldigital.com", "UBL"), ("bankalfalah.com", "Bank Alfalah"),
                      ("coinmarketcap.com", "CoinMarketCap"), ("payoneer.com", "Payoneer"), ("sadapay.pk", "SadaPay"),
                      ("nayapay.com", "NayaPay")]),
            (.games, [("chess.com", "Chess.com"), ("lichess.org", "Lichess"), ("poki.com", "Poki"),
                      ("crazygames.com", "CrazyGames"), ("twitch.tv", "Twitch"), ("steampowered.com", "Steam"),
                      ("epicgames.com", "Epic Games"), ("roblox.com", "Roblox"), ("miniclip.com", "Miniclip"),
                      ("kick.com", "Kick")]),
        ]
        for (kind, sites) in table {
            if let hit = sites.first(where: { on($0.0) }) { return (kind, hit.1) }
        }
        return (.other, host)
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
