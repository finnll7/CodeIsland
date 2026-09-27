import SwiftUI

/// PandaView — Panda Code mascot, a pixel panda face.
/// Black-and-white bear with dark eye patches, round ears, and a gentle expression.
/// Animations: idle (sleeping with zzz), working (typing with bounce), alert (startled).
struct PandaView: View {
    let status: MascotAgentStatus
    var size: CGFloat = 27
    @State private var alive = false

    private static let bodyC     = Color(red: 0.95, green: 0.95, blue: 0.95)  // white fur
    private static let blackC    = Color(red: 0.12, green: 0.12, blue: 0.14)  // black patches
    private static let eyeWhite  = Color(red: 1.0, green: 1.0, blue: 1.0)
    private static let noseC     = Color(red: 0.20, green: 0.20, blue: 0.22)
    private static let cheekC    = Color(red: 1.0, green: 0.75, blue: 0.75)   // blush
    private static let alertC    = Color(red: 1.0, green: 0.24, blue: 0.0)
    private static let earInner  = Color(red: 0.22, green: 0.22, blue: 0.24)

    var body: some View {
        Group {
            switch status {
            case .idle:                 sleepScene
            case .processing, .running: workScene
            case .waitingApproval, .waitingQuestion: alertScene
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .onAppear { alive = true }
        .onChange(of: status) {
            alive = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { alive = true }
        }
    }

    private struct V {
        let ox: CGFloat, oy: CGFloat, s: CGFloat, y0: CGFloat
        init(_ sz: CGSize, svgW: CGFloat = 14, svgH: CGFloat = 14, svgY0: CGFloat = 2) {
            s = min(sz.width / svgW, sz.height / svgH)
            ox = (sz.width - svgW * s) / 2
            oy = (sz.height - svgH * s) / 2
            y0 = svgY0
        }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, dy: CGFloat = 0) -> CGRect {
            CGRect(x: ox + x * s, y: oy + (y - y0 + dy) * s, width: w * s, height: h * s)
        }
    }

    private func lerp(_ keyframes: [(CGFloat, CGFloat)], at pct: CGFloat) -> CGFloat {
        guard let first = keyframes.first else { return 0 }
        if pct <= first.0 { return first.1 }
        for i in 1..<keyframes.count {
            if pct <= keyframes[i].0 {
                let t = (pct - keyframes[i-1].0) / (keyframes[i].0 - keyframes[i-1].0)
                return keyframes[i-1].1 + (keyframes[i].1 - keyframes[i-1].1) * t
            }
        }
        return keyframes.last?.1 ?? 0
    }

    // MARK: - Draw panda face

    private func drawFace(_ c: GraphicsContext, v: V, dy: CGFloat, eyeOpen: CGFloat = 1.0, blinkPhase: CGFloat = 1.0) {
        // Shadow
        c.fill(Path(v.r(3.5, 15, 7, 1)), with: .color(.black.opacity(0.2)))

        // Ears (black circles on top)
        c.fill(Path(ellipseIn: v.r(2.5, 3, 3, 3, dy: dy)), with: .color(Self.blackC))
        c.fill(Path(ellipseIn: v.r(8.5, 3, 3, 3, dy: dy)), with: .color(Self.blackC))
        // Ear inner
        c.fill(Path(ellipseIn: v.r(3.2, 3.7, 1.6, 1.6, dy: dy)), with: .color(Self.earInner))
        c.fill(Path(ellipseIn: v.r(9.2, 3.7, 1.6, 1.6, dy: dy)), with: .color(Self.earInner))

        // Head (white round face)
        c.fill(Path(ellipseIn: v.r(2, 4.5, 10, 8, dy: dy)), with: .color(Self.bodyC))

        // Eye patches (black ovals)
        let patchH: CGFloat = 3.2 * eyeOpen
        c.fill(Path(ellipseIn: v.r(3.2, 6.5, 3, patchH, dy: dy)), with: .color(Self.blackC))
        c.fill(Path(ellipseIn: v.r(7.8, 6.5, 3, patchH, dy: dy)), with: .color(Self.blackC))

        // Eyes (white dots inside patches)
        let eyeH: CGFloat = 1.4 * blinkPhase
        if blinkPhase > 0.3 {
            c.fill(Path(ellipseIn: v.r(4.2, 7.2, 1.2, max(0.2, eyeH), dy: dy)), with: .color(Self.eyeWhite))
            c.fill(Path(ellipseIn: v.r(8.6, 7.2, 1.2, max(0.2, eyeH), dy: dy)), with: .color(Self.eyeWhite))
        } else {
            // Closed eyes — thin line
            c.fill(Path(v.r(3.8, 7.8, 2, 0.3, dy: dy)), with: .color(Self.eyeWhite.opacity(0.6)))
            c.fill(Path(v.r(8.2, 7.8, 2, 0.3, dy: dy)), with: .color(Self.eyeWhite.opacity(0.6)))
        }

        // Nose
        c.fill(Path(ellipseIn: v.r(6.2, 9.5, 1.6, 1, dy: dy)), with: .color(Self.noseC))

        // Cheeks (blush)
        c.fill(Path(ellipseIn: v.r(2.5, 9.5, 1.5, 1, dy: dy)), with: .color(Self.cheekC.opacity(0.4)))
        c.fill(Path(ellipseIn: v.r(10, 9.5, 1.5, 1, dy: dy)), with: .color(Self.cheekC.opacity(0.4)))
    }

    // MARK: - Scenes

    private var sleepScene: some View {
        ZStack {
            MascotTimeline(interval: 0.12) { t in
                let float = sin(t * 2 * .pi / 4.1) * 0.5 + sin(t * 2 * .pi / 6.8) * 0.3
                let blinkCycle = t.truncatingRemainder(dividingBy: 5.0)
                let blink: CGFloat = (blinkCycle > 4.2 && blinkCycle < 4.4) ? 0.15 : 0.3
                Canvas { c, sz in
                    let v = V(sz, svgW: 14, svgH: 12, svgY0: 4)
                    drawFace(c, v: v, dy: float, eyeOpen: 0.6, blinkPhase: blink)
                }
            }
            MascotTimeline(interval: 0.12) { t in
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 3.0 + ci * 0.4; let delay = ci * 1.0
                        let phase = max(0, ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle)
                        let fontSize = max(6, size * CGFloat(0.16 + phase * 0.10))
                        let opacity = phase < 0.8 ? (0.6 - ci * 0.1) : (1.0 - phase) * 3.0 * (0.6 - ci * 0.1)
                        Text("z").font(.system(size: fontSize, weight: .black, design: .monospaced))
                            .foregroundStyle(Self.blackC.opacity(opacity))
                            .offset(x: size * CGFloat(0.18 + ci * 0.07), y: -size * CGFloat(0.12 + phase * 0.38))
                    }
                }
            }
        }
    }

    private var workScene: some View {
        MascotTimeline(interval: 0.03) { t in
            let workPause = MascotMotion.quirk(t, cycle: 9.7, duration: 1.0, seed: 0xd0)
            let bounce = sin(t * 2 * .pi / 0.45) * 0.8 * (1 - workPause)
                + sin(t * 2 * .pi / 3.1) * 0.25 * workPause
            let blink = max(0.1, MascotMotion.blink(t, seed: 0xd1))
            Canvas { c, sz in
                let v = V(sz, svgW: 14, svgH: 14, svgY0: 2)
                drawFace(c, v: v, dy: bounce, blinkPhase: blink)
            }
        }
    }

    private var alertScene: some View {
        ZStack {
            Circle().fill(Self.alertC.opacity(alive ? 0.12 : 0)).frame(width: size * 0.8)
                .blur(radius: size * 0.05)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: alive)
            MascotTimeline(interval: 0.03) { t in
                let pct = t.truncatingRemainder(dividingBy: 3.0) / 3.0
                let jumpY = lerp([(0,0),(0.04,0),(0.15,-6),(0.22,1),(0.25,-4),(0.35,0.8),(0.4,-2),(0.5,0.3),(0.55,0),(1,0)], at: pct)
                let shakeX: CGFloat = (pct > 0.12 && pct < 0.5) ? sin(pct * 70) * 0.5 : 0
                let bangOp = lerp([(0,0),(0.04,1),(0.5,1),(0.58,0),(1,0)], at: pct)
                Canvas { c, sz in
                    let v = V(sz, svgW: 14, svgH: 14, svgY0: 2)
                    c.translateBy(x: shakeX * v.s, y: 0)
                    drawFace(c, v: v, dy: jumpY, eyeOpen: 1.2)
                    c.translateBy(x: -shakeX * v.s, y: 0)
                    // Exclamation mark
                    if bangOp > 0.01 {
                        c.fill(Path(v.r(12, 3 + jumpY * 0.1, 1.5, 3)), with: .color(Self.alertC.opacity(bangOp)))
                        c.fill(Path(v.r(12, 7 + jumpY * 0.1, 1.5, 1.2)), with: .color(Self.alertC.opacity(bangOp)))
                    }
                }
            }
        }
    }
}

#Preview("PandaCode") {
    VStack(spacing: 12) {
        PandaView(status: .idle,            size: 54)
        PandaView(status: .running,         size: 54)
        PandaView(status: .waitingApproval, size: 54)
    }
    .padding()
    .background(Color.black)
}
