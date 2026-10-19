import Foundation
import Security

// MARK: - API key (kept in the macOS Keychain)

/// An API key kept in the macOS Keychain.
final class KeychainKey: @unchecked Sendable {
    private let service: String
    private var cached: String?
    private let lock = NSLock()

    init(service: String) { self.service = service }

    var value: String? {
        lock.lock(); defer { lock.unlock() }
        if cached == nil { cached = read() ?? "" }
        return cached?.isEmpty == false ? cached : nil
    }

    func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); cached = trimmed; lock.unlock()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        guard !trimmed.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    private func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

let GeminiKey = KeychainKey(service: "io.github.mohsin2596.macbuddy.gemini-api-key")
let GroqKey = KeychainKey(service: "io.github.mohsin2596.macbuddy.groq-api-key")

// MARK: - Fast chat straight to Groq or the Gemini API

/// Talks to Gemini directly over HTTPS (about a second per answer), instead of starting the
/// Antigravity agent for every question. Requests that need doing something on the Mac come back
/// as `.action` so the agent can handle them.
@MainActor
final class FastGemini {
    enum Outcome {
        case reply(String)
        case action            // needs to do something on the Mac: hand it to the agent
        case failed(String)
    }

    private var history: [(role: String, text: String)] = []
    private var lastUsed = Date.distantPast
    private var task: Task<Void, Never>?
    /// The first model that worked, so later requests go straight to it.
    nonisolated(unsafe) private static var workingModel: String?
    private static let models = ["gemini-3.5-flash-lite", "gemini-flash-lite-latest", "gemini-flash-latest"]

    static var isAvailable: Bool { GroqKey.value != nil || GeminiKey.value != nil }

    func reset() { history = [] }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Remembers a turn that was answered elsewhere (by the agent), so follow-ups have context.
    func remember(user: String, reply: String) {
        history.append((role: "user", text: user))
        history.append((role: "model", text: reply))
        trim()
    }

    /// A chat turn. `system` is the persona and rules.
    func chat(_ text: String, system: String, completion: @escaping @MainActor (Outcome) -> Void) {
        if Date().timeIntervalSince(lastUsed) > 15 * 60 { history = [] }
        lastUsed = Date()
        let turns = history + [(role: "user", text: text)]
        task?.cancel()
        task = Task { [weak self] in
            let outcome = await Self.generate(turns: turns, system: system)
            guard !Task.isCancelled, let self else { return }
            if case .reply(let answer) = outcome {
                self.history.append((role: "user", text: text))
                self.history.append((role: "model", text: answer))
                self.trim()
            }
            completion(outcome)
        }
    }

    /// A one-off line (no history), e.g. something the buddy says by itself. nil on failure.
    static func oneShot(_ prompt: String) async -> String? {
        if case .reply(let text) = await generate(turns: [(role: "user", text: prompt)], system: nil) { return text }
        return nil
    }

    private func trim() {
        if history.count > 24 { history.removeFirst(history.count - 24) }
    }

    // MARK: HTTP

    /// Groq first (fastest) when there's a Groq key, then Gemini.
    private static func generate(turns: [(role: String, text: String)], system: String?) async -> Outcome {
        if let groq = GroqKey.value {
            let outcome = await groqGenerate(turns: turns, system: system, key: groq)
            if case .failed(let problem) = outcome, GeminiKey.value != nil, !problem.isEmpty {
                voiceLog("groq failed (\(problem)); trying Gemini")
                return await geminiGenerate(turns: turns, system: system)
            }
            return outcome
        }
        return await geminiGenerate(turns: turns, system: system)
    }

    // MARK: Groq (OpenAI-compatible)

    nonisolated(unsafe) private static var groqModel: String?
    private static let groqModels = ["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "openai/gpt-oss-20b"]

    /// Asks Groq which models this key can use, best chat models first.
    private static func groqAvailableModels(key: String) async -> [String] {
        guard let url = URL(string: "https://api.groq.com/openai/v1/models") else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let pair = try? await URLSession.shared.data(for: request),
              let json = (try? JSONSerialization.jsonObject(with: pair.0)) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return [] }
        let ids = list.compactMap { entry -> String? in
            guard let id = entry["id"] as? String else { return nil }
            if (entry["active"] as? Bool) == false { return nil }
            let lower = id.lowercased()
            // Skip speech, safety and other non-chat models.
            let skip = ["whisper", "guard", "tts", "playai", "orpheus", "distil", "embed", "prompt-guard", "safeguard", "compound"]
            return skip.contains { lower.contains($0) } ? nil : id
        }
        func score(_ id: String) -> Int {
            let l = id.lowercased()
            var s = 0
            if l.contains("llama") { s += 30 }
            if l.contains("70b") || l.contains("maverick") { s += 25 }
            if l.contains("gpt-oss-20b") { s += 28 }
            if l.contains("gpt-oss-120b") { s += 20 }
            if l.contains("qwen") || l.contains("kimi") { s += 15 }
            if l.contains("instant") || l.contains("8b") || l.contains("scout") { s += 10 }
            if l.contains("preview") { s -= 5 }
            return s
        }
        let sorted = ids.sorted { score($0) > score($1) }
        voiceLog("groq models for this key: \(sorted.prefix(8).joined(separator: ", "))")
        return sorted
    }

    private static func groqGenerate(turns: [(role: String, text: String)], system: String?, key: String) async -> Outcome {
        let started = Date()
        var models = groqModel.map { first in [first] + groqModels.filter { $0 != first } } ?? groqModels
        if groqModel == nil {
            // Use what this key actually has; the default names are only a fallback.
            let available = await groqAvailableModels(key: key)
            if !available.isEmpty { models = Array(available.prefix(4)) }
        }
        var messages: [[String: String]] = []
        if let system { messages.append(["role": "system", "content": system]) }
        messages += turns.map { ["role": $0.role == "model" ? "assistant" : "user", "content": $0.text] }

        var lastStatus = 0
        var lastDetail = ""
        for model in models {
            guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else { break }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let body: [String: Any] = ["model": model, "messages": messages, "max_tokens": 400, "temperature": 0.7]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            guard let pair = try? await URLSession.shared.data(for: request) else {
                return .failed(Task.isCancelled ? "" : "I couldn't reach Groq. Check your internet connection.")
            }
            let (data, response) = pair
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                groqModel = model
                voiceLog("groq (\(model)) took \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let answer = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !answer.isEmpty else { return .failed("Sorry, I didn't get an answer. Try again.") }
                let shown = Lingo.split(answer).show.uppercased()
                if shown.hasPrefix("ACTION") && shown.count < 20 { return .action }
                return .reply(answer)
            }
            let text = String(decoding: data, as: UTF8.self)
            voiceLog("groq (\(model)) HTTP \(status): \(text.prefix(300))")
            lastStatus = status
            lastDetail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }.flatMap { $0["message"] as? String } ?? ""
            if status == 401 { return .failed("Your Groq API key isn't working. Check it in my settings.") }
            if status == 404, groqModel == model { groqModel = nil }   // the saved model went away: look again next time
            if status == 403 { return .failed("Groq refused the request. It may not be available in your country, or the key is limited.") }
            continue   // 400, 404, 413, 429, 5xx: try the next model
        }
        switch lastStatus {
        case 429: return .failed("I've hit the Groq limit for now. Try again in a minute.")
        case 0: return .failed("I couldn't reach Groq.")
        default:
            return .failed("Groq couldn't answer\(lastDetail.isEmpty ? "" : ": " + String(lastDetail.prefix(80))).")
        }
    }

    // MARK: Gemini

    private static func geminiGenerate(turns: [(role: String, text: String)], system: String?) async -> Outcome {
        guard let key = GeminiKey.value else { return .failed("No API key.") }
        let started = Date()
        let candidates = workingModel.map { first in [first] + models.filter { $0 != first } } ?? models
        var lastProblem = "Sorry, I couldn't reach Gemini. Please try again."
        for model in candidates {
            for withThinkingSetting in [true, false] {
                var body: [String: Any] = [
                    "contents": turns.map { ["role": $0.role, "parts": [["text": $0.text]]] },
                ]
                if let system { body["system_instruction"] = ["parts": [["text": system]]] }
                if withThinkingSetting { body["generationConfig"] = ["thinkingConfig": ["thinkingLevel": "low"]] }

                guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")
                else { continue }
                var request = URLRequest(url: url, timeoutInterval: 25)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                guard let pair = try? await URLSession.shared.data(for: request) else {
                    return .failed(Task.isCancelled ? "" : "I couldn't reach Gemini. Check your internet connection.")
                }
                let (data, response) = pair
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let text = String(decoding: data, as: UTF8.self)
                if status == 200 {
                    workingModel = model
                    let answer = replyText(data)
                    voiceLog("fast gemini (\(model)) took \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                    guard let answer, !answer.isEmpty else { return .failed("Sorry, I didn't get an answer. Try again.") }
                    let plain = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                    let shown = Lingo.split(plain).show.uppercased()
                    if shown.hasPrefix("ACTION") && shown.count < 20 { return .action }
                    return .reply(plain)
                }
                voiceLog("fast gemini (\(model)) HTTP \(status): \(text.prefix(200))")
                if status == 400, text.lowercased().contains("thinking"), withThinkingSetting { continue }   // retry without it
                if status == 400 || status == 401 || status == 403, text.contains("API_KEY") || text.lowercased().contains("api key") {
                    return .failed("Your Gemini API key isn't working. Check it in my settings.")
                }
                if status == 429 { return .failed("I've hit the Gemini limit for now. Try again in a minute.") }
                if status == 404 { break }   // try the next model
                lastProblem = "Gemini had a problem answering. Please try again."
                break
            }
        }
        return .failed(lastProblem)
    }

    /// candidates[0].content.parts[*].text, skipping the model's private "thought" parts.
    private static func replyText(_ data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        return parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
    }

    // MARK: Persona

    static func chatSystem(language: String, canAct: Bool) -> String {
        let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? "friend"
        let doing = canAct
            ? "If they ask you to DO something on their Mac (open, create, change or control apps, files, notes, reminders, calendar, music, settings, and so on), reply with exactly the single word ACTION and nothing else. Simple questions and chatting you answer yourself."
            : "You can't control their Mac. If they ask you to do something on it, say briefly that you can only chat right now."
        return """
        You are Mac Buddy, a little companion living on \(name)'s Mac, and their close friend. \
        \(Personality.tone()) Use their name now and then. They talk to you by voice: \
        their words come from speech recognition and may contain small mistakes, so work out what they most \
        likely meant. Your reply is read aloud, so answer in plain spoken language in one or two short \
        sentences, with no markdown, lists, emoji or links. \(doing)
        \(Lingo.rules(language))
        """
    }
}
