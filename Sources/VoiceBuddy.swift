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
    let fast = FastGemini()
    private var clearTimer: Timer?
    /// Listen for a reply once the current line has been spoken.
    private var listenAfterSpeaking = false
    /// The current listen was started by the buddy itself (silence just ends the chat).
    private var followUp = false

    init(model: BuddyModel, settings: BuddySettings) {
        self.model = model
        self.settings = settings
        listener.onPartial = { [weak self] text in self?.model.setVoice(.listening(text)) }
        listener.onFinish = { [weak self] result in self?.received(result) }
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
            fast.cancel()
            model.setVoice(.off)
            Speaker.shared.say("Okay, never mind.")
        case .off, .answering(_):
            listen(followUp: false)
        }
    }

    /// Starts a fresh conversation (the buddy forgets earlier requests).
    func newConversation() {
        gemini.reset()
        fast.reset()
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

    /// With a Groq key, the recording goes to Whisper (much better for Urdu, Punjabi and mixed
    /// speech); Apple's text is the backup.
    private func received(_ result: Heard) {
        guard let audio = result.audio, Whisper.isAvailable else {
            if result.text.isEmpty, let problem = result.problem, !followUp {
                answer(problem, thenListen: false)
            } else {
                heard(result.text)
            }
            return
        }
        model.setVoice(.thinking)
        Task { [weak self] in
            let text = await Whisper.transcribe(audio, language: self?.settings.language ?? "auto")
            guard let self, self.model.voice == .thinking else { return }
            let best = (text?.isEmpty == false) ? text! : result.text
            if best.isEmpty, let problem = result.problem, !self.followUp {
                self.answer(problem, thenListen: false)
            } else {
                self.heard(best)
            }
        }
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

        // "Be quiet" / "chup karo": stop talking by itself. "You can talk again": back to normal.
        if Self.matches(request, ["be quiet", "stop talking", "don't talk", "dont talk", "shut up", "chup", "chup karo",
                                  "khamosh", "chup ho jao", "baat mat karo", "چپ", "خاموش"]) {
            settings.chattiness = 0
            answer("Okay, I'll stay quiet. Double-click me when you need me.", thenListen: false)
            return
        }
        if Self.matches(request, ["you can talk again", "talk to me again", "start talking", "baat karo", "baatein karo"]) {
            settings.chattiness = 1
            answer("Yay! I'll chat now and then.", thenListen: false)
            return
        }

        // Simple things happen instantly, without using Gemini: open apps, play songs, volume, timers…
        if settings.instantCommands,
           let done = QuickCommands.handle(request) ?? QuickCommands.handle(Lingo.englishCommand(request)) {
            answer(done, thenListen: false)
            return
        }
        model.setVoice(.thinking)

        // Fast path: chat straight with the Gemini API (about a second). Only requests that need
        // doing something on the Mac go to the slower agent.
        if settings.brain != "cursor", FastGemini.isAvailable {
            fast.chat(request, system: FastGemini.chatSystem(language: settings.language, canAct: settings.geminiActs)) { [weak self] outcome in
                guard let self, self.model.voice == .thinking else { return }
                switch outcome {
                case .reply(let text):
                    self.answer(text, thenListen: keepTalking)
                case .action:
                    self.askAgent(request, keepTalking: keepTalking)
                case .failed(let problem):
                    self.answer(problem.isEmpty ? "Sorry, something went wrong." : problem, thenListen: false)
                }
            }
            return
        }
        askAgent(request, keepTalking: keepTalking)
    }

    /// The Antigravity agent: slower, but it can act on the Mac.
    private func askAgent(_ request: String, keepTalking: Bool) {
        let cursor = settings.brain == "cursor"
        if !cursor, FastGemini.isAvailable, settings.geminiActs {
            // A quick "on it" so you know it's working while the agent starts.
            Speaker.shared.say(Self.onIt(settings.language))
        } else {
            // The agent takes a few seconds: say a little "hmm" if it's still thinking after 3 s.
            let asked = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.model.voice == .thinking, !Speaker.shared.isSpeaking,
                          Date().timeIntervalSince(asked) >= 2.9 else { return }
                    Speaker.shared.say(["Hmm, let me think.", "One sec.", "Hmm."].randomElement()!)
                }
            }
        }
        gemini.ask(request, canAct: settings.geminiActs, language: settings.language,
                   cursor: cursor, cursorModel: settings.cursorModel) { [weak self] reply in
            guard let self, self.model.voice == .thinking else { return }
            self.fast.remember(user: request, reply: Lingo.split(reply).show)
            self.answer(reply, thenListen: keepTalking)
        }
    }

    private static func onIt(_ language: String) -> String {
        language == "en" ? ["On it!", "Okay, doing it now.", "Sure, one moment."].randomElement()!
                         : ["अच्छा, अभी करता हूँ।", "ठीक है, एक मिनट।", "On it!"].randomElement()!
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

    private static func matches(_ text: String, _ phrases: [String]) -> Bool {
        let t = " " + text.lowercased().filter { $0.isLetter || $0 == " " || $0 == "'" } + " "
        return phrases.contains { t.contains(" \($0) ") }
    }

    /// "Thanks", "bye", "that's all"… ends the conversation instead of listening again.
    private static func isGoodbye(_ text: String) -> Bool {
        let t = " " + text.lowercased().filter { $0.isLetter || $0 == " " || $0 == "'" } + " "
        return ["bye", "goodbye", "good night", "goodnight", "that's all", "thats all", "thank you",
                "thanks", "stop", "never mind", "nevermind", "shut up", "be quiet", "allah hafiz", "khuda hafiz"]
            .contains { t.contains(" \($0) ") }
    }
}
