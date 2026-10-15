import Foundation

/// What the buddy is doing in a voice conversation.
enum VoiceState: Equatable {
    case off
    case listening(String)   // what it has heard so far
    case thinking
    case answering(String)

    var isActive: Bool { self != .off }
}

/// Ties it together: listen → do it (instant commands, or Gemini) → say the answer.
@MainActor
final class VoiceBuddy {
    private let model: BuddyModel
    private let settings: BuddySettings
    private let listener = Listener()
    private let gemini = GeminiBrain()
    private var clearTimer: Timer?

    init(model: BuddyModel, settings: BuddySettings) {
        self.model = model
        self.settings = settings
        listener.onPartial = { [weak self] text in self?.model.setVoice(.listening(text)) }
        listener.onFinish = { [weak self] text in self?.heard(text) }
        listener.onError = { [weak self] message in self?.answer(message) }
    }

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
            clearTimer?.invalidate()
            Speaker.shared.stop()
            model.setVoice(.listening(""))
            listener.start()
        }
    }

    /// Starts a fresh conversation (the buddy forgets earlier requests).
    func newConversation() {
        gemini.reset()
        Speaker.shared.say("Fresh start! What's up?")
    }

    private func heard(_ text: String) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else {
            answer("I didn't catch that. Try again?")
            return
        }
        // Simple things happen instantly, without using Gemini: open apps, play songs, volume, timers…
        if settings.instantCommands, let done = QuickCommands.handle(request) {
            answer(done)
            return
        }
        // Everything else goes to Gemini, which answers or does it on your Mac.
        model.setVoice(.thinking)
        gemini.ask(request, canAct: settings.geminiActs) { [weak self] reply in
            guard let self, self.model.voice == .thinking else { return }
            self.answer(reply)
        }
    }

    private func answer(_ text: String) {
        model.setVoice(.answering(text))
        Speaker.shared.say(text)
        // Keep the answer on screen about as long as it takes to say it.
        let words = Double(text.split(separator: " ").count)
        clearTimer?.invalidate()
        clearTimer = Timer.scheduledTimer(withTimeInterval: max(3, words / 2.6 + 1.5), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .answering(_) = self.model.voice else { return }
                self.model.setVoice(.off)
            }
        }
    }
}
