import SwiftUI

/// Routes external navigation requests into the Menu (Settings) tab's
/// `NavigationStack`. When a CTA outside Settings (e.g. RotaView's empty-state
/// "Add employee" button) targets a page that lives in the overflow Menu
/// because the user removed it from the tab bar, the dispatcher sets
/// `pendingDestination` and `SettingsView` consumes it on appear / change to
/// push the page programmatically. See IOS_BUGS.md #2.
@Observable
final class MenuNavigationBridge {
    var pendingDestination: TabPage?
}
