import AVFoundation

/// Speaks the buddy's lines out loud with the Mac's built-in voice (works offline), and keeps
/// track of which word it's on so the mouth can move and the bubble can type along.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    private let synth = AVSpeechSynthesizer()
    /// The text being spoken (after cleanup), and how much of it has been said so far.
    private(set) var text = ""
    private(set) var spokenUpTo = 0
    private(set) var isSpeaking = false
    private var wordStarted = Date.distantPast

    override init() {
        super.init()
        synth.delegate = self
    }

    func say(_ line: String) {
        let clean = Self.speakable(line)
        guard !clean.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        text = clean
        spokenUpTo = 0
        isSpeaking = true
        wordStarted = Date()
        let utterance = AVSpeechUtterance(string: clean)
        utterance.pitchMultiplier = 1.2   // a little higher, to suit a small buddy
        synth.speak(utterance)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    /// How wide the mouth should open right now (0…1): it opens and closes once per word.
    func mouthOpenness(at date: Date) -> Double {
        guard isSpeaking else { return 0 }
        let since = date.timeIntervalSince(wordStarted)
        let word = since < 0.28 ? sin(since / 0.28 * .pi) : 0
        let chatter = 0.25 * abs(sin(date.timeIntervalSinceReferenceDate * 13))   // in case word timing isn't reported
        return max(0.12, min(1, max(word, chatter)))
    }

    /// The part of the text said so far, ending with the current word, at most `limit` characters.
    func typedSoFar(limit: Int) -> String {
        let ns = text as NSString
        let end = isSpeaking ? min(spokenUpTo, ns.length) : ns.length
        let said = ns.substring(to: end).trimmingCharacters(in: .whitespaces)
        guard said.count > limit else { return said }
        return "…" + String(said.suffix(limit - 1))
    }

    // MARK: AVSpeechSynthesizerDelegate (called off the main thread)

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        let end = characterRange.location + characterRange.length
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.spokenUpTo = max(self.spokenUpTo, end)
                self.wordStarted = Date()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.isSpeaking = false
                self.spokenUpTo = (self.text as NSString).length
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // Only if nothing new started speaking in the meantime.
                if !self.synth.isSpeaking { self.isSpeaking = false }
            }
        }
    }

    /// Drops emoji and decoration like "*yawn*" so the voice doesn't read them out.
    static func speakable(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { s in
            let p = s.properties
            if s.value == 0xFE0F || s.value == 0x200D { return false }      // emoji joiners
            if p.isEmojiPresentation { return false }
            if p.isEmoji && s.value >= 0x2000 { return false }             // symbols like ☕️ ✦
            return true
        }
        return String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "…", with: ".")
            .trimmingCharacters(in: .whitespaces)
    }
}
