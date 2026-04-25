import SwiftUI

/// User-tunable knobs for the per-employee message body that Bulk Send
/// generates. Persisted via `@AppStorage` so settings stick across launches.
struct BulkSendSettings {

    static let weekHeaderKey   = "bulkSend.template.weekHeader"
    static let shiftLineKey    = "bulkSend.template.shiftLine"
    static let customPrefixKey = "bulkSend.template.customPrefix"
    static let customSuffixKey = "bulkSend.template.customSuffix"

    var weekHeader: Bool
    var shiftLine: Bool
    var customPrefix: String
    var customSuffix: String

    static var current: BulkSendSettings {
        let d = UserDefaults.standard
        return BulkSendSettings(
            weekHeader: d.object(forKey: weekHeaderKey) as? Bool ?? true,
            shiftLine: d.object(forKey: shiftLineKey) as? Bool ?? true,
            customPrefix: d.string(forKey: customPrefixKey) ?? "",
            customSuffix: d.string(forKey: customSuffixKey) ?? ""
        )
    }
}
