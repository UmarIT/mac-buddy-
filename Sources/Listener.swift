import AppKit
import AVFoundation
import Speech

/// Appends a line to ~/.mac-buddy/voice.log so listening problems can be diagnosed.
func voiceLog(_ message: String) {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mac-buddy")
    let url = dir.appendingPathComponent("voice.log")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    let line = "\(f.string(from: Date())) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Listens to the microphone and turns speech into text. Stops by itself after a short pause.
@MainActor
final class Listener {
    var onPartial: ((String) -> Void)?
    /// Called once per listen with what was heard ("" if nothing).
    var onFinish: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var isListening = false
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var transcript = ""
    private var silenceTimer: Timer?
    private var limitTimer: Timer?
    /// The last error from speech recognition, e.g. "kAFAssistantErrorDomain 1101: …".
    private var lastError: String?

    /// Asks for permission the first time, then starts listening.
    func start() {
        guard !isListening else { return }
        isListening = true
        transcript = ""
        lastError = nil
        AudioLevel.shared.startSession()
        SFSpeechRecognizer.requestAuthorization(Self.onMain { [weak self] (status: SFSpeechRecognizerAuthorizationStatus) in
            guard let self, self.isListening else { return }
            guard status == .authorized else {
                Self.openPrivacySettings("Privacy_SpeechRecognition")
                self.fail("Speech recognition is blocked for Mac Buddy. I opened the settings: switch Mac Buddy on, then try again.")
                return
            }
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: Self.onMain { [weak self] (granted: Bool) in
                guard let self, self.isListening else { return }
                guard granted else {
                    Self.openPrivacySettings("Privacy_Microphone")
                    self.fail("The microphone is blocked for Mac Buddy. I opened the settings: switch Mac Buddy on, then try again.")
                    return
                }
                self.begin()
            })
        })
    }

    /// Stops now and delivers whatever was heard so far.
    func stop() {
        guard isListening else { return }
        finish()
    }

    /// Stops without delivering anything.
    func cancel() {
        guard isListening else { return }
        teardown()
    }

    // MARK: Internals

    private func begin() {
        // Your Mac's language first; if that isn't supported (e.g. English (Pakistan)), US English.
        let candidates = [SFSpeechRecognizer(), SFSpeechRecognizer(locale: Locale(identifier: "en-US"))].compactMap { $0 }
        guard let recognizer = candidates.first(where: { $0.isAvailable }) else {
            fail("Speech recognition isn't available right now. Check your internet connection, and that Dictation is on in System Settings, Keyboard.")
            return
        }
        self.recognizer = recognizer
        voiceLog("start: locale=\(recognizer.locale.identifier) available=\(recognizer.isAvailable) onDevice=\(recognizer.supportsOnDeviceRecognition) speechAuth=\(SFSpeechRecognizer.authorizationStatus().rawValue) micAuth=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Let macOS use its online recognizer when the on-device one isn't downloaded.
        request.requiresOnDeviceRecognition = false
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("I couldn't find a microphone.")
            return
        }
        voiceLog("mic format: \(format.sampleRate) Hz, \(format.channelCount) channel(s)")
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(for: request))

        engine.prepare()
        do {
            try engine.start()
        } catch {
            voiceLog("engine start failed: \(error)")
            fail("I couldn't start the microphone.")
            return
        }

        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(for: self))

        // Give up if nothing is said, and never listen for too long.
        restartSilenceTimer(after: 7)
        limitTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    fileprivate func handle(text: String?, isFinal: Bool, error: String?) {
        guard isListening else { return }
        if let text, !text.isEmpty, text != transcript {
            transcript = text
            onPartial?(text)
            restartSilenceTimer(after: 1.6)   // a short pause means you're done talking
        }
        if let error { lastError = error; voiceLog("recognition error: \(error)") }
        if isFinal || error != nil { finish() }
    }

    private func restartSilenceTimer(after seconds: TimeInterval) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    private func finish() {
        let heard = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let peak = AudioLevel.shared.peak
        let error = lastError
        voiceLog("finish: heard=\"\(heard)\" peak=\(String(format: "%.2f", peak)) error=\(error ?? "none")")
        teardown()
        guard heard.isEmpty else {
            onFinish?(heard)
            return
        }
        // Nothing came through: say why, when we can tell.
        let lower = (error ?? "").lowercased()
        if lower.contains("1101") || lower.contains("1700") || lower.contains("dictation") || lower.contains("siri") {
            Self.openSettings("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
            onError?("I need Dictation to understand you. I opened Keyboard settings: turn on Dictation, then try again.")
        } else if peak < 0.12 {
            onError?("I didn't hear anything. Check that the right microphone is selected in System Settings, Sound, Input, then try again.")
        } else if error != nil {
            Self.openSettings("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
            onError?("I heard you but couldn't turn it into words. Make sure Dictation is on in Keyboard settings, then try again.")
        } else {
            onFinish?("")
        }
    }

    private func fail(_ message: String) {
        teardown()
        onError?(message)
    }

    private func teardown() {
        isListening = false
        AudioLevel.shared.reset()
        silenceTimer?.invalidate(); silenceTimer = nil
        limitTimer?.invalidate(); limitTimer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
        recognizer = nil
    }

    /// Opens System Settings at Privacy & Security → the given pane.
    private static func openPrivacySettings(_ pane: String) {
        openSettings("x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }

    private static func openSettings(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    // Callbacks from Apple's frameworks arrive on background threads. These helpers are
    // nonisolated so the closures they build don't assume the main thread, and they hop back
    // to the main thread before touching any state.

    nonisolated private static func onMain<T: Sendable>(
        _ body: @escaping @MainActor @Sendable (T) -> Void
    ) -> @Sendable (T) -> Void {
        { value in DispatchQueue.main.async { MainActor.assumeIsolated { body(value) } } }
    }

    nonisolated private static func tapBlock(for request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            // Loudness for the live voice wave in the bubble.
            guard let samples = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in 0..<n { sum += samples[i] * samples[i] }
            AudioLevel.shared.push((sum / Float(n)).squareRoot())
        }
    }

    nonisolated private static func resultHandler(for owner: Listener) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        return { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let problem = error.map { e -> String in
                let ns = e as NSError
                return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { owner?.handle(text: text, isFinal: isFinal, error: problem) }
            }
        }
    }
}
