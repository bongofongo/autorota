import SwiftUI

/// Wraps `content` in a `NavigationStack` only when `embed` is true.
///
/// Tab-root pages own their navigation, so they embed (the default). When the
/// same page is *pushed* as a destination from the overflow Menu's existing
/// `NavigationStack`, it must NOT create a second, nested stack — nesting
/// triggers an iOS 26 bug where popping leaves the outer stack inert and
/// swallows all subsequent navigation. In that case `embed` is false and the
/// content attaches its title/toolbar/destinations to the Menu's stack instead.
struct OptionalNavigationStack<Content: View>: View {
    let embed: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if embed {
            NavigationStack { content }
        } else {
            content
        }
    }
}

private struct MenuPushedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when a page is rendered as a *pushed* destination inside the
    /// overflow Menu's `NavigationStack`. Root pages read this and skip
    /// creating their own stack (via `OptionalNavigationStack(embed:)`) so the
    /// two stacks never nest. Tab roots leave it at the default `false`.
    var isMenuPushed: Bool {
        get { self[MenuPushedKey.self] }
        set { self[MenuPushedKey.self] = newValue }
    }
}
