import Foundation
import AutorotaKit

/// Single source of truth for building a full-rota `FfiExportConfig` from the
/// Export-tab settings. Consumed by the share sheet and the settings preview
/// so they can never drift apart.
///
/// There is no profile or PDF-template setting anymore: presets are always
/// the staff schedule on the weekly grid, and a custom layout opts into the
/// manager report by placing the Cost pill in its cells.
enum FullExportConfigBuilder {

    /// `"employee_by_weekday"` and `"shift_by_weekday"` are fixed presets;
    /// `"custom"` reads the sandbox layout from `defaults`.
    static let customLayoutPref = "custom"

    static func make(
        layoutPref: String,
        format: String,
        defaults: UserDefaults = .standard
    ) -> FfiExportConfig {
        if layoutPref == customLayoutPref {
            if let layout = ExportCustomLayout.load(from: defaults),
               let config = try? ExportCustomLayoutMapper.ffiConfig(layout, format: format) {
                return config
            }
            // Missing or invalid sandbox config: never fail the share path —
            // fall back to the By Employee preset.
            return preset(layout: "employee_by_weekday", format: format)
        }
        return preset(layout: layoutPref, format: format)
    }

    private static func preset(layout: String, format: String) -> FfiExportConfig {
        let byShift = layout == "shift_by_weekday"
        return FfiExportConfig(
            layout: layout,
            format: format,
            profile: "staff_schedule",
            showShiftName: !byShift,
            showTimes: true,
            showRole: byShift,
            pdfTemplate: nil,
            roleSections: nil,
            rowContent: nil
        )
    }
}
