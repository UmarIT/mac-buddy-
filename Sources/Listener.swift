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

/// The result of one listen.
struct Heard {
    /// What Apple's recognizer understood ("" if nothing).
    let text: String
    /// The recording, when you actually spoke (for a better transcription with Whisper).
    let audio: Data?
    /// Why nothing was understood, when we can tell (e.g. Dictation is off).
    let problem: String?
}

/// Listens to the microphone and turns speech into text. Stops by itself shortly after you stop
/// talking (judged by the sound level, and by the words coming in).
@MainActor
final class Listener {
    var onPartial: ((String) -> Void)?
    /// Called once per listen.
    var onFinish: ((Heard) -> Void)?
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

    /// True when listening for a reply on its own: silence then just ends quietly.
    private var quiet = false
    private var firstWait: TimeInterval = 7
    private var locales: [String] = []

    // Recording and voice-activity detection.
    private let recorder = AudioRecorder()
    private var vadTimer: Timer?
    private var startedAt = Date()
    private var lastLoud = Date()
    private var noiseFloor = 0.0
    private var spoke = false

    /// Asks for permission the first time, then starts listening. `quiet`: if nothing is said,
    /// finish silently (used when the buddy listens for your reply by itself).
    func start(quiet: Bool = false, firstWait: TimeInterval = 7, locales: [String] = []) {
        guard !isListening else { return }
        self.quiet = quiet
        self.firstWait = firstWait
        self.locales = locales
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
        // The chosen languages first; then your Mac's language; then US English.
        let candidates = (locales.map { SFSpeechRecognizer(locale: Locale(identifier: $0)) }
            + [SFSpeechRecognizer(), SFSpeechRecognizer(locale: Locale(identifier: "en-US"))]).compactMap { $0 }
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
        recorder.start(sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(for: request, recorder: recorder))

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
        restartSilenceTimer(after: firstWait)
        startedAt = Date()
        lastLoud = Date()
        noiseFloor = 0
        spoke = false
        vadTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkVoiceActivity() }
        }
        limitTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    fileprivate func handle(text: String?, isFinal: Bool, error: String?) {
        guard isListening else { return }
        if let text, !text.isEmpty, text != transcript {
            transcript = text
            onPartial?(text)
            restartSilenceTimer(after: 1.1)   // a short pause means you're done talking
        }
        if let error { lastError = error; voiceLog("recognition error: \(error)") }
        if isFinal || error != nil { finish() }
    }

    /// Ends the listen about a second after your voice stops (louder than the room's background).
    private func checkVoiceActivity() {
        guard isListening else { return }
        let level = AudioLevel.shared.value
        let now = Date()
        if now.timeIntervalSince(startedAt) < 0.35 {   // measure the room first
            noiseFloor = max(noiseFloor, level)
            return
        }
        let threshold = min(0.75, max(0.3, noiseFloor + 0.18))
        if level > threshold {
            lastLoud = now
            if !spoke {
                spoke = true
                silenceTimer?.invalidate()   // you started talking: no more "nothing said" timeout
                voiceLog("speech started (level \(String(format: "%.2f", level)), threshold \(String(format: "%.2f", threshold)))")
            }
        }
        if spoke, now.timeIntervalSince(lastLoud) > 1.0 { stop() }
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
        let audio = (spoke || !heard.isEmpty) ? recorder.wav() : nil
        voiceLog("finish: heard=\"\(heard)\" peak=\(String(format: "%.2f", peak)) spoke=\(spoke) audio=\(audio?.count ?? 0)B error=\(error ?? "none")")
        teardown()
        guard heard.isEmpty, !quiet else {
            onFinish?(Heard(text: heard, audio: audio, problem: nil))
            return
        }
        // Nothing understood: say why, when we can tell (Whisper may still understand the recording).
        let lower = (error ?? "").lowercased()
        var problem: String?
        if lower.contains("1101") || lower.contains("1700") || lower.contains("dictation") || lower.contains("siri") {
            problem = "I need Dictation to understand you. Turn on Dictation in System Settings, Keyboard, or add a free Groq key in my Voice settings."
        } else if peak < 0.12 {
            problem = "I didn't hear anything. Check that the right microphone is selected in System Settings, Sound, Input, then try again."
        } else if error != nil {
            problem = "I heard you but couldn't turn it into words. Make sure Dictation is on in Keyboard settings, or add a free Groq key in my Voice settings."
        }
        onFinish?(Heard(text: "", audio: audio, problem: problem))
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
        vadTimer?.invalidate(); vadTimer = nil
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

    nonisolated private static func tapBlock(for request: SFSpeechAudioBufferRecognitionRequest,
                                             recorder: AudioRecorder) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            // Loudness for the live voice wave in the bubble, and the recording for Whisper.
            guard let samples = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            recorder.append(samples, count: n)
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
