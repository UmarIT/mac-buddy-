import AVFoundation
import Speech

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

    /// Asks for permission the first time, then starts listening.
    func start() {
        guard !isListening else { return }
        isListening = true
        transcript = ""
        SFSpeechRecognizer.requestAuthorization(Self.onMain { [weak self] (status: SFSpeechRecognizerAuthorizationStatus) in
            guard let self, self.isListening else { return }
            guard status == .authorized else {
                self.fail("Speech recognition is turned off for Mac Buddy. Turn it on in System Settings, Privacy and Security, Speech Recognition.")
                return
            }
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: Self.onMain { [weak self] (granted: Bool) in
                guard let self, self.isListening else { return }
                guard granted else {
                    self.fail("I can't hear you. Allow microphone access for Mac Buddy in System Settings, Privacy and Security, Microphone.")
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
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            fail("Speech recognition isn't available right now. Check your internet connection.")
            return
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true   // keeps your voice on your Mac
        }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("I couldn't find a microphone.")
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(for: request))

        engine.prepare()
        do {
            try engine.start()
        } catch {
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

    fileprivate func handle(text: String?, isFinal: Bool, failed: Bool) {
        guard isListening else { return }
        if let text, !text.isEmpty, text != transcript {
            transcript = text
            onPartial?(text)
            restartSilenceTimer(after: 1.6)   // a short pause means you're done talking
        }
        if isFinal || failed { finish() }
    }

    private func restartSilenceTimer(after seconds: TimeInterval) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    private func finish() {
        let heard = transcript
        teardown()
        onFinish?(heard)
    }

    private func fail(_ message: String) {
        teardown()
        onError?(message)
    }

    private func teardown() {
        isListening = false
        silenceTimer?.invalidate(); silenceTimer = nil
        limitTimer?.invalidate(); limitTimer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
        recognizer = nil
    }

    // Callbacks from Apple's frameworks arrive on background threads. These helpers are
    // nonisolated so the closures they build don't assume the main thread, and they hop back
    // to the main thread before touching any state.

    nonisolated private static func onMain<T>(_ body: @escaping @MainActor (T) -> Void) -> (T) -> Void {
        { value in DispatchQueue.main.async { MainActor.assumeIsolated { body(value) } } }
    }

    nonisolated private static func tapBlock(for request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func resultHandler(for owner: Listener) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        weak var owner = owner
        return { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { owner?.handle(text: text, isFinal: isFinal, failed: failed) }
            }
        }
    }
}
