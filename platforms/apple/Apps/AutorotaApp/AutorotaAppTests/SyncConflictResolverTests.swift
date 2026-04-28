import Foundation
import Testing
@testable import AutorotaApp

@Suite("SyncConflictResolver")
struct SyncConflictResolverTests {

    private let t0 = "2026-04-28T10:00:00Z"
    private let t1 = "2026-04-28T11:00:00Z"

    // MARK: - Three-way merge matrix

    @Test("server has no opinion (key absent) → local value preserved")
    func serverAbsentKeepsLocal() {
        let merged = SyncConflictResolver.merge(
            base: ["name": "Alice", "phone": "555-0001"],
            local: ["name": "Alice", "phone": "555-9999"],
            server: ["name": "Alice"], // phone omitted
            localLastModified: t1,
            serverLastModified: t1
        )
        #expect(merged["phone"] as? String == "555-9999")
    }

    @Test("server explicit NSNull clears the field")
    func serverNullClearsField() {
        let merged = SyncConflictResolver.merge(
            base: ["name": "Alice", "phone": "555-0001"],
            local: ["name": "Alice", "phone": "555-0001"],
            server: ["name": "Alice", "phone": NSNull()],
            localLastModified: t0,
            serverLastModified: t1
        )
        #expect(merged["phone"] is NSNull)
    }

    @Test("server deletion sentinel clears the field")
    func serverDeletionSentinelClearsField() {
        let sentinel: [String: Any] = [SyncConflictResolver.deletionSentinel: true]
        let merged = SyncConflictResolver.merge(
            base: ["name": "Alice", "phone": "555-0001"],
            local: ["name": "Alice", "phone": "555-0001"],
            server: ["name": "Alice", "phone": sentinel],
            localLastModified: t0,
            serverLastModified: t1
        )
        #expect(merged["phone"] is NSNull)
    }

    @Test("only-local-changed keeps local edit")
    func onlyLocalChanged() {
        let merged = SyncConflictResolver.merge(
            base: ["name": "Alice"],
            local: ["name": "Alicia"],
            server: ["name": "Alice"],
            localLastModified: t1,
            serverLastModified: t0
        )
        #expect(merged["name"] as? String == "Alicia")
    }

    @Test("only-server-changed takes server")
    func onlyServerChanged() {
        let merged = SyncConflictResolver.merge(
            base: ["name": "Alice"],
            local: ["name": "Alice"],
            server: ["name": "Bob"],
            localLastModified: t0,
            serverLastModified: t1
        )
        #expect(merged["name"] as? String == "Bob")
    }

    @Test("both-changed → later timestamp wins (server)")
    func bothChangedServerWins() {
        let merged = SyncConflictResolver.merge(
            base: ["name": "Alice"],
            local: ["name": "Alicia"],
            server: ["name": "Bob"],
            localLastModified: t0,
            serverLastModified: t1
        )
        #expect(merged["name"] as? String == "Bob")
    }

    @Test("both-changed → later timestamp wins (local)")
    func bothChangedLocalWins() {
        let merged = SyncConflictResolver.merge(
            base: ["name": "Alice"],
            local: ["name": "Alicia"],
            server: ["name": "Bob"],
            localLastModified: t1,
            serverLastModified: t0
        )
        #expect(merged["name"] as? String == "Alicia")
    }

    // MARK: - Equality

    @Test("Bool true and NSNumber 1 are unequal")
    func boolNotEqualToInt() {
        #expect(!SyncConflictResolver.valuesEqual(true, NSNumber(value: 1)))
    }

    @Test("NSNumber(1) == NSNumber(1.0) (numeric isEqual)")
    func intEqualsDoubleNumeric() {
        #expect(SyncConflictResolver.valuesEqual(NSNumber(value: 1), NSNumber(value: 1.0)))
    }

    @Test("number and string with same lexical form are unequal")
    func numberNotEqualToString() {
        #expect(!SyncConflictResolver.valuesEqual(NSNumber(value: 1), "1"))
    }

    @Test("nil and NSNull are equal")
    func nilEqualsNSNull() {
        #expect(SyncConflictResolver.valuesEqual(nil, NSNull()))
    }
}
