import SwiftUI

/// Shared bridge between `ContentView`'s tab-bar dots button and the
/// `EmployeeListView` that owns the employee actions. The search-role tab
/// in the tab bar flips `overflowOpen`, and `EmployeeListView` observes it
/// to present its overflow menu.
@Observable
final class EmployeeUIBridge {
    var overflowOpen: Bool = false
}
