import SwiftUI

struct AppCard<Content: View>: View {
    var radius: CGFloat = SurfaceRadius.medium
    var padding: CGFloat = Spacing.lg
    @ViewBuilder var content: Content

    var body: some View {
        content.appSurface(radius: radius, padding: padding)
    }
}
