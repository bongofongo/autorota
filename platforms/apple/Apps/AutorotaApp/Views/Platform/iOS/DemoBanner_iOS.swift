#if os(iOS)
import SwiftUI

extension DemoModeController {
    /// On iOS, the spotlight overlay is the primary guidance; the hint
    /// card nudge only shows when the spotlight can't locate its target.
    var showsSpotlightHintNudge: Bool { isGuidanceHidden }
}

extension View {
    func demoChecklistInlineTitle() -> some View {
        navigationBarTitleDisplayMode(.inline)
    }
}
#endif
