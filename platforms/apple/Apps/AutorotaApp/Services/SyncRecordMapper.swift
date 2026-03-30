import AutorotaKit
import CloudKit
import Foundation

enum SyncRecordMapper {
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

    /// Converts an FfiSyncRecord to a CKRecord, setting all fields from the JSON.
    static func toCKRecord(_ syncRecord: FfiSyncRecord) -> CKRecord? {
        let ckRecordType = recordType(for: syncRecord.tableName)
        let recordID = makeRecordID(tableName: syncRecord.tableName, rowID: syncRecord.recordId)
        let record = CKRecord(recordType: ckRecordType, recordID: recordID)

        guard let data = syncRecord.fields.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        for (key, value) in json {
            if key == "id" { continue } // ID is in the record name, not a field
            switch value {
            case let s as String: record[key] = s as CKRecordValue
            case let n as NSNumber: record[key] = n as CKRecordValue
            case is NSNull: record[key] = nil
            default: record[key] = "\(value)" as CKRecordValue
            }
        }

        return record
    }

    /// Converts a CKRecord back to an FfiSyncRecord.
    static func fromCKRecord(_ record: CKRecord) -> FfiSyncRecord? {
        guard let (tableName, rowID) = parseRecordID(record.recordID) else { return nil }

        var json: [String: Any] = ["id": rowID]
        for key in record.allKeys() {
            if let value = record[key] {
                json[key] = value
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let fields = String(data: data, encoding: .utf8)
        else { return nil }

        let lastModified = (json["last_modified"] as? String) ?? ""

        return FfiSyncRecord(
            tableName: tableName,
            recordId: rowID,
            fields: fields,
            lastModified: lastModified
        )
    }
}
