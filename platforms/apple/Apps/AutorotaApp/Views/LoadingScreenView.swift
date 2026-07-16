import SwiftUI

/// Boot loading screen: the app icon's pocket watch redrawn as vectors, with
/// the crown-click + dial-spin animation designed in the HTML playground
/// (2026-07-16). Plays once per cold boot for users who have already chosen
/// a plan — `AutorotaAppApp` decides whether to mount it.
///
/// Geometry is authored in the icon's native 1024×1024 space (dial centre at
/// (512, 565)) and scaled to fit the window. The spin easing is an exact
/// constant-acceleration → constant-deceleration curve (piecewise quadratic),
/// not a bezier approximation.
struct LoadingScreenView: View {
    /// Called exactly once, when the animation timeline has fully played
    /// (or immediately-ish under Reduce Motion). The caller crossfades to
    /// the app when this AND data loading have both completed.
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate: Date = .now
    @State private var timelineDone = false

    // MARK: - Tuned parameters (source of truth: rota-loading-playground.html)

    private enum P {
        static let startDelay: TimeInterval = 0.10
        static let crownPressDuration: TimeInterval = 0.24
        static let crownHoldDuration: TimeInterval = 0.12
        /// Overlaps the start of the spin — the band launches as the crown
        /// springs back up.
        static let crownReleaseDuration: TimeInterval = 0.32
        static let spinDuration: TimeInterval = 1.88
        static let spinDegrees: Double = 360
        /// Fraction of the spin spent accelerating. 0.435 gives ~30% higher
        /// constant acceleration than the 50/50 triangle while keeping the
        /// deceleration rate identical to the original 2.0 s / 50-50 tune.
        static let accelFraction: Double = 0.435
        static let crownPressDepth: Double = 16   // 1024-pt icon space
        static let wordmarkScale: Double = 0.92
        /// Full timeline (the parent owns the crossfade that follows).
        static var total: TimeInterval {
            startDelay + crownPressDuration + crownHoldDuration + spinDuration
        }
        /// Under Reduce Motion the dial is drawn static; hold it briefly so
        /// the swap to content doesn't flash.
        static let reducedMotionHold: TimeInterval = 0.8
    }

    // MARK: - Colors (sampled from AppIcon rota-icon-azure.png)

    private static let azure = Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0)
    private static let steel = Color(red: 0x87 / 255.0, green: 0x94 / 255.0, blue: 0xA3 / 255.0)
    private static let groove = Color(red: 0x5F / 255.0, green: 0x6B / 255.0, blue: 0x7A / 255.0)
    private static let dotGray = Color(red: 0xDE / 255.0, green: 0xE3 / 255.0, blue: 0xE9 / 255.0)
    private static let tickGray = Color(red: 0xD2 / 255.0, green: 0xD8 / 255.0, blue: 0xDF / 255.0)
    private static let chapterGray = Color(red: 0xE9 / 255.0, green: 0xEC / 255.0, blue: 0xF0 / 255.0)

    private static var backgroundColor: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    var body: some View {
        TimelineView(.animation(paused: timelineDone || reduceMotion)) { context in
            Canvas { ctx, size in
                let t = reduceMotion ? 0 : context.date.timeIntervalSince(startDate)
                draw(in: &ctx, size: size, at: t)
            }
        }
        .background(Self.backgroundColor)
        .ignoresSafeArea()
        .task {
            let wait = reduceMotion ? P.reducedMotionHold : P.total
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            timelineDone = true
            onFinished()
        }
    }

    // MARK: - Timeline evaluation

    /// Ease-in cubic: the crown resists, then gives way.
    private func easeInCubic(_ p: Double) -> Double { p * p * p }

    /// Underdamped spring settle for the release: sharp snap up, ~27%
    /// overshoot, one visible ring. `1 - e^(-5p)·cos(12p)`.
    private func springOut(_ p: Double) -> Double {
        1 - exp(-5 * p) * cos(12 * p)
    }

    /// Constant acceleration for u ∈ [0, f], constant deceleration for
    /// u ∈ (f, 1]. Returns spin progress 0→1 (C¹-continuous at u = f).
    private func spinProgress(_ u: Double) -> Double {
        let f = P.accelFraction
        return u <= f ? (u * u) / f : 1 - ((1 - u) * (1 - u)) / (1 - f)
    }

    /// Vertical offset of the crown head at time `t` (1024-pt space).
    private func crownOffset(at t: TimeInterval) -> Double {
        let pressStart = P.startDelay
        let holdStart = pressStart + P.crownPressDuration
        let releaseStart = holdStart + P.crownHoldDuration
        if t < pressStart { return 0 }
        if t < holdStart {
            return P.crownPressDepth * easeInCubic((t - pressStart) / P.crownPressDuration)
        }
        if t < releaseStart { return P.crownPressDepth }
        let p = (t - releaseStart) / P.crownReleaseDuration
        if p >= 1 { return 0 }
        return P.crownPressDepth * (1 - springOut(p))
    }

    /// Rotation of the notch + minute-dot band at time `t`, in degrees.
    private func bandAngle(at t: TimeInterval) -> Double {
        let spinStart = P.startDelay + P.crownPressDuration + P.crownHoldDuration
        guard t > spinStart else { return 0 }
        let u = min((t - spinStart) / P.spinDuration, 1)
        return P.spinDegrees * spinProgress(u)
    }

    // MARK: - Drawing (1024-pt icon space, dial centre (512, 565))

    private func draw(in ctx: inout GraphicsContext, size: CGSize, at t: TimeInterval) {
        let scale = min(size.width, size.height) * 0.82 / 1024
        ctx.translateBy(
            x: (size.width - 1024 * scale) / 2,
            y: (size.height - 1024 * scale) / 2
        )
        ctx.scaleBy(x: scale, y: scale)

        drawCrown(in: ctx, offset: crownOffset(at: t))
        drawCase(in: ctx)
        drawBand(in: ctx, angle: bandAngle(at: t))
        drawWordmark(in: ctx)
    }

    private func dialCircle(_ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: 512 - r, y: 565 - r, width: 2 * r, height: 2 * r))
    }

    private func roundedRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
    }

    private func drawCrown(in ctx: GraphicsContext, offset: Double) {
        // Stem and collar stay put; the head (cap + grip grooves) presses down.
        ctx.fill(roundedRect(496, 148, 32, 52, 6), with: .color(Self.azure))

        var head = ctx
        head.translateBy(x: 0, y: offset)
        head.fill(roundedRect(474, 102, 76, 54, 16), with: .color(Self.steel))
        var grooves = Path()
        for gx in [497.0, 512.0, 527.0] {
            grooves.move(to: CGPoint(x: gx, y: 116))
            grooves.addLine(to: CGPoint(x: gx, y: 142))
        }
        head.stroke(grooves, with: .color(Self.groove), style: StrokeStyle(lineWidth: 5, lineCap: .round))

        ctx.fill(roundedRect(486, 172, 52, 16, 8), with: .color(Self.steel))
    }

    private func drawCase(in ctx: GraphicsContext) {
        // The face stays white in both appearances, matching the icon.
        ctx.fill(dialCircle(368), with: .color(.white))
        ctx.stroke(dialCircle(368), with: .color(Self.azure), lineWidth: 10)
        ctx.stroke(dialCircle(346), with: .color(Self.azure), lineWidth: 24)
        ctx.stroke(dialCircle(288), with: .color(Self.chapterGray), lineWidth: 5)
    }

    private func drawBand(in ctx: GraphicsContext, angle: Double) {
        var band = ctx
        band.translateBy(x: 512, y: 565)
        band.rotate(by: .degrees(angle))
        band.translateBy(x: -512, y: -565)

        // Minute dots: every 6°, radius 312.5 (hour positions sit hidden
        // under the notches, exactly as in the icon SVG).
        var dots = Path()
        for i in 0..<60 {
            let a = Double(i) * 6 * .pi / 180
            let x = 512 + 312.5 * sin(a)
            let y = 565 - 312.5 * cos(a)
            dots.addEllipse(in: CGRect(x: x - 4, y: y - 4, width: 8, height: 8))
        }
        band.fill(dots, with: .color(Self.dotGray))

        // Hour notches: every 30°, spanning radius 296.5...328.5.
        var ticks = Path()
        for i in 0..<12 {
            let a = Double(i) * 30 * .pi / 180
            let (dx, dy) = (sin(a), -cos(a))
            ticks.move(to: CGPoint(x: 512 + 328.5 * dx, y: 565 + 328.5 * dy))
            ticks.addLine(to: CGPoint(x: 512 + 296.5 * dx, y: 565 + 296.5 * dy))
        }
        band.stroke(ticks, with: .color(Self.tickGray), style: StrokeStyle(lineWidth: 11, lineCap: .round))
    }

    private func drawWordmark(in ctx: GraphicsContext) {
        var word = ctx
        // Same transform chain as the icon SVG: scale about (512, 565) with
        // the wordmark's own vertical centre at 563.
        word.translateBy(x: 512, y: 565)
        word.scaleBy(x: P.wordmarkScale, y: P.wordmarkScale)
        word.translateBy(x: -512, y: -563)

        var strokes = Path()
        // r
        strokes.move(to: CGPoint(x: 252, y: 632))
        strokes.addLine(to: CGPoint(x: 252, y: 495))
        strokes.move(to: CGPoint(x: 252, y: 558))
        strokes.addQuadCurve(to: CGPoint(x: 311, y: 495), control: CGPoint(x: 252, y: 495))
        // o (the gear ring)
        strokes.addEllipse(in: CGRect(x: 423 - 56, y: 563 - 56, width: 112, height: 112))
        // t
        strokes.move(to: CGPoint(x: 535, y: 495))
        strokes.addLine(to: CGPoint(x: 607, y: 495))
        strokes.move(to: CGPoint(x: 569, y: 447))
        strokes.addLine(to: CGPoint(x: 569, y: 598))
        strokes.addQuadCurve(to: CGPoint(x: 603, y: 632), control: CGPoint(x: 569, y: 632))
        // a
        strokes.addEllipse(in: CGRect(x: 711 - 60, y: 563 - 60, width: 120, height: 120))
        strokes.move(to: CGPoint(x: 771, y: 495))
        strokes.addLine(to: CGPoint(x: 771, y: 632))
        word.stroke(strokes, with: .color(Self.azure), style: StrokeStyle(lineWidth: 30, lineCap: .round))

        // Gear teeth fused onto the o.
        for i in 0..<8 {
            var tooth = word
            tooth.translateBy(x: 423, y: 563)
            tooth.rotate(by: .degrees(22.5 + Double(i) * 45))
            tooth.translateBy(x: -423, y: -563)
            tooth.fill(roundedRect(413, 479, 20, 18, 5), with: .color(Self.azure))
        }

        // Gear axle.
        word.fill(
            Path(ellipseIn: CGRect(x: 423 - 9, y: 563 - 9, width: 18, height: 18)),
            with: .color(Self.steel)
        )
    }
}

#Preview {
    LoadingScreenView(onFinished: {})
}
