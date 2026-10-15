import Foundation

/// What the buddy is doing in a voice conversation.
enum VoiceState: Equatable {
    case off
    case listening(String)   // what it has heard so far
    case thinking
    case answering(String)

    var isActive: Bool { self != .off }
}

/// Ties it together: listen → do it (instant commands, or Gemini) → say the answer → listen for
/// your reply. The buddy can also start a conversation itself (see Companion).
@MainActor
final class VoiceBuddy {
    private let model: BuddyModel
    private let settings: BuddySettings
    private let listener = Listener()
    let gemini = GeminiBrain()
    private var clearTimer: Timer?
    /// Listen for a reply once the current line has been spoken.
    private var listenAfterSpeaking = false
    /// The current listen was started by the buddy itself (silence just ends the chat).
    private var followUp = false

    init(model: BuddyModel, settings: BuddySettings) {
        self.model = model
        self.settings = settings
        listener.onPartial = { [weak self] text in self?.model.setVoice(.listening(text)) }
        listener.onFinish = { [weak self] text in self?.heard(text) }
        listener.onError = { [weak self] message in self?.answer(message, thenListen: false) }
        Speaker.shared.onDone = { [weak self] in self?.finishedSpeaking() }
    }

    /// Whether the buddy is busy talking with you right now (so it shouldn't start a new topic).
    var isBusy: Bool { model.voice.isActive || Speaker.shared.isSpeaking }

    /// Double-click, the shortcut, or the menu item. Each press moves the conversation along:
    /// start listening → (press again to send early) → (press while thinking to cancel).
    func toggle() {
        guard settings.voiceAssistant else {
            model.poke()
            return
        }
        switch model.voice {
        case .listening(_):
            listener.stop()
        case .thinking:
            gemini.cancel()
            model.setVoice(.off)
            Speaker.shared.say("Okay, never mind.")
        case .off, .answering(_):
            listen(followUp: false)
        }
    }

    /// Starts a fresh conversation (the buddy forgets earlier requests).
    func newConversation() {
        gemini.reset()
        Speaker.shared.say("Fresh start! What's up?")
    }

    /// The buddy starts talking by itself. If `invitesReply`, it listens for your answer afterwards.
    func speakUp(_ line: String, invitesReply: Bool) {
        guard !isBusy else { return }
        answer(line, thenListen: invitesReply && settings.voiceAssistant)
    }

    var language: String { settings.language }

    // MARK: Flow

    private func listen(followUp: Bool) {
        clearTimer?.invalidate()
        listenAfterSpeaking = false
        Speaker.shared.stop()
        self.followUp = followUp
        model.setVoice(.listening(""))
        listener.start(quiet: followUp, firstWait: followUp ? 6 : 7, locales: Lingo.recognizerLocales(settings.language))
    }

    private func heard(_ text: String) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else {
            if followUp {
                model.setVoice(.off)   // you didn't reply: the chat simply ends
            } else {
                answer("I didn't catch that. Try again?", thenListen: false)
            }
            return
        }
        let keepTalking = settings.keepConversation && !Self.isGoodbye(request)

        // Simple things happen instantly, without using Gemini: open apps, play songs, volume, timers…
        if settings.instantCommands,
           let done = QuickCommands.handle(request) ?? QuickCommands.handle(Lingo.englishCommand(request)) {
            answer(done, thenListen: false)
            return
        }
        // Everything else goes to Gemini, which answers or does it on your Mac.
        model.setVoice(.thinking)
        gemini.ask(request, canAct: settings.geminiActs, language: settings.language) { [weak self] reply in
            guard let self, self.model.voice == .thinking else { return }
            self.answer(reply, thenListen: keepTalking)
        }
    }

    private func answer(_ reply: String, thenListen: Bool) {
        // Gemini may send "SHOW: Roman Urdu / SAY: Devanagari"; plain text is used for both.
        let (text, spoken) = Lingo.split(reply)
        listenAfterSpeaking = thenListen
        model.setVoice(.answering(text))
        Speaker.shared.say(spoken, display: text)
        // Keep the answer on screen about as long as it takes to say it (a fallback if no voice).
        let words = Double(text.split(separator: " ").count)
        clearTimer?.invalidate()
        clearTimer = Timer.scheduledTimer(withTimeInterval: max(3, words / 2.6 + 1.5), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .answering(_) = self.model.voice, !Speaker.shared.isSpeaking else { return }
                self.finishedSpeaking()
            }
        }
    }

    /// After the buddy finishes a line: listen for your reply, or go quiet.
    private func finishedSpeaking() {
        guard case .answering(_) = model.voice else { return }
        clearTimer?.invalidate()
        if listenAfterSpeaking {
            listenAfterSpeaking = false
            listen(followUp: true)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, case .answering(_) = self.model.voice, !Speaker.shared.isSpeaking else { return }
                    self.model.setVoice(.off)
                }
            }
        }
    }

    /// "Thanks", "bye", "that's all"… ends the conversation instead of listening again.
    private static func isGoodbye(_ text: String) -> Bool {
        let t = " " + text.lowercased().filter { $0.isLetter || $0 == " " || $0 == "'" } + " "
        return ["bye", "goodbye", "good night", "goodnight", "that's all", "thats all", "thank you",
                "thanks", "stop", "never mind", "nevermind", "shut up", "be quiet", "allah hafiz", "khuda hafiz"]
            .contains { t.contains(" \($0) ") }
    }
}
