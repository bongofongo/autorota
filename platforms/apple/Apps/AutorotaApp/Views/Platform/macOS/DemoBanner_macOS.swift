#if os(macOS)
import SwiftUI

extension DemoModeController {
    /// macOS has no spotlight overlay, so the hint card nudge always shows
    /// while a step is pending.
    var showsSpotlightHintNudge: Bool { true }
}

extension View {
    func demoChecklistInlineTitle() -> some View {
        self
    }
}
#endif
