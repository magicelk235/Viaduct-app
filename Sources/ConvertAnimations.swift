import SwiftUI
import Combine

// MARK: - Conversion orbit

/// The converting card's centerpiece: the extension's icon in the middle, and
/// the parts it is made of — manifest, scripts, images, styles, pages, build —
/// orbiting around it on flattened elliptical paths with depth (they dim and
/// shrink behind the tile, swing bright in front). As each phase completes,
/// one satellite spirals inward, accelerating, and is absorbed: the icon bumps
/// and its glow flares as it swallows the piece. By the end the icon has taken
/// everything in and stands alone — the extension, assembled.
///
/// During the finishing race (CLI already exited 0) the remaining satellites
/// cascade in, then `onComplete` fires exactly once — the same contract the
/// old progress bar had.
struct ConversionOrbit: View {
    var phase: ConvertPhase
    var icon: NSImage?
    /// When true, the CLI has finished — absorb everything left, then fire
    /// `onComplete` exactly once.
    var finishing: Bool = false
    var onComplete: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Per-satellite absorption start time (reference-date seconds); nil = still orbiting.
    @State private var absorbStart: [TimeInterval?] = Array(repeating: nil, count: Satellite.all.count)
    @State private var didComplete = false

    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private let stageWidth: CGFloat = 250
    private let stageHeight: CGFloat = 150
    private let tileSize: CGFloat = 60
    private let absorbDuration: TimeInterval = 0.7

    /// One orbiting ingredient of the extension.
    private struct Satellite {
        let symbol: String
        let rx: CGFloat        // orbit x radius
        let ry: CGFloat        // orbit y radius (flattened → reads as depth)
        let speed: Double      // rad/s
        let theta0: Double     // starting angle
        let tilt: Double       // orbit plane rotation

        // Pairs absorbed around the same time share a speed and start π apart,
        // so the last few orbiters stay spread out instead of clumping into a
        // blob beside the icon.
        static let all: [Satellite] = [
            .init(symbol: "doc.text",           rx: 84, ry: 26, speed: 0.55, theta0: 0.0,  tilt: -0.15),
            .init(symbol: "curlybraces",        rx: 74, ry: 32, speed: 0.70, theta0: 2.1,  tilt:  0.20),
            .init(symbol: "photo",              rx: 92, ry: 22, speed: 0.50, theta0: 1.2,  tilt:  0.05),
            .init(symbol: "paintbrush.pointed", rx: 68, ry: 28, speed: 0.50, theta0: 4.34, tilt: -0.15),
            .init(symbol: "globe",              rx: 80, ry: 30, speed: 0.58, theta0: 0.6,  tilt:  0.12),
            .init(symbol: "gearshape",          rx: 90, ry: 24, speed: 0.58, theta0: 3.74, tilt: -0.08),
        ]
    }

    /// How many satellites should be absorbed right now.
    private var targetAbsorbed: Int {
        finishing ? Satellite.all.count
                  : ConvertPhase.track.firstIndex(of: phase) ?? 0
    }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                glow(t)
                ForEach(Array(Satellite.all.enumerated()), id: \.offset) { idx, sat in
                    satelliteView(idx, sat, t)
                }
                iconTile(t)
                    .zIndex(1)
            }
        }
        .frame(width: stageWidth, height: stageHeight)
        .onReceive(ticker) { _ in tick() }
    }

    // MARK: Orbit math

    /// Absorption progress 0…1 for a satellite at time `t`.
    private func absorb(_ idx: Int, _ t: TimeInterval) -> Double {
        guard let start = absorbStart[idx] else { return 0 }
        if reduceMotion { return 1 }
        return min(max((t - start) / absorbDuration, 0), 1)
    }

    @ViewBuilder
    private func satelliteView(_ idx: Int, _ sat: Satellite, _ t: TimeInterval) -> some View {
        let s = absorb(idx, t)
        if s < 1 {
            // Suck-in: radius collapses with an ease-in while the angle speeds
            // up, so the piece visibly spirals into the icon.
            let pull = s * s
            let theta = sat.theta0 + (reduceMotion ? 0 : t * sat.speed) + s * 3.5
            let r = 1 - pull
            let ox = CGFloat(cos(theta)) * sat.rx * r
            let oy = CGFloat(sin(theta)) * sat.ry * r
            let x = ox * CGFloat(cos(sat.tilt)) - oy * CGFloat(sin(sat.tilt))
            let y = ox * CGFloat(sin(sat.tilt)) + oy * CGFloat(cos(sat.tilt))
            // Depth: +sin(theta) is the near side of the orbit.
            let frontness = (sin(theta) + 1) / 2        // 0 far … 1 near
            let scale = (0.78 + 0.28 * frontness) * (1 - 0.5 * pull)
            let fade = s > 0.7 ? 1 - (s - 0.7) / 0.3 : 1

            ZStack {
                Circle().fill(Theme.Colors.surfaceElevated)
                Image(systemName: sat.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.primary)
            }
            .frame(width: 24, height: 24)
            .overlay(Circle().strokeBorder(Theme.Colors.hairline, lineWidth: 1))
            .scaleEffect(CGFloat(scale))
            .opacity((0.55 + 0.45 * frontness) * fade)
            .position(x: stageWidth / 2 + x, y: stageHeight / 2 + y)
            .zIndex(frontness > 0.5 ? 2 : 0)
        }
    }

    // MARK: Center icon

    /// The swallow bump: a decaying spike right after each absorption lands.
    private func pulse(_ t: TimeInterval) -> Double {
        absorbStart.compactMap { $0 }.reduce(0) { acc, start in
            let dt = t - (start + absorbDuration)
            guard dt > 0, dt < 1 else { return acc }
            return acc + exp(-dt / 0.22)
        }
    }

    private func glow(_ t: TimeInterval) -> some View {
        let absorbed = absorbStart.compactMap { $0 }.count
        let base = 0.05 + 0.012 * Double(absorbed)
        return Circle()
            .fill(Theme.Colors.primary.opacity(min(base + 0.12 * pulse(t), 0.28)))
            .frame(width: tileSize + 8, height: tileSize + 8)
            .blur(radius: 16)
    }

    private func iconTile(_ t: TimeInterval) -> some View {
        ZStack {
            Color.clear
                .liquidGlass(radius: 16)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.Colors.hairline, lineWidth: 1))

            if let icon {
                Image(nsImage: icon)
                    .resizable().interpolation(.high)
                    .scaledToFit()
                    .padding(8)
            } else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.Colors.primary)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .frame(width: tileSize, height: tileSize)
        .scaleEffect(1 + 0.06 * min(pulse(t), 1.4))
    }

    // MARK: Absorption schedule

    /// Start absorbing any satellite the phase (or the finishing race) says is
    /// due, staggered so simultaneous triggers cascade instead of vanishing at
    /// once. After the last one lands, hold the completed stage — the icon
    /// alone, glow settling — for a beat before `onComplete` flips the flow to
    /// done, so the finish is something the user actually sees.
    private func tick() {
        let now = Date().timeIntervalSinceReferenceDate
        var delay: TimeInterval = 0
        for idx in 0..<targetAbsorbed where absorbStart[idx] == nil {
            absorbStart[idx] = now + delay
            delay += 0.18
        }
        if finishing, !didComplete,
           absorbStart.allSatisfy({ $0 != nil }),
           let last = absorbStart.compactMap({ $0 }).max(),
           now > last + absorbDuration + 1.5 {
            didComplete = true
            onComplete?()
        }
    }
}
