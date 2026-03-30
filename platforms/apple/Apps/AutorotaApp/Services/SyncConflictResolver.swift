import CloudKit
import Foundation

enum SyncConflictResolver {
    /// Performs a three-way merge between base, local, and server versions of a record.
    ///
    /// - Parameters:
    ///   - base: The field values at last successful sync (from sync_base_snapshot). Nil if no base exists (first sync).
    ///   - local: The current local field values (from SQLite).
    ///   - server: The field values from the CloudKit server record.
    ///   - localLastModified: The local row's last_modified timestamp.
    ///   - serverLastModified: The server record's last_modified timestamp.
    /// - Returns: The merged field values as a JSON dictionary.
    static func merge(
        base: [String: Any]?,
        local: [String: Any],
        server: [String: Any],
        localLastModified: String,
        serverLastModified: String
    ) -> [String: Any] {
        // If no base snapshot exists, fall back to timestamp-based last-write-wins at row level.
        guard let base else {
            return serverLastModified >= localLastModified ? server : local
        }

        var result = local // Start with local, apply server changes

        for key in Set(local.keys).union(server.keys) {
            if key == "id" || key == "last_modified" { continue }

            let baseVal = base[key]
            let localVal = local[key]
            let serverVal = server[key]

            let localChanged = !valuesEqual(baseVal, localVal)
            let serverChanged = !valuesEqual(baseVal, serverVal)

            if !localChanged && serverChanged {
                // Only server changed this field — take server's value
                result[key] = serverVal
            } else if localChanged && !serverChanged {
                // Only local changed — keep local (already in result)
                continue
            } else if localChanged && serverChanged {
                // Both changed — later timestamp wins, server as tiebreaker
                if serverLastModified >= localLastModified {
                    result[key] = serverVal
                }
                // else keep local (already in result)
            }
            // Neither changed — keep base/local (already in result)
        }

        // Use the later timestamp
        result["last_modified"] = max(localLastModified, serverLastModified)

        return result
    }

    /// Compares two JSON values for equality, handling nil/NSNull.
    private static func valuesEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (is NSNull, nil), (nil, is NSNull), (is NSNull, is NSNull): return true
        case (nil, _), (_, nil): return false
        case (let a as String, let b as String): return a == b
        case (let a as NSNumber, let b as NSNumber): return a == b
        case (let a as Bool, let b as Bool): return a == b
        default: return "\(a!)" == "\(b!)"
        }
    }
}
