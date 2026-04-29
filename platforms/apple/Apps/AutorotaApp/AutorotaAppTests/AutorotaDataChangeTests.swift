import Foundation
import Testing
@testable import AutorotaApp

@Suite("AutorotaDataChange — typed notification payload")
struct AutorotaDataChangeTests {

    @Test func payloadEncodesIntoUserInfo() async {
        let center = NotificationCenter()
        let received: AutorotaDataChange? = await withCheckedContinuation { cont in
            let token = center.addObserver(
                forName: .autorotaDataChanged,
                object: nil,
                queue: nil
            ) { note in
                cont.resume(returning: note.autorotaDataChange)
            }
            // Post directly so we don't depend on the global default centre
            // and so the observer above sees this exact post.
            let change = AutorotaDataChange(
                source: .local,
                tables: [.employee, .shift],
                rowIDs: [42, 43]
            )
            center.post(
                name: .autorotaDataChanged,
                object: nil,
                userInfo: ["change": change]
            )
            _ = token
        }

        #expect(received?.source == .local)
        #expect(received?.tables == [.employee, .shift])
        #expect(received?.rowIDs == [42, 43])
    }

    @Test func legacyPostWithoutUserInfoStillReachesObserversWithNilPayload() async {
        let center = NotificationCenter()
        let result: Bool = await withCheckedContinuation { cont in
            let token = center.addObserver(
                forName: .autorotaDataChanged,
                object: nil,
                queue: nil
            ) { note in
                // Back-compat: a bare post must produce `nil` so listeners
                // know they need to fall back to a full reload.
                cont.resume(returning: note.autorotaDataChange == nil)
            }
            center.post(name: .autorotaDataChanged, object: nil)
            _ = token
        }

        #expect(result == true)
    }

    @Test func tableFromTableNameMapsKnownTables() {
        #expect(AutorotaDataChange.Table.from(tableName: "employee") == [.employee])
        #expect(AutorotaDataChange.Table.from(tableName: "employees") == [.employee])
        #expect(AutorotaDataChange.Table.from(tableName: "shift_template") == [.shiftTemplate])
        #expect(AutorotaDataChange.Table.from(tableName: "employee_availability_override")
                == [.employeeAvailabilityOverride])
    }

    @Test func tableFromTableNameFallsBackOnUnknown() {
        // Unrecognised remote table → conservative full-reload set so a
        // schema addition doesn't silently drop on the client.
        let result = AutorotaDataChange.Table.from(tableName: "future_table_v3")
        #expect(result == Set(AutorotaDataChange.Table.allCases))
    }

    @Test func remoteSyncSourceIsDistinctFromLocal() {
        // Sync engine drops events with source == .remoteSync to break
        // reentrancy. Verify the enum carries the distinction.
        let local = AutorotaDataChange(source: .local, tables: [.shift], rowIDs: nil)
        let remote = AutorotaDataChange(source: .remoteSync, tables: [.shift], rowIDs: nil)
        #expect(local.source != remote.source)
        #expect(local.source.rawValue == "local")
        #expect(remote.source.rawValue == "remoteSync")
    }
}
