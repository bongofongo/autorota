import SwiftUI

/// Shared bridge between `ContentView`'s tab-bar dots button and the
/// `RotaView` that owns the schedule actions. The search-role tab in the
/// tab bar flips `overflowOpen`, and `RotaView` observes it to present its
/// overflow menu.
@Observable
final class RotaUIBridge {
    var overflowOpen: Bool = false
    var isEditMode: Bool = false
}
