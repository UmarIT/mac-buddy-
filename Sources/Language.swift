import Foundation

/// English, Urdu and Punjabi support.
///
/// macOS has no Urdu or Punjabi speech recognizer or standard voice, so:
/// - listening uses Hindi in Roman letters ("hi-Latn"), made for mixed Hindi/English speech;
///   spoken Urdu is nearly the same, and it comes out as Roman Urdu like on WhatsApp;
/// - Gemini replies with two versions: SHOW (Roman Urdu/Punjabi, for the bubble) and SAY
///   (the same words in Devanagari, so the Hindi voice pronounces them properly).
enum Lingo {
    /// Speech-recognition locales to try, best first.
    static func recognizerLocales(_ language: String) -> [String] {
        switch language {
        case "en": return ["en-US", "en-IN", "en-GB"]
        default: return ["hi-Latn", "hi-IN", "en-IN", "en-US"]   // Urdu, Punjabi, or a mix
        }
    }

    /// Instructions for Gemini about which language to answer in, and how to format it.
    static func rules(_ language: String) -> String {
        let which: String = switch language {
        case "en": "Always reply in English."
        case "ur": "Always reply in Urdu."
        case "pa": "Always reply in Punjabi."
        default: "Reply in English, unless the user's message is in Urdu or Punjabi (in Urdu script or Roman letters); then reply in that language, in Roman letters."
        }
        guard language != "en" else { return which }
        return """
        \(which)
        Format every reply as exactly two lines:
        SHOW: the reply as the user reads it (English as is; Urdu or Punjabi in Roman letters, like WhatsApp)
        SAY: the same reply for the voice (English as is; Urdu or Punjabi written in Devanagari script so a Hindi voice pronounces it correctly)
        """
    }

    /// Splits a "SHOW: … / SAY: …" reply. Falls back to the whole text for both.
    static func split(_ reply: String) -> (show: String, say: String) {
        var show: String?, say: String?
        for line in reply.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.uppercased().hasPrefix("SHOW:") { show = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            if t.uppercased().hasPrefix("SAY:") { say = String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        }
        let clean = reply.replacingOccurrences(of: "SHOW:", with: "").replacingOccurrences(of: "SAY:", with: "")
        let s = show ?? say ?? clean.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s, say ?? s)
    }

    /// Turns common Roman Urdu/Punjabi commands into English ones the built-in commands understand:
    /// "youtube kholo" → "open youtube", "kesariya chalao" → "play kesariya", "awaz barhao" → "volume up".
    static func englishCommand(_ text: String) -> String {
        var s = " " + text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "." } + " "
        for filler in [" please ", " plz ", " zara ", " yaar ", " yar ", " buddy ", " na ", " ji "] {
            s = s.replacingOccurrences(of: filler, with: " ")
        }
        s = s.split(separator: " ").joined(separator: " ")

        let whole: [(String, String)] = [
            ("awaz barhao", "volume up"), ("awaz tez karo", "volume up"), ("awaz zyada karo", "volume up"),
            ("awaz kam karo", "volume down"), ("awaz ahista karo", "volume down"), ("awaz dheemi karo", "volume down"),
            ("awaz band karo", "mute"), ("awaz kholo", "unmute"),
            ("kitne baje hain", "what time"), ("kya time hai", "what time"), ("time kya hai", "what time"),
            ("kitna time hua", "what time"), ("kinne vaje ne", "what time"), ("aaj kya din hai", "what day"),
            ("screenshot lo", "take a screenshot"), ("screenshot le lo", "take a screenshot"),
            ("gana band karo", "pause music"), ("music band karo", "pause music"), ("agla gana", "next song"),
        ]
        for (urdu, english) in whole where s.contains(urdu) { return english }

        let suffixes: [(String, String)] = [
            (" khol do", "open"), (" kholo", "open"), (" khol", "open"), (" open karo", "open"), (" open kar do", "open"),
            (" chalao", "play"), (" chala do", "play"), (" lagao", "play"), (" laga do", "play"), (" sunao", "play"),
            (" bajao", "play"), (" play karo", "play"), (" play kar do", "play"), (" chala", "play"),
            (" band karo", "close"), (" band kar do", "close"), (" bund karo", "close"),
            (" search karo", "search for"), (" talash karo", "search for"), (" dhundo", "search for"), (" dhoondo", "search for"),
        ]
        for (ending, verb) in suffixes where s.hasSuffix(ending) {
            var thing = String(s.dropLast(ending.count)).trimmingCharacters(in: .whitespaces)
            for tail in [" ko", " pe", " par", " mein", " main", " ka", " ki", " ke"] where thing.hasSuffix(tail) {
                thing = String(thing.dropLast(tail.count))
            }
            if !thing.isEmpty { return "\(verb) \(thing)" }
        }
        return text
    }
}

/// How the buddy talks. Stored as "buddy.personality" in UserDefaults (see BuddySettings).
enum Personality {
    static var current: String { UserDefaults.standard.string(forKey: "buddy.personality") ?? "friendly" }

    static var userName: String { NSFullUserName().split(separator: " ").first.map(String.init) ?? "friend" }

    /// The tone part of the prompt.
    static func tone(_ style: String = current) -> String {
        switch style {
        case "witty":
            return """
            Your personality is witty, cheeky and a little sarcastic, like a funny friend who loves banter: \
            make clever jokes, tease them playfully, have bold, honest opinions instead of sitting on the fence, \
            and never sound preachy, corporate or overly polite. Keep it good-natured: never mean, hurtful, \
            crude or offensive, and drop the jokes when they're sad or asking about something serious.
            """
        case "chill":
            return "Your personality is calm, relaxed and laid-back. Keep things short and easygoing."
        default:
            return "Talk warmly and casually, like a close, caring friend."
        }
    }
}
