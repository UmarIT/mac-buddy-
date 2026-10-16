import Foundation

// voiceLog lives in Listener.swift; the tests don't need the log.
func voiceLog(_ message: String) {}

@main
enum LogicTests {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        if ok { print("✓ \(what)") } else { print("✗ \(what)"); failures += 1 }
    }

    static func main() {
        // Roman Urdu commands → English
        check(Lingo.englishCommand("YouTube kholo") == "open youtube", "youtube kholo")
        check(Lingo.englishCommand("Yaar zara Kesariya chalao") == "play kesariya", "kesariya chalao")
        check(Lingo.englishCommand("Chrome band karo") == "close chrome", "chrome band karo")
        check(Lingo.englishCommand("Awaz barhao please") == "volume up", "awaz barhao")
        check(Lingo.englishCommand("Kitne baje hain?") == "what time", "kitne baje hain")
        check(Lingo.englishCommand("What is the capital of Japan") == "What is the capital of Japan", "English untouched")

        // SHOW / SAY replies
        let both = Lingo.split("SHOW: Theek hoon yaar\nSAY: ठीक हूँ यार")
        check(both.show == "Theek hoon yaar" && both.say == "ठीक हूँ यार", "SHOW/SAY split")
        let plain = Lingo.split("It's 4 PM.")
        check(plain.show == "It's 4 PM." && plain.say == "It's 4 PM.", "plain reply")
        let sayOnly = Lingo.split("SAY: hello there")
        check(sayOnly.show == "hello there", "SAY only")

        // Song moods
        check(NowPlaying.musicVibe(for: "Surah Rahman | Qari Abdul Basit") == .quran, "quran")
        check(NowPlaying.musicVibe(for: "Judai - Sad Song Lyrics") == .sad, "sad")
        check(NowPlaying.musicVibe(for: "Kesariya - Brahmastra") == .romantic, "romantic")
        check(NowPlaying.musicVibe(for: "Mehndi Hai Rachne Wali - Wedding Song") == .happy, "happy")
        check(NowPlaying.musicVibe(for: "Coke Studio | Pasoori") == .groove, "groove")
        check(NowPlaying.musicVibe(for: "A.R. Rahman - Jai Ho") == .groove, "A.R. Rahman isn't Quran")

        print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
