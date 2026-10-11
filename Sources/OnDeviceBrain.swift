import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Free, private answers from Apple's on-device AI model (Apple Intelligence, macOS 26+).
/// Nothing is sent to the internet and no account is needed. Follow-up questions remember the
/// conversation for 15 minutes.
@MainActor
final class OnDeviceBrain {
    private var session: AnyObject?
    private var lastUsed = Date.distantPast

    private static let instructions = """
    You are Mac Buddy, a cheerful little desktop companion on the user's Mac, talking with them by \
    voice. Their words come from speech recognition and may contain small mistakes, so work out \
    what they most likely meant. Your reply is read aloud, so answer in plain spoken language in at \
    most three short sentences, with no markdown, lists, emoji or links. You cannot control the Mac \
    yourself. If they ask you to do something on the Mac, tell them to say a command like \
    "open Safari", "search for cats", "volume up" or "set a timer for 5 minutes".
    """

    /// Whether Apple's model can be used right now.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Why it can't be used, in words to say out loud.
    static var unavailableReason: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return ""
            case .unavailable(let reason):
                let why = String(describing: reason)
                if why.contains("NotEnabled") {
                    return "To answer questions, turn on Apple Intelligence in System Settings. I can still open apps, search, set timers and change the volume."
                }
                if why.contains("NotReady") {
                    return "Apple Intelligence is still getting ready. Try again in a little while. Meanwhile I can open apps, search and set timers."
                }
                return "This Mac can't run Apple's on-device AI, so I can only do commands like open Safari, search for something, volume up, or set a timer."
            @unknown default:
                return "Apple's on-device AI isn't available right now. I can still open apps, search and set timers."
            }
        }
        #endif
        return "To answer questions for free, I need macOS 26 with Apple Intelligence. For now I can do commands like open Safari, search for something, volume up, or set a timer."
    }

    func reset() { session = nil }

    func ask(_ question: String) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if Date().timeIntervalSince(lastUsed) > 15 * 60 { session = nil }
            lastUsed = Date()
            let current = (session as? LanguageModelSession) ?? LanguageModelSession(instructions: Self.instructions)
            session = current
            do {
                let response = try await current.respond(to: question)
                return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                session = nil   // e.g. the conversation got too long; start fresh next time
                return "Sorry, I couldn't answer that one. Try asking another way."
            }
        }
        #endif
        return Self.unavailableReason
    }
}
