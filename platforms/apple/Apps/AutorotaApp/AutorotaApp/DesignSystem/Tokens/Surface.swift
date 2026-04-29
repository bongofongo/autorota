import SwiftUI

enum SurfaceRadius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
}

private struct SurfaceModifier: ViewModifier {
    let radius: CGFloat
    let padding: CGFloat

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
            )
        #else
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
        #endif
    }
}

extension View {
    func appSurface(radius: CGFloat = SurfaceRadius.medium, padding: CGFloat = Spacing.lg) -> some View {
        modifier(SurfaceModifier(radius: radius, padding: padding))
    }
}
