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
    private let onDevice = OnDeviceBrain()
    private var thinkingTask: Task<Void, Never>?
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
            thinkingTask?.cancel()
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
        onDevice.reset()
        Speaker.shared.say("Fresh start! What's up?")
    }

    private func heard(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            answer("I didn't catch that. Try again?")
            return
        }
        // 1. Things it can just do, instantly and for free: open apps, search, volume, timers…
        if let done = QuickCommands.handle(question) {
            answer(done)
            return
        }
        model.setVoice(.thinking)

        // 2. "Do anything" mode: an agent that can act on the Mac (Cursor's agent or Claude Code).
        if settings.assistantActions {
            askAgent(question, fallbackToOnDevice: true)
            return
        }

        // 3. Questions: Apple's free on-device AI when this Mac has it…
        if OnDeviceBrain.isAvailable {
            thinkingTask = Task { [weak self] in
                guard let self else { return }
                let reply = await self.onDevice.ask(question)
                guard !Task.isCancelled, self.model.voice == .thinking else { return }
                self.answer(reply)
            }
            return
        }

        // 4. …otherwise Claude Code or Cursor's agent, if one is installed.
        askAgent(question, fallbackToOnDevice: false)
    }

    private func askAgent(_ question: String, fallbackToOnDevice: Bool) {
        assistant.ask(question, brain: .auto, allowActions: settings.assistantActions,
                      folder: NSHomeDirectory()) { [weak self] reply, notFound in
            guard let self, self.model.voice == .thinking else { return }
            if notFound {
                if fallbackToOnDevice, OnDeviceBrain.isAvailable {
                    self.thinkingTask = Task { [weak self] in
                        guard let self else { return }
                        let reply = await self.onDevice.ask(question)
                        guard !Task.isCancelled, self.model.voice == .thinking else { return }
                        self.answer(reply)
                    }
                } else if self.settings.assistantActions {
                    self.answer("To do anything you ask, I need Cursor's agent. Open Terminal and install it, then run agent login. I can still do simple commands like open Safari.")
                } else {
                    self.answer(OnDeviceBrain.unavailableReason)
                }
            } else if !reply.isEmpty {
                self.answer(reply)
            }
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
