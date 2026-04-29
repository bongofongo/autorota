import Foundation
import Testing
@testable import AutorotaApp

@Suite("AutorotaSyncEngine — saved-state corruption recovery")
struct SyncStateValidationTests {

    @Test func emptyStringStoredValueReturnsNilWithoutCallback() {
        var corruptionCalled = false
        let result = AutorotaSyncEngine.decodeSavedState(stored: "") { _ in
            corruptionCalled = true
        }
        #expect(result == nil)
        #expect(corruptionCalled == false,
                "empty string is the explicit 'no saved state' sentinel, not corruption")
    }

    @Test func nilStoredValueReturnsNilWithoutCallback() {
        var corruptionCalled = false
        let result = AutorotaSyncEngine.decodeSavedState(stored: nil) { _ in
            corruptionCalled = true
        }
        #expect(result == nil)
        #expect(corruptionCalled == false)
    }

    @Test func malformedJsonInvokesCorruptionCallback() {
        var capturedReason: String?
        let result = AutorotaSyncEngine.decodeSavedState(
            stored: "{this is not json"
        ) { reason in
            capturedReason = reason
        }
        #expect(result == nil)
        #expect(capturedReason != nil, "corruption callback must fire on JSON decode failure")
        #expect(capturedReason?.contains("JSON decode failed") == true,
                "reason should describe the kind of corruption: \(capturedReason ?? "nil")")
    }

    @Test func validJsonButWrongShapeInvokesCorruptionCallback() {
        // Valid JSON, wrong type for CKSyncEngine.State.Serialization.
        var capturedReason: String?
        let result = AutorotaSyncEngine.decodeSavedState(
            stored: #"{"unexpected": "fields"}"#
        ) { reason in
            capturedReason = reason
        }
        #expect(result == nil)
        #expect(capturedReason != nil)
    }
}
