import SwiftUI

// MARK: - Layout

enum BuddyLayout {
    /// Unscaled window size; the real window is this times the size setting.
    static let window = CGSize(width: 240, height: 220)
    static let bubbleHeight: CGFloat = 80
    static let character = CGSize(width: 160, height: 140)
    /// Clickable area in unscaled window coordinates (origin bottom-left). The rest lets clicks through.
    static let hitRect = NSRect(x: 68, y: 18, width: 104, height: 116)
    /// Where the eyes sit in unscaled window coordinates (origin bottom-left).
    static let eyeCenter = CGPoint(x: 120, y: 76)
}

enum Palette {
    static let ink = Color(red: 0.18, green: 0.13, blue: 0.12)
    static let cheek = Color(red: 1.0, green: 0.55, blue: 0.6)
    static let accent = Color(red: 0.87, green: 0.49, blue: 0.36)
}

// MARK: - Speech bubble

struct BubbleInfo: Equatable {
    var text: String
    var icon: String?
    var tint: Color = .primary
    var spinner = false
    /// Show the live voice wave (while listening).
    var wave = false
}

struct BubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let tail: CGFloat = 6
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - tail)
        var p = Path(roundedRect: body, cornerRadius: min(12, body.height / 2), style: .continuous)
        p.move(to: CGPoint(x: rect.midX - 7, y: body.maxY - 0.5))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX + 7, y: body.maxY - 0.5))
        p.closeSubpath()
        return p
    }
}

struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

@MainActor
struct TypingDots: View {
    let t: Double
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .frame(width: 5, height: 5)
                    .opacity(0.3 + 0.7 * max(0, sin(t * 6 - Double(i) * 0.9)))
            }
        }
        .foregroundStyle(color)
    }
}

@MainActor
struct BubbleView: View {
    let info: BubbleInfo
    let t: Double
    var accent: Color = Palette.accent

    var body: some View {
        HStack(spacing: 6) {
            if info.spinner { TypingDots(t: t, color: accent) }
            if info.wave { VoiceWave(t: t, level: AudioLevel.shared.value) }
            if let icon = info.icon {
                Image(systemName: icon).foregroundStyle(info.tint)
            }
            Text(info.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(Color(white: 0.15))
        .padding(.horizontal, 11)
        .padding(.top, 7)
        .padding(.bottom, 13)
        .background(
            // Frosted glass: a blur of what's behind, a bright tint so text stays readable, and a light rim.
            ZStack {
                BubbleShape().fill(.ultraThinMaterial)
                BubbleShape().fill(LinearGradient(colors: [Color.white.opacity(0.88), Color.white.opacity(0.66)],
                                                  startPoint: .top, endPoint: .bottom))
                BubbleShape().stroke(LinearGradient(colors: [Color.white, Color.white.opacity(0.25)],
                                                    startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .environment(\.colorScheme, .light)
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
        )
        .frame(maxWidth: BuddyLayout.window.width - 12)
    }
}

// MARK: - Character

enum EyeStyle { case open(Double), happy, closed, dizzy }
enum MouthStyle { case smile, grin, oh, focus, snore, frown }

struct Pose {
    var lift = 0.0
    var squash = 1.0
    var tilt = 0.0
    var spin = 0.0
    /// Rotation around the middle of the body (backflips), unlike `tilt` which pivots on the feet.
    var flip = 0.0
    var shakeX = 0.0
    var leftArm = 15.0
    var rightArm = -15.0
    var leftFoot = 0.0
    var rightFoot = 0.0
    var look = CGSize.zero
    var eyeScale = 1.0
    var eyes = EyeStyle.open(1)
    var mouth = MouthStyle.smile
    /// Extra rosy cheeks (0…1), e.g. for romantic songs.
    var blush = 0.0
    var antenna: Color?
    var antennaGlow = 0.0
}

@MainActor
struct CharacterView: View {
    let mood: Mood
    let t: Double
    let reaction: Reaction?
    let style: BuddyStyle
    /// Antenna color while working (Claude orange / Cursor blue); nil keeps the default.
    var agentTint: Color? = nil
    /// Which agent's mark goes on the laptop screen (a code symbol for Cursor).
    var screenAgent: Agent? = nil
    /// How it reacts to what you're listening to (only while otherwise idle).
    var vibe: Vibe? = nil
    /// Do just this one work activity (e.g. reading the news) instead of the usual routine.
    var fixedActivity: WorkActivity? = nil
    /// Voice-assistant look: aura, particles and lip-sync.
    var voiceLook: VoiceLook = .none
    /// Microphone loudness 0…1 while listening.
    var voiceLevel: Double = 0
    /// How wide the mouth is open while speaking, 0…1.
    var talk: Double = 0

    private var limb: Color { style.limb.color }

    /// What the buddy is busy with while Claude works; nil otherwise (a tap reaction takes over).
    private var work: WorkState? {
        guard mood == .working, reaction == nil else { return nil }
        if let fixedActivity {
            return WorkState(activity: fixedActivity, local: t.truncatingRemainder(dividingBy: WorkSchedule.slot), presence: 1)
        }
        return WorkSchedule.state(at: t)
    }

    var body: some View {
        let pose = makePose()
        ZStack {
            Ellipse()
                .fill(Color.black.opacity(0.16))
                .frame(width: 74 * (1 - min(pose.lift, 40) / 80), height: 10)
                .offset(y: 52)

            effectsBehind

            figure(pose)
                .scaleEffect(x: 2 - pose.squash, y: pose.squash, anchor: .bottom)
                .rotation3DEffect(.degrees(pose.spin), axis: (x: 0, y: 1, z: 0))
                .rotationEffect(.degrees(pose.tilt), anchor: .bottom)
                .rotationEffect(.degrees(pose.flip))
                .offset(x: pose.shakeX, y: -pose.lift)

            effectsInFront
        }
        .frame(width: BuddyLayout.character.width, height: BuddyLayout.character.height)
    }

    // MARK: Pose

    private func makePose() -> Pose {
        var p = Pose()
        let breathe = sin(t * 2)
        p.squash = 1 + 0.025 * breathe
        p.leftArm = 15 + 4 * breathe
        p.rightArm = -p.leftArm

        // Glance somewhere new every few seconds.
        let slot = floor(t / 3.1)
        p.look = CGSize(width: cos(slot * 1.7) * 3, height: sin(slot * 2.3) * 1.5)
        let blinking = t.truncatingRemainder(dividingBy: 3.7) < 0.13
        p.eyes = .open(blinking ? 0.1 : 1)

        switch mood {
        case .idle:
            break
        case .working:
            p.antenna = agentTint ?? Color(red: 0.3, green: 0.8, blue: 1.0)
            p.antennaGlow = 0.5 + 0.5 * sin(t * 8)
            if let work { p = blended(from: p, to: workPose(p, work), by: work.presence) }
        case .done:
            p.lift = abs(sin(t * 6)) * 14
            p.squash = 1 + 0.05 * sin(t * 12)
            p.leftArm = 150 + sin(t * 12) * 12
            p.rightArm = -150 - sin(t * 12) * 12
            p.eyes = .happy
            p.mouth = .grin
            p.antenna = Color(red: 1.0, green: 0.82, blue: 0.2)
            p.antennaGlow = 1
        case .attention:
            p.shakeX = t.truncatingRemainder(dividingBy: 1.6) < 0.45 ? sin(t * 45) * 2.5 : 0
            p.rightArm = -145 + sin(t * 10) * 25
            p.look = CGSize(width: 0, height: -1)
            p.eyeScale = 1.12
            p.mouth = .oh
            p.antenna = Color(red: 1.0, green: 0.3, blue: 0.3)
            p.antennaGlow = sin(t * 9) > 0 ? 1 : 0.2
        case .sleeping:
            p.squash = 1 + 0.04 * sin(t * 1.2)
            p.tilt = 6
            p.leftArm = 8
            p.rightArm = -8
            p.eyes = .closed
            p.mouth = .snore
        }

        if mood == .idle, let vibe { applyVibe(vibe, to: &p) }

        if voiceLook == .listening {
            // Attentive: eyes on you, a little bigger when you speak louder, gentle tilt.
            p.look = .zero
            p.eyeScale = 1.06 + 0.12 * voiceLevel
            p.tilt = sin(t * 1.4) * 3
            p.mouth = .smile
            p.antenna = AIPalette.glow
            p.antennaGlow = 0.5 + 0.5 * voiceLevel
        } else if voiceLook == .speaking {
            p.antenna = AIPalette.glow
            p.antennaGlow = 0.4 + 0.6 * talk
        }

        if let look = style.look, vibe != .quran { p.look = look }

        if let reaction {
            let r = reaction.elapsed
            let k = min(r / reaction.kind.duration, 1)
            switch reaction.kind {
            case .spin:
                let jump = min(r / 0.6, 1)
                p.lift += sin(jump * .pi) * 24
                p.spin = (1 - pow(1 - jump, 3)) * 360
                p.leftArm = 140
                p.rightArm = -140
                p.eyes = .happy
                p.mouth = .grin
            case .backflip:
                let crouch = min(r / 0.18, 1)
                let air = max(0, min((r - 0.18) / 0.7, 1))
                p.squash = air == 0 ? 1 - 0.12 * crouch : 1 + 0.06 * sin(air * .pi)
                p.lift += sin(air * .pi) * 38
                p.flip = -(1 - pow(1 - air, 2.4)) * 360
                p.leftArm = 160 * sin(air * .pi)
                p.rightArm = -160 * sin(air * .pi)
                p.leftFoot = 4 * sin(air * .pi)
                p.rightFoot = p.leftFoot
                p.eyes = air > 0 && air < 1 ? .closed : .happy
                p.mouth = .grin
            case .boing:
                // Squashed flat, then a wobbling spring back.
                let spring = exp(-r * 3.6) * cos(r * 17)
                p.squash = 1 - 0.28 * spring
                p.lift += max(0, -spring) * 10
                p.leftArm = 15 + 40 * max(0, spring)
                p.rightArm = -p.leftArm
                p.eyes = spring > 0.4 ? .closed : .open(1)
                p.eyeScale = 1 + 0.15 * max(0, -spring)
                p.mouth = spring > 0.4 ? .oh : .grin
            case .wave:
                p.rightArm = -150 + sin(r * 14) * 26
                p.tilt = sin(r * 7) * 4
                p.lift += abs(sin(r * 7)) * 3
                p.look = CGSize(width: 2, height: 0)
                p.eyes = .happy
                p.mouth = .grin
            case .giggle:
                p.shakeX = sin(r * 42) * 2.4 * (1 - k)
                p.squash = 1 + 0.04 * sin(r * 30)
                p.leftArm = -35 + sin(r * 30) * 6
                p.rightArm = 35 - sin(r * 30) * 6
                p.eyes = .happy
                p.mouth = .grin
            case .dizzy:
                p.tilt = sin(r * 14) * 12 * (1 - r / 2)
                p.eyes = .dizzy
                p.mouth = .oh
            }
        }
        return p
    }

    // MARK: Figure

    private func figure(_ p: Pose) -> some View {
        let radius = min(style.roundness, 41)
        return ZStack {
            if style.antenna {
                antenna(p)
            }

            foot.offset(x: -20, y: 41 - p.leftFoot)
            foot.offset(x: 20, y: 41 - p.rightFoot)

            Group {
                if style.holo {
                    holoBody(radius: radius)
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(colors: [style.bodyLight, style.body.color],
                                             startPoint: .top, endPoint: .bottom))
                }
            }
            .frame(width: 92, height: 82)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(style.holo ? Color.white.opacity(0.45) : limb.opacity(0.35), lineWidth: 1.5)
            )

            face(p)

            accessory

            arm(angle: p.leftArm).offset(x: -44, y: 4)
            arm(angle: p.rightArm).offset(x: 44, y: 4)

            if let work { workProps(work, pose: p) }
        }
    }

    /// The optional "AI look": a slowly turning purple-blue gradient with a glossy top and a
    /// shine that sweeps across every few seconds.
    private func holoBody(radius: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let sweep = (t * 0.45).truncatingRemainder(dividingBy: 1.6)   // 0…1 sweeping, then a pause
        return shape
            .fill(AngularGradient(colors: [Color(red: 0.5, green: 0.38, blue: 1.0), Color(red: 0.3, green: 0.55, blue: 1.0),
                                           Color(red: 0.4, green: 0.8, blue: 1.0), Color(red: 0.75, green: 0.45, blue: 1.0),
                                           Color(red: 0.5, green: 0.38, blue: 1.0)],
                                  center: .center, angle: .degrees(t * 30)))
            .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.5), Color.white.opacity(0)],
                                               startPoint: .top, endPoint: .center)))
            .overlay(
                LinearGradient(colors: [.clear, Color.white.opacity(0.4), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 26, height: 140)
                    .rotationEffect(.degrees(18))
                    .offset(x: -80 + sweep * 160)
            )
            .clipShape(shape)
    }

    private func antenna(_ p: Pose) -> some View {
        let bulb = p.antenna ?? limb
        return ZStack(alignment: .top) {
            Capsule().fill(limb).frame(width: 3, height: 16).offset(y: 6)
            if style.holo {
                // A glowing orb.
                Circle()
                    .fill(RadialGradient(colors: [Color.white, p.antenna ?? AIPalette.glow], center: .center,
                                         startRadius: 0, endRadius: 6))
                    .frame(width: 11, height: 11)
                    .shadow(color: (p.antenna ?? AIPalette.glow).opacity(0.5 + 0.5 * max(p.antennaGlow, 0.4)), radius: 7)
                    .offset(y: -1)
            } else {
                Circle()
                    .fill(bulb)
                    .frame(width: 9, height: 9)
                    .shadow(color: bulb.opacity(p.antennaGlow), radius: 6)
            }
        }
        .frame(width: 10, height: 24, alignment: .top)
        .rotationEffect(.degrees(sin(t * 3) * 10), anchor: .bottom)
        .offset(y: -50)
    }

    private func face(_ p: Pose) -> some View {
        ZStack {
            if style.digitalEyes {
                // A dark screen the glowing eyes sit on.
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 66, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1))
                    .offset(y: -6)
                digitalEye(p).offset(x: -15, y: -6)
                digitalEye(p).offset(x: 15, y: -6)
            } else {
                eye(p).offset(x: -17, y: -6)
                eye(p).offset(x: 17, y: -6)
            }
            if style.cheeks {
                Ellipse().fill(Palette.cheek.opacity(0.45 + 0.45 * p.blush))
                    .frame(width: 12 + 5 * p.blush, height: 7 + 3 * p.blush).offset(x: -30, y: 9)
                Ellipse().fill(Palette.cheek.opacity(0.45 + 0.45 * p.blush))
                    .frame(width: 12 + 5 * p.blush, height: 7 + 3 * p.blush).offset(x: 30, y: 9)
            }
            if talk > 0 {
                // Talking: an open mouth that grows and shrinks with each word.
                ZStack(alignment: .bottom) {
                    Ellipse().fill(Palette.ink)
                    Ellipse().fill(Palette.cheek).frame(width: 7, height: 3 + 2 * talk).offset(y: -1)
                }
                .frame(width: 10 + 4 * talk, height: 3 + 9 * talk)
                .offset(y: 15)
            } else {
                mouth(p.mouth).offset(y: 15)
            }
            if style.accessory == .glasses {
                Circle().stroke(Palette.ink, lineWidth: 2.5).frame(width: 25, height: 25).offset(x: -17, y: -6)
                Circle().stroke(Palette.ink, lineWidth: 2.5).frame(width: 25, height: 25).offset(x: 17, y: -6)
                Capsule().fill(Palette.ink).frame(width: 9, height: 2.5).offset(y: -9)
            }
        }
    }

    private var foot: some View {
        Capsule().fill(limb).frame(width: 24, height: 12)
    }

    private func arm(angle: Double) -> some View {
        Capsule()
            .fill(limb)
            .frame(width: 13, height: 28)
            .offset(y: 11)
            .rotationEffect(.degrees(angle))
    }

    /// LED-style glowing eyes (optional "Digital eyes" look).
    @ViewBuilder
    private func digitalEye(_ p: Pose) -> some View {
        let glow = AIPalette.glow
        switch p.eyes {
        case .open(let openness):
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(glow)
                .frame(width: 11, height: max(2, 16 * openness * p.eyeScale))
                .overlay(   // scanlines
                    VStack(spacing: 2) {
                        ForEach(0..<5, id: \.self) { _ in Rectangle().fill(Color.black.opacity(0.18)).frame(height: 1) }
                    }
                    .frame(width: 11, height: 14)
                    .clipped()
                )
                .shadow(color: glow, radius: 4)
                .offset(x: p.look.width * 0.7, y: p.look.height * 0.5)
        case .happy:
            Path { path in
                path.move(to: CGPoint(x: 0, y: 7))
                path.addQuadCurve(to: CGPoint(x: 14, y: 7), control: CGPoint(x: 7, y: -3))
            }
            .stroke(glow, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .frame(width: 14, height: 9)
            .shadow(color: glow, radius: 4)
        case .closed:
            Capsule().fill(glow).frame(width: 13, height: 2.5).shadow(color: glow, radius: 3)
        case .dizzy:
            Text("@")
                .font(.system(size: 16, weight: .heavy, design: .monospaced))
                .foregroundStyle(glow)
                .shadow(color: glow, radius: 3)
                .rotationEffect(.degrees(t * 400))
        }
    }

    @ViewBuilder
    private func eye(_ p: Pose) -> some View {
        switch p.eyes {
        case .open(let openness):
            let pupil = 10 * style.pupilScale
            ZStack {
                Ellipse().fill(Color.white).frame(width: 18, height: 22)
                Circle().fill(Palette.ink).frame(width: pupil, height: pupil)
                    .offset(x: p.look.width, y: p.look.height + 2)
                Circle().fill(Color.white).frame(width: pupil * 0.35, height: pupil * 0.35)
                    .offset(x: p.look.width + pupil * 0.2, y: p.look.height + 2 - pupil * 0.3)
            }
            .scaleEffect(x: p.eyeScale, y: p.eyeScale * openness)
        case .happy:
            Path { path in
                path.move(to: CGPoint(x: 0, y: 8))
                path.addQuadCurve(to: CGPoint(x: 16, y: 8), control: CGPoint(x: 8, y: -4))
            }
            .stroke(Palette.ink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .frame(width: 16, height: 10)
        case .closed:
            Path { path in
                path.move(to: CGPoint(x: 0, y: 2))
                path.addQuadCurve(to: CGPoint(x: 16, y: 2), control: CGPoint(x: 8, y: 9))
            }
            .stroke(Palette.ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: 16, height: 8)
        case .dizzy:
            Text("@")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(Palette.ink)
                .rotationEffect(.degrees(t * 400))
        }
    }

    @ViewBuilder
    private func mouth(_ style: MouthStyle) -> some View {
        switch style {
        case .smile:
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addQuadCurve(to: CGPoint(x: 12, y: 0), control: CGPoint(x: 6, y: 7))
            }
            .stroke(Palette.ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: 12, height: 5)
        case .grin:
            ZStack(alignment: .bottom) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addQuadCurve(to: CGPoint(x: 18, y: 0), control: CGPoint(x: 9, y: 20))
                    path.closeSubpath()
                }
                .fill(Palette.ink)
                Ellipse().fill(Palette.cheek).frame(width: 8, height: 4).offset(y: -1.5)
            }
            .frame(width: 18, height: 10)
            .offset(y: 2)
        case .oh:
            Ellipse().fill(Palette.ink).frame(width: 8, height: 10)
        case .focus:
            ZStack {
                Capsule().fill(Palette.ink).frame(width: 10, height: 2.5)
                Circle().fill(Palette.cheek).frame(width: 5, height: 5).offset(x: 4, y: 2.5)
            }
        case .snore:
            Ellipse().fill(Palette.ink).frame(width: 5 + 2 * sin(t * 1.2), height: 5 + 2 * sin(t * 1.2))
        case .frown:
            Path { path in
                path.move(to: CGPoint(x: 0, y: 5))
                path.addQuadCurve(to: CGPoint(x: 12, y: 5), control: CGPoint(x: 6, y: -1))
            }
            .stroke(Palette.ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: 12, height: 5)
        }
    }

    @ViewBuilder
    private var accessory: some View {
        let hatInk = Color(white: 0.16)
        switch style.accessory {
        case .none, .glasses:
            EmptyView()
        case .partyHat:
            ZStack(alignment: .top) {
                TriangleShape()
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.45, blue: 0.7), Color(red: 0.55, green: 0.4, blue: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 30, height: 34)
                Circle().fill(Color.white.opacity(0.85)).frame(width: 4, height: 4).offset(x: -3, y: 16)
                Circle().fill(Color.white.opacity(0.85)).frame(width: 4, height: 4).offset(x: 5, y: 25)
                Circle().fill(Color(red: 1, green: 0.85, blue: 0.25)).frame(width: 10, height: 10).offset(y: -5)
            }
            .frame(width: 30, height: 34)
            .rotationEffect(.degrees(-14))
            .offset(x: 14, y: -54)
        case .topHat:
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(hatInk).frame(width: 34, height: 30).offset(y: -57)
                Rectangle().fill(Color(red: 0.85, green: 0.2, blue: 0.25)).frame(width: 34, height: 6).offset(y: -47)
                Capsule().fill(hatInk).frame(width: 56, height: 8).offset(y: -41)
            }
            .rotationEffect(.degrees(-6))
        case .crown:
            Image(systemName: "crown.fill")
                .font(.system(size: 30))
                .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.87, blue: 0.3), Color(red: 0.95, green: 0.6, blue: 0.1)],
                                                startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                .offset(y: -52)
        case .bow:
            let pink = Color(red: 1, green: 0.4, blue: 0.6)
            ZStack {
                Ellipse().fill(pink).frame(width: 17, height: 12).rotationEffect(.degrees(20)).offset(x: -8)
                Ellipse().fill(pink).frame(width: 17, height: 12).rotationEffect(.degrees(-20)).offset(x: 8)
                Circle().fill(Color(red: 0.85, green: 0.25, blue: 0.45)).frame(width: 8, height: 8)
            }
            .rotationEffect(.degrees(15))
            .offset(x: 26, y: -38)
        case .flower:
            ZStack {
                ForEach(0..<5, id: \.self) { i in
                    let a = Double(i) / 5 * 2 * .pi
                    Circle().fill(Color.white).frame(width: 10, height: 10)
                        .offset(x: cos(a) * 6, y: sin(a) * 6)
                }
                Circle().fill(Color(red: 1, green: 0.8, blue: 0.2)).frame(width: 8, height: 8)
            }
            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
            .rotationEffect(.degrees(t * 10))
            .offset(x: -26, y: -37)
        case .headphones:
            ZStack {
                Circle().trim(from: 0.5, to: 1)
                    .stroke(hatInk, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 104, height: 104)
                    .offset(y: 6)
                RoundedRectangle(cornerRadius: 6).fill(hatInk).frame(width: 14, height: 26).offset(x: -50, y: 4)
                RoundedRectangle(cornerRadius: 6).fill(hatInk).frame(width: 14, height: 26).offset(x: 50, y: 4)
                Circle().fill(Palette.accent).frame(width: 5, height: 5).offset(x: -50, y: 4)
                Circle().fill(Palette.accent).frame(width: 5, height: 5).offset(x: 50, y: 4)
            }
        }
    }

    var laptop: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.88), Color(white: 0.74)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 56, height: 34)
                .overlay {
                    if screenAgent == .cursor {
                        // A code symbol that pulses like a heartbeat (not Cursor's logo).
                        let pulse = max(0, sin(t * 4))
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(style.body.color)
                            .scaleEffect(1 + 0.12 * pulse)
                    } else {
                        Image(systemName: "asterisk")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(style.body.color)
                            .rotationEffect(.degrees(t * 90))
                    }
                }
            Capsule().fill(Color(white: 0.62)).frame(width: 68, height: 5)
        }
    }

    // MARK: Effects

    @ViewBuilder
    private var effectsBehind: some View {
        aura(voiceLook, level: voiceLevel)
        if mood == .idle, vibe == .quran {
            // A soft, slow glow while listening.
            Circle()
                .fill(RadialGradient(colors: [Color(red: 1, green: 0.9, blue: 0.6).opacity(0.35), .clear],
                                     center: .center, startRadius: 10, endRadius: 75))
                .frame(width: 150, height: 150)
                .scaleEffect(1 + 0.05 * sin(t * 0.9))
                .offset(y: 4)
        }
        if mood == .done {
            ForEach(0..<5, id: \.self) { i in
                let angle = Double(i) / 5 * 2 * .pi + t * 0.8
                Image(systemName: "sparkle")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(red: 1, green: 0.78, blue: 0.2))
                    .scaleEffect(0.5 + 0.6 * abs(sin(t * 4 + Double(i))))
                    .offset(x: cos(angle) * 66, y: sin(angle) * 44 - 8)
            }
        }
    }

    @ViewBuilder
    private var effectsInFront: some View {
        thinkingParticles(voiceLook)
        if let work { workEffects(work) }
        if let work, work.activity == .typing {
            let glyphs = ["{ }", "</>", "01", "fn", "=>"]
            ForEach(0..<3, id: \.self) { i in
                let phase = (t * 0.6 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let slot = Int(floor(t * 0.6 + Double(i) / 3))
                Text(glyphs[(slot + i * 2) % glyphs.count])
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.3, green: 0.75, blue: 1.0))
                    .opacity(sin(phase * .pi) * work.presence)
                    .offset(x: (i == 1 ? 48 : -48) + sin(phase * 6) * 4, y: 20 - phase * 70)
            }
        }
        if mood == .idle, let vibe, vibe == .happy || vibe == .groove {
            let colors = [Color(red: 1, green: 0.45, blue: 0.7), Color(red: 0.55, green: 0.5, blue: 1),
                          Color(red: 0.3, green: 0.75, blue: 1.0)]
            let speed = vibe == .happy ? 0.75 : 0.45
            ForEach(0..<3, id: \.self) { i in
                let phase = (t * speed + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                Image(systemName: i == 1 ? "music.note" : "music.quarternote.3")
                    .font(.system(size: 11 + phase * 5, weight: .bold))
                    .foregroundStyle(colors[i])
                    .opacity(sin(phase * .pi))
                    .offset(x: (i == 1 ? 46 : -46) + sin(phase * 7) * 5, y: 10 - phase * 70)
            }
        }
        if mood == .idle, vibe == .romantic {
            // Hearts drift up and fade, gently swaying.
            let pinks = [Color(red: 1, green: 0.35, blue: 0.5), Color(red: 1, green: 0.55, blue: 0.7),
                         Color(red: 0.95, green: 0.25, blue: 0.4), Color(red: 1, green: 0.7, blue: 0.8)]
            ForEach(0..<4, id: \.self) { i in
                let phase = (t * 0.35 + Double(i) / 4).truncatingRemainder(dividingBy: 1)
                let side: Double = i % 2 == 0 ? -1 : 1
                Image(systemName: "heart.fill")
                    .font(.system(size: 9 + phase * 9 + Double(i % 2) * 3))
                    .foregroundStyle(pinks[i])
                    .opacity(sin(phase * .pi))
                    .scaleEffect(1 + 0.15 * sin(t * 6 + Double(i)))
                    .offset(x: side * (40 + Double(i) * 4) + sin(phase * 6 + Double(i)) * 8, y: 14 - phase * 80)
            }
        }
        if mood == .idle, case .sport(let sport)? = vibe {
            // The sport's ball bounces beside the buddy; a little burst of sparkles when it cheers.
            let bounce = abs(sin(t * 3.2))
            Image(systemName: sport.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(sport == .cricket ? Color(red: 0.85, green: 0.15, blue: 0.2) : Palette.ink.opacity(0.85))
                .rotationEffect(.degrees(t * 120))
                .offset(x: 56, y: 38 - bounce * 26)
            if CharacterView.cheering(at: t) {
                ForEach(0..<4, id: \.self) { i in
                    let angle = Double(i) / 4 * 2 * .pi + t * 2
                    Image(systemName: "sparkle")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(red: 1, green: 0.78, blue: 0.2))
                        .offset(x: cos(angle) * 54, y: sin(angle) * 30 - 30)
                }
            }
        }
        if mood == .idle, case .browse(let kind, _)? = vibe, kind != .news, kind != .learning, kind != .search {
            if kind == .social || kind == .chat {
                // Likes and messages pop up now and then.
                let phase = (t * 0.5).truncatingRemainder(dividingBy: 1)
                Image(systemName: kind == .chat ? "ellipsis.bubble.fill" : (Int(t * 0.5) % 2 == 0 ? "hand.thumbsup.fill" : "heart.fill"))
                    .font(.system(size: 13 + phase * 5, weight: .bold))
                    .foregroundStyle(kind == .chat ? Color(red: 0.2, green: 0.75, blue: 0.4)
                                     : (Int(t * 0.5) % 2 == 0 ? Color(red: 0.2, green: 0.5, blue: 0.95) : Color(red: 1, green: 0.35, blue: 0.5)))
                    .opacity(sin(phase * .pi))
                    .offset(x: 50, y: -10 - phase * 40)
            } else {
                Image(systemName: kind.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(kind == .money ? Color(red: 0.2, green: 0.65, blue: 0.3)
                                     : kind == .food ? Color(red: 0.9, green: 0.5, blue: 0.2)
                                     : Color(red: 0.3, green: 0.55, blue: 0.95))
                    .rotationEffect(.degrees(kind == .travel ? 45 + sin(t * 2) * 10 : sin(t * 2) * 8))
                    .offset(x: kind == .travel ? 50 + sin(t * 1.2) * 10 : 54, y: -6 + sin(t * 3) * 6)
            }
        }
        if mood == .idle, vibe == .sad {
            // A tear rolls down now and then.
            let phase = (t * 0.33).truncatingRemainder(dividingBy: 1)
            Image(systemName: "drop.fill")
                .font(.system(size: 7))
                .foregroundStyle(Color(red: 0.45, green: 0.7, blue: 1.0))
                .opacity(phase < 0.6 ? sin(phase / 0.6 * .pi) : 0)
                .offset(x: -19, y: 2 + phase * 40)
        }
        if mood == .sleeping {
            ForEach(0..<3, id: \.self) { i in
                let phase = (t * 0.35 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                Text("z")
                    .font(.system(size: 10 + phase * 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(red: 0.5, green: 0.6, blue: 0.95))
                    .opacity(sin(phase * .pi))
                    .offset(x: 30 + phase * 30, y: -40 - phase * 30)
            }
        }
        if let reaction { reactionEffects(reaction) }
        if let reaction, reaction.kind == .spin {
            ForEach(0..<3, id: \.self) { i in
                let r = reaction.elapsed / 1.2
                Image(systemName: "heart.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 1, green: 0.4, blue: 0.55))
                    .opacity(1 - r)
                    .scaleEffect(0.6 + r)
                    .offset(x: Double(i - 1) * 28, y: -50 - r * 50 - Double(i % 2) * 10)
            }
        }
    }
}

// MARK: - Buddy (bubble + character)

/// The bubble-over-character stack at unscaled size. Shared by the desktop window and the settings preview.
@MainActor
struct BuddyStack: View {
    let bubble: BubbleInfo?
    let mood: Mood
    let t: Double
    let reaction: Reaction?
    let style: BuddyStyle
    var agentTint: Color? = nil
    var screenAgent: Agent? = nil
    var vibe: Vibe? = nil
    var fixedActivity: WorkActivity? = nil
    var voiceLook: VoiceLook = .none
    var voiceLevel: Double = 0
    var talk: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                if let bubble {
                    BubbleView(info: bubble, t: t, accent: style.body.color)
                        .transition(.scale(scale: 0.4, anchor: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: BuddyLayout.window.width, height: BuddyLayout.bubbleHeight, alignment: .bottom)
            .animation(.spring(duration: 0.3, bounce: 0.4), value: bubble)

            CharacterView(mood: mood, t: t, reaction: reaction, style: style, agentTint: agentTint,
                          screenAgent: screenAgent, vibe: vibe, fixedActivity: fixedActivity,
                          voiceLook: voiceLook, voiceLevel: voiceLevel, talk: talk)
        }
        .frame(width: BuddyLayout.window.width, height: BuddyLayout.window.height, alignment: .bottom)
    }

    static func bubble(for mood: Mood, projects: [String], settings: BuddySettings,
                       agents: [Agent] = [], doneAgent: Agent? = nil) -> BubbleInfo? {
        guard settings.showBubble else { return nil }
        switch mood {
        case .attention:
            return BubbleInfo(text: "Claude needs your OK!", icon: "exclamationmark.circle.fill", tint: .red)
        case .working:
            let who = agents.map(\.name).joined(separator: " + ")
            let lead = agents.first
            guard settings.showProject, let first = projects.first else {
                return BubbleInfo(text: who.isEmpty ? "Working…" : "\(who) working…",
                                  icon: lead?.icon, tint: lead?.tint ?? .primary, spinner: true)
            }
            var text = first
            if projects.count > 1 { text += " + \(projects[1])" }
            if projects.count > 2 { text += " +\(projects.count - 2)" }
            if !who.isEmpty { text = "\(who) · \(text)" }
            return BubbleInfo(text: text, icon: lead?.icon ?? "folder.fill", tint: lead?.tint ?? Palette.accent, spinner: true)
        case .done:
            return BubbleInfo(text: doneAgent.map { "\($0.name) is done!" } ?? "All done!",
                              icon: "checkmark.circle.fill", tint: .green)
        case .idle, .sleeping:
            return nil
        }
    }
}

/// Root view of the desktop window.
@MainActor
struct BuddyView: View {
    @ObservedObject var model: BuddyModel
    @ObservedObject var settings: BuddySettings

    static func voiceLook(_ voice: VoiceState, speaking: Bool) -> VoiceLook {
        switch voice {
        case .off: return .none
        case .listening(_): return .listening
        case .thinking: return .thinking
        case .answering(_): return speaking ? .speaking : .none
        }
    }

    static func voiceBubble(_ voice: VoiceState, speaker: Speaker) -> BubbleInfo? {
        switch voice {
        case .off:
            return nil
        case .listening(let heard):
            let text = heard.isEmpty ? "Listening…" : "…" + String(heard.suffix(26))
            return BubbleInfo(text: text, wave: true)
        case .thinking:
            return BubbleInfo(text: "Thinking…", icon: "sparkles", tint: Agent.gemini)
        case .answering(let answer):
            // Types along with the voice, word by word.
            let typed = speaker.typedSoFar(limit: 36)
            let text = typed.isEmpty ? (answer.count > 38 ? String(answer.prefix(36)) + "…" : answer) : typed
            return BubbleInfo(text: text, icon: "sparkles", tint: Agent.gemini)
        }
    }

    /// nil: not a working reaction. .some(nil): the usual work routine. .some(x): just activity x.
    static func activity(for vibe: Vibe?) -> WorkActivity?? {
        switch vibe {
        case .work(_)?: return .some(nil)
        case .browse(.news, _)?, .browse(.learning, _)?: return .some(.reading)
        case .browse(.search, _)?: return .some(.thinking)
        default: return nil
        }
    }

    static func vibeBubble(_ vibe: Vibe?, title: String?) -> BubbleInfo? {
        guard let vibe else { return nil }
        let song = title.map { $0.count > 30 ? String($0.prefix(28)) + "…" : $0 } ?? ""
        switch vibe {
        case .quran:
            return BubbleInfo(text: "Listening carefully…", icon: "book.closed.fill",
                              tint: Color(red: 0.2, green: 0.6, blue: 0.4))
        case .sad:
            return BubbleInfo(text: song, icon: "cloud.rain.fill", tint: Color(red: 0.4, green: 0.6, blue: 0.95))
        case .romantic:
            return BubbleInfo(text: song, icon: "heart.fill", tint: Color(red: 1, green: 0.35, blue: 0.5))
        case .happy:
            return BubbleInfo(text: song, icon: "music.note", tint: Color(red: 1, green: 0.45, blue: 0.7))
        case .groove:
            return BubbleInfo(text: song, icon: "headphones", tint: Palette.accent)
        case .sport(let sport):
            return BubbleInfo(text: sport == .other ? song : "Watching \(sport.name)!", icon: sport.icon,
                              tint: Color(red: 0.2, green: 0.65, blue: 0.3))
        case .work(let place):
            return BubbleInfo(text: "Working · \(place)", icon: "laptopcomputer", tint: Palette.accent, spinner: true)
        case .browse(let kind, let name):
            let short = name.count > 24 ? String(name.prefix(22)) + "…" : name
            let text: String = switch kind {
            case .social: "Scrolling \(short)"
            case .chat: "Chatting on \(short)"
            case .shopping: "Shopping on \(short)!"
            case .news: "Reading the news"
            case .learning: "Learning · \(short)"
            case .search: short.isEmpty ? "Searching…" : "Searching: \(short)"
            case .food: "Yum! Ordering food?"
            case .movie: "Movie time!"
            case .travel: "Planning a trip?"
            case .money: "Money stuff · \(short)"
            case .games: "Game time!"
            case .other: "Browsing \(short)"
            }
            return BubbleInfo(text: text, icon: kind.icon, tint: Color(red: 0.3, green: 0.55, blue: 0.95))
        }
    }

    /// Turns the whole buddy blue (with headphones) for Cursor; Claude keeps your chosen look.
    static func themed(_ style: BuddyStyle, for agent: Agent?) -> BuddyStyle {
        guard agent == .cursor else { return style }
        var s = style
        s.body = Agent.cursorBody
        s.limb = Agent.cursorLimb
        s.holo = false   // Cursor's blue wins over the AI look
        if s.accessory == .none { s.accessory = .headphones }
        return s
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40)) { timeline in
            let now = timeline.date
            let t = now.timeIntervalSinceReferenceDate * settings.animationSpeed
            let bubble = Self.voiceBubble(model.voice, speaker: Speaker.shared)
                ?? model.activePhrase(at: now).map { BubbleInfo(text: $0) }
                ?? BuddyStack.bubble(for: model.mood, projects: model.projects, settings: settings,
                                     agents: model.agents, doneAgent: model.doneAgent)
                ?? (model.mood == .idle && settings.showBubble ? Self.vibeBubble(model.vibe, title: model.nowPlaying) : nil)
            // With both agents busy, the antenna takes turns between their colors.
            let agents = model.agents
            let tint: Color? = agents.isEmpty ? nil
                : agents[Int(now.timeIntervalSinceReferenceDate / 1.5) % agents.count].tint
            // A work tab or app in front: the buddy works along with you; news and
            // learning sites make it read, a search makes it think.
            let chatting = model.voice.isActive
            let activity = model.mood == .idle && !chatting ? Self.activity(for: model.vibe) : nil
            // While you talk to it: calm while listening or answering, thinking hard while Gemini works.
            let mood: Mood = chatting ? (model.voice == .thinking ? .working : .idle)
                : (activity != nil ? .working : model.mood)
            let fixed: WorkActivity? = chatting ? (model.voice == .thinking ? .thinking : nil) : (activity ?? nil)
            let look = Self.voiceLook(model.voice, speaking: Speaker.shared.isSpeaking)
            BuddyStack(bubble: bubble, mood: mood, t: t, reaction: model.reaction(at: now),
                       style: Self.themed(settings.style(look: model.cursorLook), for: chatting ? nil : model.themeAgent),
                       agentTint: chatting ? Optional(Agent.gemini) : tint, screenAgent: chatting ? nil : model.themeAgent,
                       vibe: chatting || activity != nil ? nil : model.vibe,
                       fixedActivity: fixed,
                       voiceLook: look,
                       voiceLevel: look == .listening ? AudioLevel.shared.value : 0,
                       talk: look == .speaking ? Speaker.shared.mouthOpenness(at: now) : 0)
                .opacity(settings.opacity)
                .scaleEffect(settings.scale)
                .frame(width: BuddyLayout.window.width * settings.scale,
                       height: BuddyLayout.window.height * settings.scale)
        }
    }
}

// MARK: - Reacting to music

extension CharacterView {
    /// Cheers for about a second every five seconds while watching sports.
    static func cheering(at t: Double) -> Bool { t.truncatingRemainder(dividingBy: 5) < 1.3 }

    func applyVibe(_ vibe: Vibe, to p: inout Pose) {
        switch vibe {
        case .quran:
            // Perfectly still and respectful: eyes closed, hands together, head slightly bowed.
            p.squash = 1 + 0.012 * sin(t * 0.9)
            p.leftArm = -28
            p.rightArm = 28
            p.tilt = 0
            p.eyes = .closed
            p.mouth = .smile
            p.antenna = Color(red: 0.55, green: 0.85, blue: 0.65)
            p.antennaGlow = 0.35 + 0.15 * sin(t * 0.9)
        case .romantic:
            // Dreamy: slow sway, shy hands together, half-closed happy eyes, rosy cheeks.
            p.tilt = sin(t * 1.2) * 6
            p.squash = 1 + 0.02 * sin(t * 2.4)
            p.lift = max(0, sin(t * 1.2)) * 3
            p.leftArm = -40 + sin(t * 2.4) * 4
            p.rightArm = 40 - sin(t * 2.4) * 4
            p.eyes = sin(t * 0.7) > 0.3 ? .closed : .happy
            p.mouth = .smile
            p.blush = 0.8 + 0.2 * sin(t * 2)
            p.antenna = Color(red: 1, green: 0.4, blue: 0.6)
            p.antennaGlow = 0.6 + 0.4 * abs(sin(t * 2.4))   // a little heartbeat
        case .sport(_):
            if Self.cheering(at: t) {
                // Jumps up and cheers!
                let c = t.truncatingRemainder(dividingBy: 5) / 1.3
                p.lift = sin(c * .pi) * 22
                p.leftArm = 155 + sin(t * 18) * 10
                p.rightArm = -155 - sin(t * 18) * 10
                p.eyes = .happy
                p.mouth = .grin
                p.antennaGlow = 1
            } else {
                // Glued to the game: leaning in, eyes wide, fists clenched.
                p.tilt = -3 + sin(t * 1.5)
                p.eyeScale = 1.1
                p.look = CGSize(width: -2.5, height: -0.5)
                p.leftArm = -20 + sin(t * 9) * 3
                p.rightArm = 20 - sin(t * 9) * 3
                p.mouth = sin(t * 0.9) > 0.7 ? .oh : .focus
                p.antennaGlow = 0.5
            }
            p.antenna = Color(red: 0.3, green: 0.85, blue: 0.4)
        case .work(_):
            break   // drawn as the regular "working" routine
        case .browse(let kind, _):
            switch kind {
            case .social, .chat:
                // Thumb flicking through a feed, eyes down.
                p.look = CGSize(width: 1, height: 3)
                p.rightArm = 48 + sin(t * 7) * 9
                p.leftArm = 14
                p.tilt = 2
                p.mouth = sin(t * 0.8) > 0.5 ? .grin : .smile
            case .shopping:
                p.lift = abs(sin(t * 4)) * 6
                p.leftArm = 110 + sin(t * 8) * 15
                p.rightArm = -30
                p.eyes = .happy
                p.mouth = .grin
                p.eyeScale = 1.1
            case .food:
                p.mouth = sin(t * 3) > 0 ? .oh : .grin
                p.leftArm = -55 + sin(t * 4) * 8      // rubbing tummy
                p.rightArm = 55 - sin(t * 4) * 8
                p.eyes = sin(t * 1.5) > 0.6 ? .happy : .open(1)
                p.tilt = sin(t * 2) * 3
            case .movie:
                p.eyeScale = 1.15
                p.look = CGSize(width: 0, height: -1)
                p.rightArm = 70 + max(0, sin(t * 2)) * 30    // popcorn to mouth
                p.leftArm = 10
                p.mouth = sin(t * 2) > 0.8 ? .oh : .smile
            case .travel:
                p.tilt = sin(t * 1.5) * 7
                p.leftArm = 90 + sin(t * 1.5) * 25      // arms out like wings
                p.rightArm = -90 + sin(t * 1.5) * 25
                p.lift = 3 + sin(t * 3) * 2
                p.eyes = .happy
                p.mouth = .grin
            case .money:
                p.mouth = .focus
                p.eyeScale = 0.95
                p.look = CGSize(width: sin(t * 1.2) * 3, height: 1)
                p.rightArm = 72 + sin(t * 7) * 5
            case .games:
                p.lift = abs(sin(t * 6)) * 4
                p.leftArm = -45 + sin(t * 20) * 10       // button mashing
                p.rightArm = 45 + sin(t * 20 + 1) * 10
                p.eyes = sin(t * 2) > 0.7 ? .happy : .open(1)
                p.eyeScale = 1.1
                p.mouth = .grin
            case .news, .learning, .search:
                break   // drawn as reading / thinking
            case .other:
                // Curious: looking around the page.
                p.look = CGSize(width: sin(t * 0.9) * 3.5, height: cos(t * 1.3) * 2)
                p.tilt = sin(t * 0.7) * 4
                p.mouth = .smile
            }
        case .sad:
            p.squash = 0.97 + 0.01 * sin(t * 0.8)
            p.tilt = sin(t * 0.8) * 3
            p.leftArm = 3
            p.rightArm = -3
            p.look = CGSize(width: 0, height: 2)
            p.eyes = .open(0.55)
            p.mouth = .frown
            p.antenna = Color(red: 0.45, green: 0.6, blue: 0.95)
            p.antennaGlow = 0.25
        case .happy:
            p.lift = abs(sin(t * 5)) * 9
            p.squash = 1 + 0.05 * sin(t * 10)
            p.tilt = sin(t * 2.5) * 8
            p.leftArm = 120 + sin(t * 5) * 25
            p.rightArm = -120 + sin(t * 5) * 25
            p.leftFoot = max(0, sin(t * 5)) * 4
            p.rightFoot = max(0, -sin(t * 5)) * 4
            p.eyes = .happy
            p.mouth = .grin
            p.antenna = Color(red: 1, green: 0.45, blue: 0.7)
            p.antennaGlow = 0.5 + 0.5 * abs(sin(t * 5))
        case .groove:
            // Nodding along to the beat.
            p.squash = 1 + 0.04 * sin(t * 6)
            p.tilt = sin(t * 3) * 4
            p.leftArm = 20 + sin(t * 6) * 8
            p.rightArm = -20 + sin(t * 6) * 8
            p.eyes = sin(t * 3) > 0.6 ? .closed : .happy
            p.mouth = .smile
            p.antenna = Color(red: 0.55, green: 0.5, blue: 1)
            p.antennaGlow = 0.4 + 0.4 * abs(sin(t * 6))
        }
    }
}
