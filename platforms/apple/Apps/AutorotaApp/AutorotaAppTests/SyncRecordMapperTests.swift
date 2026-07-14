import AutorotaKit
import CloudKit
import Foundation
import Testing
@testable import AutorotaApp

@Suite("SyncRecordMapper")
struct SyncRecordMapperTests {

    /// Semantic JSON equality via NSDictionary (handles NSNull, numbers, nesting).
    private func jsonDict(_ s: String) -> NSDictionary? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj as NSDictionary
    }

    // MARK: - Whole row rides in a single `payload` field

    @Test("parent record maps to exactly one payload field and round-trips")
    func employeeRoundTrip() {
        let fields = #"{"id":7,"first_name":"Alice","nickname":null,"hourly_wage":12.5,"last_modified":"2026-04-28T10:00:00Z"}"#
        let input = FfiSyncRecord(tableName: "employees", recordId: 7, fields: fields, lastModified: "2026-04-28T10:00:00Z")

        let record = SyncRecordMapper.toCKRecord(input)
        #expect(record != nil)
        guard let record else { return }

        #expect(record.recordType == "Employee")
        #expect(record.recordID.recordName == "employees_7")
        // Exactly one app-set field, and it is the payload blob.
        #expect(record.allKeys() == [SyncRecordMapper.payloadKey])
        #expect(record[SyncRecordMapper.payloadKey] as? String == fields)

        let back = SyncRecordMapper.fromCKRecord(record)
        #expect(back != nil)
        guard let back else { return }
        #expect(back.tableName == "employees")
        #expect(back.recordId == 7)
        #expect(back.lastModified == "2026-04-28T10:00:00Z")
        // JSON preserved verbatim — including the explicit null.
        #expect(jsonDict(back.fields) == jsonDict(fields))
    }

    @Test("child record carrying role_requirements_json round-trips")
    func shiftWithRoleRequirementsRoundTrip() {
        let fields = #"{"id":42,"rota_id":3,"required_role":"barista","role_requirements_json":"[{\"role\":\"barista\",\"min\":2}]","last_modified":"2026-04-28T11:00:00Z"}"#
        let input = FfiSyncRecord(tableName: "shifts", recordId: 42, fields: fields, lastModified: "2026-04-28T11:00:00Z")

        let record = SyncRecordMapper.toCKRecord(input)
        #expect(record?.recordType == "Shift")
        #expect(record?.allKeys() == [SyncRecordMapper.payloadKey])

        let back = record.flatMap(SyncRecordMapper.fromCKRecord)
        #expect(back?.recordId == 42)
        #expect(back?.lastModified == "2026-04-28T11:00:00Z")
        #expect(jsonDict(back?.fields ?? "") == jsonDict(fields))
    }

    @Test("record missing the payload field returns nil")
    func missingPayloadReturnsNil() {
        let recordID = SyncRecordMapper.makeRecordID(tableName: "employees", rowID: 1)
        let record = CKRecord(recordType: "Employee", recordID: recordID)
        #expect(SyncRecordMapper.fromCKRecord(record) == nil)
    }
}
