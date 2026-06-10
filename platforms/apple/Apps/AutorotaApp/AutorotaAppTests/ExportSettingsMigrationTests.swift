import Foundation
import Testing
@testable import AutorotaApp

@Suite("ExportSettingsMigration")
struct ExportSettingsMigrationTests {

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "migration-tests-\(UUID().uuidString)"))
    }

    private static let staleKeys = [
        "exportShowShiftName", "exportShowTimes", "exportShowRole",
        "empExportShowShiftName", "empExportShowTimes", "empExportShowRole",
        "exportDefaultProfile", "empExportDefaultProfile",
        "exportDefaultPdfTemplate",
    ]

    @Test func removesStaleKeys() throws {
        let defaults = try makeDefaults()
        for key in Self.staleKeys {
            defaults.set("anything", forKey: key)
        }

        ExportSettingsMigration.run(defaults: defaults)

        for key in Self.staleKeys {
            #expect(defaults.object(forKey: key) == nil)
        }
    }

    @Test func leavesLayoutPrefAlone() throws {
        let defaults = try makeDefaults()
        defaults.set("shift_by_weekday", forKey: "exportDefaultLayout")

        ExportSettingsMigration.run(defaults: defaults)

        #expect(defaults.string(forKey: "exportDefaultLayout") == "shift_by_weekday")
    }

    @Test func isIdempotent() throws {
        let defaults = try makeDefaults()
        defaults.set("by_role", forKey: "exportDefaultPdfTemplate")

        ExportSettingsMigration.run(defaults: defaults)
        ExportSettingsMigration.run(defaults: defaults)

        #expect(defaults.object(forKey: "exportDefaultPdfTemplate") == nil)
        #expect(defaults.object(forKey: "exportShowTimes") == nil)
    }
}
