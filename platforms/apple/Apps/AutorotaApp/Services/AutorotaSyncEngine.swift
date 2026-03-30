import AutorotaKit
import CloudKit
import Foundation
import os

@Observable
final class AutorotaSyncEngine: @unchecked Sendable {
    enum SyncStatus: Sendable {
        case idle
        case syncing
        case error(String)
    }

    private(set) var status: SyncStatus = .idle
    private var engine: CKSyncEngine?
    private let logger = Logger(subsystem: "com.toadmountain.autorota", category: "sync")

    /// Initialize the sync engine. Call after `autorotaInitDb()`.
    func start() async {
        do {
            let config = try await loadOrCreateConfiguration()
            let engine = CKSyncEngine(config)
            self.engine = engine
            NotificationCenter.default.addObserver(
                forName: .autorotaDataChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.schedulePush()
            }
            logger.info("CKSyncEngine started")
        } catch {
            logger.error("Failed to start CKSyncEngine: \(error)")
            status = .error(error.localizedDescription)
        }
    }

    /// Notify the engine that local data has changed and needs to be pushed.
    func schedulePush() {
        guard let engine else { return }
        engine.state.add(pendingDatabaseChanges: [
            .saveZone(CKRecordZone(zoneID: SyncRecordMapper.zoneID))
        ])
        scheduleRecordChanges()
    }

    /// Queues all pending local records for push.
    private func scheduleRecordChanges() {
        guard let engine else { return }
        do {
            var pendingIDs: [CKRecord.ID] = []
            for table in SyncRecordMapper.allTables {
                let records = try getPendingSyncRecords(tableName: table)
                for record in records {
                    pendingIDs.append(SyncRecordMapper.makeRecordID(tableName: table, rowID: record.recordId))
                }
            }
            let tombstones = try getPendingTombstones()
            var deletionIDs: [CKRecord.ID] = []
            for t in tombstones {
                deletionIDs.append(SyncRecordMapper.makeRecordID(tableName: t.tableName, rowID: t.recordId))
            }
            if !pendingIDs.isEmpty {
                engine.state.add(pendingRecordZoneChanges: pendingIDs.map { .saveRecord($0) })
            }
            if !deletionIDs.isEmpty {
                engine.state.add(pendingRecordZoneChanges: deletionIDs.map { .deleteRecord($0) })
            }
        } catch {
            logger.error("Failed to schedule record changes: \(error)")
        }
    }

    // MARK: - Configuration Persistence

    private func loadOrCreateConfiguration() async throws -> CKSyncEngine.Configuration {
        var savedState: CKSyncEngine.State.Serialization?

        if let stateData = try getSyncMetadata(key: "ck_engine_state"),
           let data = stateData.data(using: .utf8) {
            savedState = try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }

        let database = CKContainer(identifier: "iCloud.com.toadmountain.autorota").privateCloudDatabase
        let config = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: savedState,
            delegate: self
        )
        return config
    }

    private func saveEngineState(_ state: CKSyncEngine.State.Serialization) {
        do {
            let data = try JSONEncoder().encode(state)
            if let str = String(data: data, encoding: .utf8) {
                try setSyncMetadata(key: "ck_engine_state", value: str)
            }
        } catch {
            logger.error("Failed to save engine state: \(error)")
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension AutorotaSyncEngine: CKSyncEngineDelegate {

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let stateUpdate):
            saveEngineState(stateUpdate.stateSerialization)

        case .accountChange(let accountChange):
            handleAccountChange(accountChange)

        case .fetchedDatabaseChanges(let fetchedChanges):
            for deletion in fetchedChanges.deletions {
                if deletion.zoneID == SyncRecordMapper.zoneID {
                    logger.warning("AutorotaZone was deleted from iCloud")
                }
            }

        case .fetchedRecordZoneChanges(let fetchedChanges):
            handleFetchedRecordZoneChanges(fetchedChanges)

        case .sentRecordZoneChanges(let sentChanges):
            handleSentRecordZoneChanges(sentChanges)

        case .sentDatabaseChanges:
            break

        case .willFetchChanges:
            status = .syncing

        case .willFetchRecordZoneChanges:
            break

        case .didFetchRecordZoneChanges:
            break

        case .didFetchChanges:
            status = .idle

        case .willSendChanges:
            status = .syncing

        case .didSendChanges:
            status = .idle

        @unknown default:
            logger.info("Unknown CKSyncEngine event: \(String(describing: event))")
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let allPendingChanges = syncEngine.state.pendingRecordZoneChanges
        let filteredChanges = allPendingChanges.filter { scope.contains($0) }
        guard !filteredChanges.isEmpty else { return nil }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: filteredChanges) { recordID in
            guard let (tableName, _) = SyncRecordMapper.parseRecordID(recordID) else { return nil }
            do {
                let records = try getPendingSyncRecords(tableName: tableName)
                guard let record = records.first(where: {
                    SyncRecordMapper.makeRecordID(tableName: tableName, rowID: $0.recordId) == recordID
                }) else { return nil }
                return SyncRecordMapper.toCKRecord(record)
            } catch {
                self.logger.error("Failed to build CKRecord for \(recordID): \(error)")
                return nil
            }
        }
    }

    // MARK: - Handling Fetched Changes (Pull)

    private func handleFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        for modification in changes.modifications {
            let record = modification.record
            guard let syncRecord = SyncRecordMapper.fromCKRecord(record) else {
                logger.warning("Could not parse CKRecord: \(record.recordID)")
                continue
            }

            do {
                let snapshots = try getBaseSnapshots(tableName: syncRecord.tableName, recordIds: [syncRecord.recordId])
                let localRecords = try getPendingSyncRecords(tableName: syncRecord.tableName)
                let localRecord = localRecords.first(where: { $0.recordId == syncRecord.recordId })

                if let localRecord, localRecord.recordId == syncRecord.recordId {
                    let base = snapshots.first.flatMap { parseJSON($0.snapshot) }
                    let local = parseJSON(localRecord.fields) ?? [:]
                    let server = parseJSON(syncRecord.fields) ?? [:]

                    let merged = SyncConflictResolver.merge(
                        base: base,
                        local: local,
                        server: server,
                        localLastModified: localRecord.lastModified,
                        serverLastModified: syncRecord.lastModified
                    )

                    if let mergedData = try? JSONSerialization.data(withJSONObject: merged),
                       let mergedFields = String(data: mergedData, encoding: .utf8) {
                        let mergedRecord = FfiSyncRecord(
                            tableName: syncRecord.tableName,
                            recordId: syncRecord.recordId,
                            fields: mergedFields,
                            lastModified: (merged["last_modified"] as? String) ?? syncRecord.lastModified
                        )
                        try applyRemoteRecord(record: mergedRecord)
                    }
                } else {
                    try applyRemoteRecord(record: syncRecord)
                }
            } catch {
                logger.error("Failed to apply remote record \(syncRecord.tableName)_\(syncRecord.recordId): \(error)")
            }
        }

        for deletion in changes.deletions {
            guard let (tableName, _) = SyncRecordMapper.parseRecordID(deletion.recordID) else { continue }
            logger.info("Remote deletion: \(deletion.recordID.recordName) from \(tableName)")
        }
    }

    // MARK: - Handling Sent Changes (Push confirmation)

    private func handleSentRecordZoneChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) {
        var successesByTable: [String: [(Int64, String)]] = [:]

        for success in changes.savedRecords {
            guard let syncRecord = SyncRecordMapper.fromCKRecord(success) else { continue }
            successesByTable[syncRecord.tableName, default: []].append((syncRecord.recordId, syncRecord.fields))
        }

        for (tableName, records) in successesByTable {
            let ids = records.map { $0.0 }
            let snapshots = records.map { $0.1 }
            do {
                try markRecordsSynced(tableName: tableName, recordIds: ids, baseSnapshots: snapshots)
            } catch {
                logger.error("Failed to mark records synced for \(tableName): \(error)")
            }
        }

        var clearedTombstoneIDs: [Int64] = []
        for deletedID in changes.deletedRecordIDs {
            guard let (tableName, rowID) = SyncRecordMapper.parseRecordID(deletedID) else { continue }
            do {
                let tombstones = try getPendingTombstones()
                if let tombstone = tombstones.first(where: { $0.tableName == tableName && $0.recordId == rowID }) {
                    clearedTombstoneIDs.append(tombstone.id)
                }
            } catch {
                logger.error("Failed to find tombstone for \(deletedID): \(error)")
            }
        }
        if !clearedTombstoneIDs.isEmpty {
            do {
                try clearTombstones(ids: clearedTombstoneIDs)
            } catch {
                logger.error("Failed to clear tombstones: \(error)")
            }
        }

        for failure in changes.failedRecordSaves {
            logger.warning("Failed to save record \(failure.record.recordID): \(failure.error)")
        }
    }

    // MARK: - Account Changes

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn:
            logger.info("iCloud account signed in — scheduling full push")
            schedulePush()
        case .signOut:
            logger.info("iCloud account signed out — sync paused")
            status = .idle
        case .switchAccounts:
            logger.warning("iCloud account switched — data may be stale")
            status = .error("iCloud account changed. Please restart the app.")
        @unknown default:
            break
        }
    }

    // MARK: - Helpers

    private func parseJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }
}
