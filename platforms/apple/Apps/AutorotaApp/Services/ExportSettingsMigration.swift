import Foundation

/// One-shot cleanup of export settings made obsolete by the custom-layout
/// sandbox: the per-field content toggles are gone (presets are fixed,
/// custom layouts persist in `ExportCustomLayout`), the profile picker was
/// replaced by the Cost pill, and the PDF template picker was removed
/// (weekly grid only; "by_role" is superseded by custom role sections).
/// Idempotent.
enum ExportSettingsMigration {
    static func run(defaults: UserDefaults = .standard) {
        for key in [
            "exportShowShiftName",
            "exportShowTimes",
            "exportShowRole",
            "empExportShowShiftName",
            "empExportShowTimes",
            "empExportShowRole",
            "exportDefaultProfile",
            "empExportDefaultProfile",
            "exportDefaultPdfTemplate",
        ] {
            defaults.removeObject(forKey: key)
        }
    }
}
