import Foundation

enum SyncConflictResolver {
    /// Field-presence sentinel: an `NSNull` value (or the literal token below)
    /// in `server[key]` means "the server explicitly cleared this field."
    /// A key being *absent* from the server dict means "the server has no
    /// opinion on this field" and the local value must be preserved. This
    /// distinction did not previously exist; without it, a server payload
    /// that omits a key was indistinguishable from one that intentionally
    /// nilled it, and the resolver would clear the local field either way.
    static let deletionSentinel = "__deleted"

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
            let localPresent = local.keys.contains(key)
            let serverPresent = server.keys.contains(key)
            let serverVal = server[key]

            // "No opinion" on either side: skip — the other side's value
            // (already in `result` for local, or absence for server) wins by
            // default.
            if !serverPresent {
                continue
            }

            let localChanged = localPresent && !valuesEqual(baseVal, localVal)
            let serverChanged = !valuesEqual(baseVal, serverVal)

            if !localChanged && serverChanged {
                // Only server changed this field — take server's value (which
                // may be NSNull / deletion sentinel for an intentional clear).
                result[key] = unwrapDeletion(serverVal)
            } else if localChanged && !serverChanged {
                // Only local changed — keep local (already in result)
                continue
            } else if localChanged && serverChanged {
                // Both changed — later timestamp wins, server as tiebreaker
                if serverLastModified >= localLastModified {
                    result[key] = unwrapDeletion(serverVal)
                }
                // else keep local (already in result)
            }
            // Neither changed — keep base/local (already in result)
        }

        // Use the later timestamp
        result["last_modified"] = max(localLastModified, serverLastModified)

        return result
    }

    /// `["__deleted": true]` (or a bare `NSNull`) is the explicit clear marker
    /// — surface as `NSNull` so JSONSerialization round-trips it.
    private static func unwrapDeletion(_ value: Any?) -> Any {
        if let dict = value as? [String: Any], dict[deletionSentinel] as? Bool == true {
            return NSNull()
        }
        return value ?? NSNull()
    }

    /// Type-aware equality. Mismatched types compare unequal — previous
    /// implementation stringified, which collapsed `1` and `"1"` (or worse,
    /// `true` and `1`) to the same key.
    ///
    /// Note: Swift `Bool` and `NSNumber` both land in the `NSNumber` pattern
    /// because `Bool` bridges via `__SwiftValue`. The discriminator below
    /// uses `CFGetTypeID(... ) == CFBooleanGetTypeID()` to tell them apart;
    /// dropping that check lets `true` compare equal to `NSNumber(1)`.
    static func valuesEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (is NSNull, nil), (nil, is NSNull), (is NSNull, is NSNull): return true
        case (nil, _), (_, nil): return false
        case (let a as String, let b as String): return a == b
        case (let a as NSNumber, let b as NSNumber):
            let aIsBool = CFGetTypeID(a) == CFBooleanGetTypeID()
            let bIsBool = CFGetTypeID(b) == CFBooleanGetTypeID()
            if aIsBool != bIsBool { return false }
            return a.isEqual(to: b)
        case (let a as [Any], let b as [Any]):
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { valuesEqual($0, $1) }
        case (let a as [String: Any], let b as [String: Any]):
            guard a.keys == b.keys else { return false }
            return a.keys.allSatisfy { valuesEqual(a[$0], b[$0]) }
        default:
            // Mismatched types — never silently coerce.
            return false
        }
    }
}
