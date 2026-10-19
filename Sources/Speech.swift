import AVFoundation

/// Speaks the buddy's lines out loud with the Mac's built-in voice (works offline), and keeps
/// track of which word it's on so the mouth can move and the bubble can type along.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    private let synth = AVSpeechSynthesizer()
    /// The text being spoken (after cleanup), and how much of it has been said so far.
    private(set) var text = ""
    /// What the bubble shows while speaking (e.g. Roman Urdu while the voice reads Devanagari).
    private(set) var display = ""
    private(set) var spokenUpTo = 0
    private(set) var isSpeaking = false
    /// Called when a line has been spoken all the way through (not when it's cut off).
    var onDone: (() -> Void)?
    private var wordStarted = Date.distantPast
    /// The utterance being spoken now, so callbacks about an older one are ignored.
    private var currentID: ObjectIdentifier?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Speaks `line`. `display` is what the bubble types along with it, if different.
    func say(_ line: String, display: String? = nil) {
        let clean = Self.speakable(line)
        guard !clean.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        text = clean
        self.display = display.map(Self.speakable) ?? clean
        spokenUpTo = 0
        isSpeaking = true
        wordStarted = Date()
        let utterance = AVSpeechUtterance(string: clean)
        let cute = UserDefaults.standard.object(forKey: "buddy.cuteVoice") as? Bool ?? true
        utterance.pitchMultiplier = cute ? 1.2 : 1.0   // a little higher suits a small buddy
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.06   // a touch quicker
        utterance.voice = Self.voice(for: clean) ?? Self.englishVoice
        currentID = ObjectIdentifier(utterance)
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
    /// When the bubble shows a different version (Roman Urdu), it advances by the same proportion.
    func typedSoFar(limit: Int) -> String {
        let spoken = text as NSString
        let shown = display as NSString
        let progress = spoken.length == 0 ? 1 : Double(min(spokenUpTo, spoken.length)) / Double(spoken.length)
        var end = isSpeaking ? Int((Double(shown.length) * progress).rounded()) : shown.length
        if isSpeaking, end < shown.length {   // finish the current word
            let rest = shown.range(of: " ", options: [], range: NSRange(location: end, length: shown.length - end))
            end = rest.location == NSNotFound ? shown.length : rest.location
        }
        let said = shown.substring(to: min(end, shown.length)).trimmingCharacters(in: .whitespaces)
        guard said.count > limit else { return said }
        return "…" + String(said.suffix(limit - 1))
    }

    // MARK: AVSpeechSynthesizerDelegate (called off the main thread)

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        let end = characterRange.location + characterRange.length
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.currentID == id else { return }
                self.spokenUpTo = max(self.spokenUpTo, end)
                self.wordStarted = Date()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.currentID == id else { return }
                self.isSpeaking = false
                self.spokenUpTo = (self.text as NSString).length
                self.onDone?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // Only if nothing new started speaking in the meantime.
                if self.currentID == id { self.isSpeaking = false }
            }
        }
    }

    /// The English voice: the one picked in Settings, else the most natural one installed
    /// (Premium, then Enhanced, then the default).
    static var englishVoice: AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: "buddy.voiceID"), !id.isEmpty,
           let chosen = AVSpeechSynthesisVoice(identifier: id) {
            return chosen
        }
        return englishVoices.first
    }

    /// Installed English voices, most natural first.
    static var englishVoices: [AVSpeechSynthesisVoice] {
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            var r = 0
            switch v.quality {
            case .premium: r += 300
            case .enhanced: r += 200
            default: r += 0
            }
            if v.language == "en-US" { r += 30 } else if v.language == "en-GB" { r += 20 } else if v.language == "en-IN" { r += 15 }
            if v.voiceTraits.contains(.isNoveltyVoice) { r -= 500 }
            return r
        }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { rank($0) > rank($1) }
    }

    /// Hindi voice for Devanagari (Urdu/Punjabi replies), an Urdu voice for Urdu script if one is
    /// installed, otherwise the Mac's default voice.
    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let scalars = text.unicodeScalars
        if scalars.contains(where: { (0x0900...0x097F).contains($0.value) }) {
            return AVSpeechSynthesisVoice(language: "hi-IN")
        }
        if scalars.contains(where: { (0x0600...0x06FF).contains($0.value) }) {
            return AVSpeechSynthesisVoice(language: "ur-PK") ?? AVSpeechSynthesisVoice(language: "ur-IN")
        }
        if scalars.contains(where: { (0x0A00...0x0A7F).contains($0.value) }) {
            return AVSpeechSynthesisVoice(language: "pa-IN")
        }
        return nil
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
