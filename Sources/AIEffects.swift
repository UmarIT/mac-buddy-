import SwiftUI

// MARK: - Microphone level (for the live voice wave)

/// The latest microphone loudness, 0…1, written from the audio thread and read while drawing.
final class AudioLevel: @unchecked Sendable {
    static let shared = AudioLevel()
    private let lock = NSLock()
    private var level = 0.0
    private var loudest = 0.0

    var value: Double {
        lock.lock(); defer { lock.unlock() }
        return level
    }

    /// The loudest moment since listening started (to tell "no sound" from "not understood").
    var peak: Double {
        lock.lock(); defer { lock.unlock() }
        return loudest
    }

    func startSession() {
        lock.lock(); level = 0; loudest = 0; lock.unlock()
    }

    /// Called with the RMS of each audio buffer.
    func push(_ rms: Float) {
        // Speech RMS is roughly 0.005…0.2; map it onto 0…1 on a log scale, then smooth it.
        let db = 20 * log10(max(Double(rms), 0.000_01))
        let target = min(max((db + 55) / 40, 0), 1)
        lock.lock()
        level = target > level ? level * 0.4 + target * 0.6 : level * 0.85 + target * 0.15
        loudest = max(loudest, level)
        lock.unlock()
    }

    func reset() {
        lock.lock(); level = 0; lock.unlock()
    }
}

// MARK: - What the AI look is doing right now

enum VoiceLook: Equatable {
    case none, listening, thinking, speaking
}

/// Colors of the AI glow (purple → blue → cyan → pink).
enum AIPalette {
    static let colors: [Color] = [
        Color(red: 0.55, green: 0.36, blue: 1.0), Color(red: 0.25, green: 0.55, blue: 1.0),
        Color(red: 0.2, green: 0.85, blue: 0.95), Color(red: 1.0, green: 0.42, blue: 0.75),
        Color(red: 0.55, green: 0.36, blue: 1.0),
    ]
    static let glow = Color(red: 0.35, green: 0.85, blue: 1.0)
}

// MARK: - Live voice wave (in the bubble while listening)

struct VoiceWave: View {
    let t: Double
    let level: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                // Each bar wobbles on its own, scaled by how loud you are; a little idle motion always.
                let wobble = 0.5 + 0.5 * sin(t * 11 + Double(i) * 1.3)
                let center = 1 - abs(Double(i) - 2) * 0.22
                let h = 3 + 12 * center * (0.15 + 0.85 * level) * (0.45 + 0.55 * wobble)
                Capsule()
                    .fill(LinearGradient(colors: [AIPalette.colors[i % 4], AIPalette.colors[(i + 1) % 4]],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 2.6, height: h)
            }
        }
        .frame(height: 15)
    }
}

// MARK: - Aura and thinking particles

extension CharacterView {
    /// A soft, colorful ring of light behind the buddy: pulses while listening (with your voice),
    /// swirls while thinking, and breathes while speaking.
    @ViewBuilder
    func aura(_ look: VoiceLook, level: Double) -> some View {
        if look != .none {
            let spin: Double = look == .thinking ? t * 140 : t * 25
            let pulse = auraPulse(look, level: level)
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: AIPalette.colors, center: .center, angle: .degrees(spin)))
                    .frame(width: 128, height: 128)
                    .blur(radius: 22)
                    .opacity(look == .thinking ? 0.75 : 0.55)
                Circle()
                    .stroke(AngularGradient(colors: AIPalette.colors, center: .center, angle: .degrees(-spin * 1.3)),
                            lineWidth: 2.5)
                    .frame(width: 122, height: 122)
                    .blur(radius: 1.5)
                    .opacity(0.8)
            }
            .scaleEffect(pulse)
            .offset(y: 2)
            .transition(.opacity)
        }
    }

    func auraPulse(_ look: VoiceLook, level: Double) -> Double {
        switch look {
        case .listening: return 1 + 0.06 * sin(t * 3) + 0.14 * level
        case .thinking: return 1 + 0.04 * sin(t * 6)
        case .speaking: return 1 + 0.05 * sin(t * 4)
        case .none: return 1
        }
    }

    /// Tiny glowing dots orbiting the buddy's head while it thinks.
    @ViewBuilder
    func thinkingParticles(_ look: VoiceLook) -> some View {
        if look == .thinking {
            ForEach(0..<7, id: \.self) { i in
                let speed = 1.6 + Double(i % 3) * 0.5
                let angle = t * speed + Double(i) * 2 * .pi / 7
                let rx = 58.0 + Double(i % 2) * 8
                let ry = 20.0 + Double(i % 3) * 4
                // Dots behind the head (upper half of the orbit) fade a little, for depth.
                let depth = 0.55 + 0.45 * max(0, sin(angle))
                Circle()
                    .fill(AIPalette.colors[i % 4])
                    .frame(width: 4 + 2 * depth, height: 4 + 2 * depth)
                    .shadow(color: AIPalette.colors[i % 4].opacity(0.9), radius: 4)
                    .opacity(depth)
                    .offset(x: cos(angle) * rx, y: -34 + sin(angle) * ry)
            }
        }
    }
}
