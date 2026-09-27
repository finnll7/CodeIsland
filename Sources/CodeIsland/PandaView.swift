import SwiftUI

/// PandaView — Panda Code mascot built from the official Panda Desktop icon
/// (extracted from "Panda 桌面版.app/Contents/Resources/app.asar",
/// dist/renderer/assets/panda-icon-BmBoTWLd.png).
///
/// The source set ships no per-state artwork (only a light/dark icon pair),
/// so the three agent states are expressed as overlays on the single icon —
/// per the chosen design:
///   idle   → dimmed icon + a drifting "z" badge
///   work   → breathing scale + orbiting progress arc
///   alert  → red "!" badge + subtle shake
struct PandaView: View {
    let status: MascotAgentStatus
    var size: CGFloat = 27

    @State private var alive = false

    /// Official Panda Desktop icon. The SPM resource bundle mirrors the
    /// project's `Resources/` directory one level below the bundle root,
    /// hence the "Resources" subdirectory probe with a flat fallback.
    private static let desktopIcon: NSImage? = {
        let bundle = Bundle.appModule
        if let url = bundle.url(forResource: "panda-desktop", withExtension: "png", subdirectory: "Resources"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let url = bundle.url(forResource: "panda-desktop", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }()

    var body: some View {
        ZStack {
            baseIcon
            switch status {
            case .idle:
                idleOverlay
            case .processing, .running:
                workOverlay
            case .waitingApproval, .waitingQuestion:
                alertOverlay
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

    // MARK: - Base

    private var baseIcon: some View {
        Group {
            if let image = Self.desktopIcon {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .opacity(status == .idle ? 0.45 : 1.0)
            } else {
                // Resource-missing fallback: keep a recognizable silhouette.
                PandaFallbackFace()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    // MARK: - Idle: drifting z badge

    private var idleOverlay: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let cycle = (t.truncatingRemainder(dividingBy: 3.0)) / 3.0
            VStack {
                HStack {
                    Spacer()
                    Text("z")
                        .font(.system(size: max(6, size * 0.28), weight: .black, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .offset(x: size * 0.12, y: -size * (0.1 + 0.25 * cycle))
                        .opacity((1.0 - cycle) * 0.9)
                }
                Spacer()
            }
        }
    }

    // MARK: - Work: breathing + orbiting arc

    private var workOverlay: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breathe = 1.0 + sin(t * 2 * .pi / 1.6) * 0.045
            let spin = (t.truncatingRemainder(dividingBy: 1.4)) / 1.4
            ZStack {
                baseIcon
                    .scaleEffect(breathe)
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(
                        AngularGradient(
                            colors: [.white.opacity(0.9), .white.opacity(0.1)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: max(1.5, size * 0.06), lineCap: .round)
                    )
                    .frame(width: size * 0.96, height: size * 0.96)
                    .rotationEffect(.degrees(-90 + spin * 360))
            }
        }
    }

    // MARK: - Alert: red "!" badge + shake

    private var alertOverlay: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // Brief shake every 2s, settled otherwise.
            let phase = t.truncatingRemainder(dividingBy: 2.0)
            let shake = phase < 0.4 ? sin(phase * 2 * .pi / 0.1) * size * 0.04 : 0
            ZStack {
                baseIcon
                    .offset(x: shake)
                VStack {
                    HStack {
                        Spacer()
                        ZStack {
                            Circle()
                                .fill(Color(red: 1.0, green: 0.24, blue: 0.0))
                                .frame(width: size * 0.42, height: size * 0.42)
                            Text("!")
                                .font(.system(size: max(6, size * 0.3), weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .offset(x: size * 0.12, y: -size * 0.12)
                    }
                    Spacer()
                }
            }
        }
    }
}

/// Minimal vector fallback when the bundled icon cannot be loaded.
private struct PandaFallbackFace: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack {
                Circle().fill(Color(red: 0.95, green: 0.95, blue: 0.95))
                Circle().frame(width: s * 0.32).offset(x: -s * 0.22, y: -s * 0.05)
                Circle().frame(width: s * 0.32).offset(x: s * 0.22, y: -s * 0.05)
                Ellipse().frame(width: s * 0.1, height: s * 0.07).offset(y: s * 0.25)
            }
        }
    }
}

#Preview("PandaCode") {
    VStack(spacing: 12) {
        PandaView(status: .idle, size: 54)
        PandaView(status: .running, size: 54)
        PandaView(status: .waitingApproval, size: 54)
    }
    .padding()
    .background(Color.black)
}
