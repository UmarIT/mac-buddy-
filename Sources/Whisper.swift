import Foundation

// MARK: - Recording what you said

/// Keeps the microphone audio of one listen (up to 30 s), written from the audio thread.
final class AudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var rate: Double = 16_000

    func start(sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        rate = sampleRate
        samples = []
        samples.reserveCapacity(Int(sampleRate * 10))
    }

    func append(_ pointer: UnsafePointer<Float>, count: Int) {
        lock.lock(); defer { lock.unlock() }
        guard samples.count < Int(rate * 30) else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: count))
    }

    /// The recording as a 16-bit mono WAV file, at about 16 kHz (plenty for speech, small upload).
    func wav() -> Data? {
        lock.lock()
        let source = samples
        let sourceRate = rate
        lock.unlock()
        guard source.count > Int(sourceRate * 0.3) else { return nil }   // under 0.3 s: nothing to send

        let factor = max(1, Int(sourceRate / 16_000))
        let outRate = Int(sourceRate) / factor
        var pcm = [Int16]()
        pcm.reserveCapacity(source.count / factor + 1)
        var i = 0
        while i + factor <= source.count {
            var sum: Float = 0
            for j in 0..<factor { sum += source[i + j] }
            let v = max(-1, min(1, sum / Float(factor)))
            pcm.append(Int16(v * 32_767))
            i += factor
        }

        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(pcm.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(outRate)); u32(UInt32(outRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        pcm.withUnsafeBufferPointer { buffer in
            for sample in buffer { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
        }
        return data
    }
}

// MARK: - Groq Whisper speech-to-text

/// Turns a recording into text with Groq's free Whisper models: far better than Apple's
/// recognizer for Urdu, Punjabi and mixed speech. Needs a Groq key.
enum Whisper {
    static var isAvailable: Bool { GroqKey.value != nil }

    static func transcribe(_ wav: Data, language: String) async -> String? {
        guard let key = GroqKey.value,
              let url = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions") else { return nil }
        let started = Date()
        for model in ["whisper-large-v3-turbo", "whisper-large-v3"] {
            let boundary = "MacBuddy-\(UUID().uuidString)"
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            field("model", model)
            field("response_format", "json")
            field("temperature", "0")
            if ["en", "ur", "pa"].contains(language) { field("language", language) }
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
            body.append(wav)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))

            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body

            guard let pair = try? await URLSession.shared.data(for: request) else {
                voiceLog("whisper: couldn't reach Groq")
                return nil
            }
            let status = (pair.1 as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200,
               let json = (try? JSONSerialization.jsonObject(with: pair.0)) as? [String: Any],
               let text = json["text"] as? String {
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                voiceLog("whisper (\(model)) took \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \"\(clean)\"")
                return isHallucination(clean) ? "" : clean
            }
            voiceLog("whisper (\(model)) HTTP \(status): \(String(decoding: pair.0, as: UTF8.self).prefix(200))")
            if status == 404 || status == 400 { continue }   // model not on this account: try the other
            return nil
        }
        return nil
    }

    /// Whisper sometimes "hears" these stock phrases in noise.
    private static func isHallucination(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return ["thank you for watching", "thanks for watching", "please subscribe", "subtitles by the amara.org community",
                "you", ""].contains(t)
    }
}
