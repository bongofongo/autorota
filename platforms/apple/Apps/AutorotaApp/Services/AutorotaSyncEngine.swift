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
    /// Last non-fatal sync issue surfaced for the UI banner. Cleared by the
    /// next successful pull. Distinct from `status` (which gates engine state)
    /// so a one-off conflict-merge failure on record N doesn't poison the
    /// whole engine.
    private(set) var lastSyncIssue: String?
    private var engine: CKSyncEngine?
    private var dataChangeObserver: NSObjectProtocol?
    /// In-flight debounce timer for `schedulePush()`. Each new local
    /// mutation cancels the previous timer and starts a fresh window so a
    /// burst of edits coalesces into one push instead of N. The window is
    /// chosen to be longer than typical UI interaction latency
    /// (~250 ms) but shorter than user-perceptible sync delay.
    private var pendingPushTask: Task<Void, Never>?
    static let pushDebounceWindow: Duration = .milliseconds(500)
    private let logger = Logger(subsystem: "com.toadmountain.autorota", category: "sync")

    deinit {
        if let observer = dataChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    enum SyncEngineError: Error, LocalizedError {
        case mergedFieldsNotUTF8

        var errorDescription: String? {
            switch self {
            case .mergedFieldsNotUTF8:
                return "Merged sync record fields are not valid UTF-8."
            }
        }
    }

    /// Encodes a merged sync record as a JSON string. Throws on
    /// `JSONSerialization` failure or non-UTF-8 output. Extracted as a
    /// static so the merge-failure path can be unit-tested without standing
    /// up a full CKSyncEngine.
    static func encodeMergedFields(_ merged: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: merged)
        guard let str = String(data: data, encoding: .utf8) else {
            throw SyncEngineError.mergedFieldsNotUTF8
        }
        return str
    }

    /// Initialize the sync engine. Call after `autorotaInitDb()`.
    /// Idempotent — calling twice is a no-op (previously this added a
    /// duplicate `.autorotaDataChanged` observer per call, causing N pushes
    /// per local mutation after N starts).
    func start() async {
        guard engine == nil else {
            logger.debug("CKSyncEngine.start() called twice; ignoring re-entry")
            return
        }
        do {
            let config = try await loadOrCreateConfiguration()
            let engine = CKSyncEngine(config)
            self.engine = engine
            dataChangeObserver = NotificationCenter.default.addObserver(
                forName: .autorotaDataChanged,
                object: nil,
                queue: .main
            ) { [weak self] note in
                // Drop our own remote-sync echoes — applying a CloudKit fetch
                // also posts `.autorotaDataChanged` so the UI refreshes, and
                // without this guard we'd push that very change back to
                // CloudKit on the next tick. Legacy posts that omit the
                // payload (back-compat) still trigger a push.
                if note.autorotaDataChange?.source == .remoteSync { return }
                self?.schedulePush()
            }
            logger.info("CKSyncEngine started")
        } catch {
            logger.error("Failed to start CKSyncEngine: \(error)")
            status = .error(userFacingMessage(error))
        }
    }

    /// Tear down the engine and remove its observer so the instance can be
    /// re-`start()`ed cleanly (or released).
    func stop() {
        if let observer = dataChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            dataChangeObserver = nil
        }
        pendingPushTask?.cancel()
        pendingPushTask = nil
        engine = nil
        status = .idle
        logger.info("CKSyncEngine stopped")
    }

    /// Notify the engine that local data has changed and needs to be pushed.
    /// Debounced: rapid bursts of mutations (e.g. running a schedule that
    /// touches many assignments, or applying a roster import) collapse
    /// into a single push at the end of the burst.
    func schedulePush() {
        pendingPushTask?.cancel()
        pendingPushTask = Task { [weak self] in
            try? await Task.sleep(for: AutorotaSyncEngine.pushDebounceWindow)
            guard !Task.isCancelled else { return }
            await self?.performScheduledPush()
        }
    }

    /// Internal: actually queue the pending changes with `CKSyncEngine`.
    /// Separated from `schedulePush()` so the debounce wrapper can
    /// collapse bursts of mutations into one push.
    @MainActor
    private func performScheduledPush() {
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

                    let mergedFields = try Self.encodeMergedFields(merged)
                    let mergedRecord = FfiSyncRecord(
                        tableName: syncRecord.tableName,
                        recordId: syncRecord.recordId,
                        fields: mergedFields,
                        lastModified: (merged["last_modified"] as? String) ?? syncRecord.lastModified
                    )
                    try applyRemoteRecord(record: mergedRecord)
                } else {
                    try applyRemoteRecord(record: syncRecord)
                }
            } catch {
                let summary = "Failed to apply remote record \(syncRecord.tableName)_\(syncRecord.recordId): \(error.localizedDescription)"
                logger.error("\(summary)")
                lastSyncIssue = summary
            }
        }

        for deletion in changes.deletions {
            guard let (tableName, rowID) = SyncRecordMapper.parseRecordID(deletion.recordID) else { continue }
            do {
                try applyRemoteDeletion(tableName: tableName, recordId: rowID)
                logger.info("Applied remote deletion: \(deletion.recordID.recordName)")
                NotificationCenter.default.postAutorotaDataChange(
                    source: .remoteSync,
                    tables: AutorotaDataChange.Table.from(tableName: tableName),
                    rowIDs: [rowID]
                )
            } catch {
                let summary = "Failed to apply remote deletion \(deletion.recordID.recordName): \(error.localizedDescription)"
                logger.error("\(summary)")
                lastSyncIssue = summary
            }
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
        if !changes.deletedRecordIDs.isEmpty {
            // Hoist the fetch and index by "table_id" key once — the previous
            // version called getPendingTombstones() per deletion (O(n²) over
            // all pending tombstones) and re-fetched on every iteration.
            let tombstoneIndex: [String: Int64]
            do {
                let tombstones = try getPendingTombstones()
                tombstoneIndex = Dictionary(
                    uniqueKeysWithValues: tombstones.map { ("\($0.tableName)_\($0.recordId)", $0.id) }
                )
            } catch {
                logger.error("Failed to load pending tombstones: \(error)")
                tombstoneIndex = [:]
            }
            for deletedID in changes.deletedRecordIDs {
                guard let (tableName, rowID) = SyncRecordMapper.parseRecordID(deletedID) else { continue }
                if let id = tombstoneIndex["\(tableName)_\(rowID)"] {
                    clearedTombstoneIDs.append(id)
                }
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
