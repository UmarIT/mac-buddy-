import AVFoundation

/// Speaks the buddy's lines out loud with the Mac's built-in voice (works offline).
@MainActor
final class Speaker {
    static let shared = Speaker()

    private let synth = AVSpeechSynthesizer()

    func say(_ text: String) {
        let clean = Self.speakable(text)
        guard !clean.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .word) }
        let utterance = AVSpeechUtterance(string: clean)
        utterance.pitchMultiplier = 1.2   // a little higher, to suit a small buddy
        synth.speak(utterance)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
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
