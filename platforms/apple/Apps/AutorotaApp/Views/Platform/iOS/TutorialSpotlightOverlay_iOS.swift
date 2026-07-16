#if os(iOS)
import SwiftUI

// MARK: - Spotlight overlay (iPhone / iPad only)

/// Full-screen dim layer with a rounded-rect hole cut around the active
/// target, plus a tooltip bubble with the instruction and sub-progress.
/// The dim layer never intercepts touches — the user always performs the
/// pointed-at action themselves; only the tooltip's Skip button is tappable.
struct TutorialSpotlightOverlay: View {
    let spotlight: DemoSpotlight
    /// Resolved frame of the target, in global coordinates. Nil when the
    /// target isn't on screen (yet) — the tooltip floats without a hole.
    let targetFrame: CGRect?
    let onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let holePadding: CGFloat = 6
    private static let holeCornerRadius: CGFloat = 10

    private var holeRect: CGRect? {
        targetFrame?.insetBy(dx: -Self.holePadding, dy: -Self.holePadding)
    }

    var body: some View {
        GeometryReader { geo in
            let bounds = geo.frame(in: .global)
            ZStack(alignment: .topLeading) {
                if holeRect != nil {
                    dimLayer(bounds: bounds)
                        .allowsHitTesting(false)
                    anchoredTooltip(bounds: bounds)
                } else {
                    // No locatable target (tab-switch prompts): sit just
                    // above the tab bar, pointing down at it.
                    bottomFloatingTooltip
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: targetFrame)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func dimLayer(bounds: CGRect) -> some View {
        if let holeRect {
            // Even-odd fill: full-screen rect + hole path = dim everywhere
            // except the hole.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: bounds.size))
                let local = holeRect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                path.addRoundedRect(
                    in: local,
                    cornerSize: CGSize(width: Self.holeCornerRadius, height: Self.holeCornerRadius)
                )
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            .overlay(
                RoundedRectangle(cornerRadius: Self.holeCornerRadius)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: holeRect.width, height: holeRect.height)
                    .position(
                        x: holeRect.midX - bounds.minX,
                        y: holeRect.midY - bounds.minY
                    )
            )
        }
    }

    /// Tooltip for a spotlighted target: on whichever side of the hole has
    /// more room, arrow pointing at the hole.
    @ViewBuilder
    private func anchoredTooltip(bounds: CGRect) -> some View {
        if let holeRect {
            let holeInLocal = holeRect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            let placeBelow = holeInLocal.midY < bounds.height / 2

            VStack(alignment: .leading, spacing: 8) {
                if placeBelow {
                    arrow(pointingUp: true)
                        .padding(.leading, 24)
                }
                tooltipBubble
                if !placeBelow {
                    arrow(pointingUp: false)
                        .padding(.leading, 24)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
            .padding(.horizontal, 16)
            .position(
                x: min(max(holeInLocal.midX, 170), bounds.width - 170),
                y: placeBelow
                    ? min(holeInLocal.maxY + 70, bounds.height - 80)
                    : max(holeInLocal.minY - 70, 80)
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("demo.spotlight.tooltip")
        }
    }

    /// Tooltip for tab-switch prompts: bottom-anchored just above the tab
    /// bar, arrow pointing down at it.
    private var bottomFloatingTooltip: some View {
        VStack(spacing: 8) {
            tooltipBubble
            arrow(pointingUp: false)
        }
        .frame(maxWidth: 320)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 100)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("demo.spotlight.tooltip")
    }

    private var tooltipBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("demo.spotlight.progress \(spotlight.index) \(spotlight.total)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(spotlight.isInfo ? "demo.spotlight.next" : "demo.spotlight.skip") {
                    onSkip()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .accessibilityIdentifier("demo.spotlight.skip")
            }
            Text(LocalizedStringKey(spotlight.instructionKey))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    private func arrow(pointingUp: Bool) -> some View {
        Triangle()
            .fill(.regularMaterial)
            .frame(width: 18, height: 9)
            .rotationEffect(pointingUp ? .zero : .degrees(180))
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
#endif
