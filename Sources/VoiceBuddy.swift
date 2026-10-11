import Foundation

/// What the buddy is doing in a voice conversation.
enum VoiceState: Equatable {
    case off
    case listening(String)   // what it has heard so far
    case thinking
    case answering(String)

    var isActive: Bool { self != .off }
}

/// Ties it together: listen → ask Claude Code → speak the answer.
@MainActor
final class VoiceBuddy {
    private let model: BuddyModel
    private let settings: BuddySettings
    private let listener = Listener()
    private let assistant = Assistant()
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
        switch model.voice {
        case .listening(_):
            listener.stop()
        case .thinking:
            assistant.cancel()
            model.setVoice(.off)
            Speaker.shared.say("Okay, never mind.")
        case .off, .answering(_):
            clearTimer?.invalidate()
            Speaker.shared.stop()
            model.setVoice(.listening(""))
            listener.start()
        }
    }

    /// Starts a fresh conversation (the buddy forgets earlier questions).
    func newConversation() {
        assistant.reset()
        Speaker.shared.say("Fresh start! What's up?")
    }

    private func heard(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            answer("I didn't catch that. Try again?")
            return
        }
        model.setVoice(.thinking)
        assistant.ask(question, allowActions: settings.assistantActions, folder: NSHomeDirectory()) { [weak self] reply in
            guard let self, self.model.voice == .thinking, !reply.isEmpty else { return }
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
