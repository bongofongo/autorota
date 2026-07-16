import AutorotaKit
import CloudKit
import Foundation

/// Pure CKRecord <-> FfiSyncRecord mapping, no shared state — kept nonisolated
/// so it can be called from the Sendable closures CKSyncEngine hands sync
/// callbacks on (record provider, conflict resolution), which don't run on
/// the main actor.
nonisolated enum SyncRecordMapper {
    /// All table names that participate in sync, in dependency order
    /// (parents before children for inserts, reverse for deletes).
    static let allTables = [
        "roles",
        "employees",
        "shift_templates",
        "rotas",
        "shifts",
        "assignments",
        "employee_availability_overrides",
        "shift_template_overrides",
    ]

    /// The CloudKit record zone used for all synced data.
    static let zoneName = "AutorotaZone"
    static let zoneID = CKRecordZone.ID(zoneName: zoneName)

    /// Maps a table name to a CloudKit record type name.
    static func recordType(for tableName: String) -> String {
        switch tableName {
        case "employees": return "Employee"
        case "shift_templates": return "ShiftTemplate"
        case "rotas": return "Rota"
        case "shifts": return "Shift"
        case "assignments": return "Assignment"
        case "roles": return "Role"
        case "employee_availability_overrides": return "EmployeeAvailabilityOverride"
        case "shift_template_overrides": return "ShiftTemplateOverride"
        default: return tableName
        }
    }

    /// Extracts the table name and SQLite row ID from a CKRecord.ID.
    /// Record names follow the pattern "{table_name}_{id}".
    static func parseRecordID(_ recordID: CKRecord.ID) -> (tableName: String, rowID: Int64)? {
        let name = recordID.recordName
        guard let lastUnderscore = name.lastIndex(of: "_") else { return nil }
        let table = String(name[name.startIndex..<lastUnderscore])
        let idStr = String(name[name.index(after: lastUnderscore)...])
        guard let rowID = Int64(idStr) else { return nil }
        return (table, rowID)
    }

    /// Builds a CKRecord.ID for a given table and row.
    static func makeRecordID(tableName: String, rowID: Int64) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(tableName)_\(rowID)", zoneID: zoneID)
    }

    /// The single CloudKit field that carries a row's entire synced JSON.
    ///
    /// Every record type stores its whole row as one opaque JSON string here,
    /// rather than mapping each SQLite column to its own typed CloudKit field.
    /// This keeps the CloudKit schema fixed (one `payload` field per record
    /// type) so adding a synced column never requires a schema change — the
    /// row JSON is produced/consumed field-agnostically by the Rust sync
    /// pipeline (`get_pending_sync_records` / `apply_remote_record`), so the
    /// app-internal representation is unchanged.
    static let payloadKey = "payload"

    /// Converts an FfiSyncRecord to a CKRecord, storing the full row JSON in
    /// the single `payload` field.
    static func toCKRecord(_ syncRecord: FfiSyncRecord) -> CKRecord? {
        let ckRecordType = recordType(for: syncRecord.tableName)
        let recordID = makeRecordID(tableName: syncRecord.tableName, rowID: syncRecord.recordId)
        let record = CKRecord(recordType: ckRecordType, recordID: recordID)
        record[payloadKey] = syncRecord.fields as CKRecordValue
        return record
    }

    /// Converts a CKRecord back to an FfiSyncRecord by reading the `payload`
    /// field verbatim. `last_modified` is pulled out of the JSON for the
    /// conflict-resolution timestamp; the JSON itself is passed through
    /// untouched (nulls included, so "cleared" stays distinct from "absent").
    static func fromCKRecord(_ record: CKRecord) -> FfiSyncRecord? {
        guard let (tableName, rowID) = parseRecordID(record.recordID),
              let fields = record[payloadKey] as? String
        else { return nil }

        var lastModified = ""
        if let data = fields.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let lm = json["last_modified"] as? String {
            lastModified = lm
        }

        return FfiSyncRecord(
            tableName: tableName,
            recordId: rowID,
            fields: fields,
            lastModified: lastModified
        )
    }
}
