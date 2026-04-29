import Foundation
import Testing
@testable import AutorotaApp

@Suite("AutorotaSyncEngine — schedulePush debounce window")
struct SyncEngineDebounceTests {

    /// The window must be longer than typical UI interaction (≥ 250 ms) but
    /// short enough that the user doesn't perceive sync lag (≤ 1 s).
    /// Tightening these bounds is fine; loosening past them risks either
    /// thrashing CloudKit or making sync feel laggy.
    @Test func debounceWindowIsWithinReasonableBounds() {
        let window = AutorotaSyncEngine.pushDebounceWindow
        let lowerBound: Duration = .milliseconds(250)
        let upperBound: Duration = .seconds(1)
        #expect(window >= lowerBound, "window \(window) below 250 ms — risks thrashing CloudKit")
        #expect(window <= upperBound, "window \(window) above 1 s — risks user-visible sync lag")
    }
}
