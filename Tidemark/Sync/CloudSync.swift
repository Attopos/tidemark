import Foundation
import SwiftData
import CloudKit
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - iCloud sync
//
// Ledger records and cash accounts are kept in step between devices through
// the user's private iCloud database (CKSyncEngine, one record zone).
//
// How it stays fast and honest:
//  * Every save of the store is followed by a scan that compares each row's
//    digest with what the server is known to hold (see SyncPlanner); what
//    differs is sent at once rather than on the engine's own schedule.
//  * The other device hears about it through a silent push and fetches. A
//    slow timer and every return to the foreground fetch as well, so a lost
//    push costs seconds, not correctness.
//  * Two edits of the same row: the later `updatedAt` wins.
//  * Nothing is ever deleted here because the store looks empty: a sweep that
//    would remove most known records is refused (a failed store open must
//    not wipe the server).

@MainActor
@Observable
final class CloudSync: CKSyncEngineDelegate {
    static let containerID = "iCloud.com.shizhengcao.Tidemark"
    private static let zoneID = CKRecordZone.ID(zoneName: "Ledger", ownerName: CKCurrentUserDefaultName)

    enum Phase: Equatable {
        case off(String)
        case idle
        case syncing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Last time anything was sent or received.
    private(set) var lastActivity: Date?
    private(set) var sentCount = 0
    private(set) var receivedCount = 0

    /// Whether this build may talk to iCloud at all. An unsigned or ad-hoc
    /// build has no iCloud entitlement, and touching CloudKit would crash it.
    static var isEntitled: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        return (value as? [String])?.contains("CloudKit") ?? false
        #else
        return true
        #endif
    }

    private struct StateFile: Codable {
        var engine: CKSyncEngine.State.Serialization?
        var records: [String: SyncEntry] = [:]
        /// Records that name an account which has not arrived yet.
        var orphans: [String: SyncFields] = [:]
        /// Account ids that lost an identity merge → the id that survived.
        var aliases: [String: String] = [:]
    }

    private let context: ModelContext
    private var engine: CKSyncEngine?
    private var state = StateFile()
    /// Digests handed to the engine and not yet confirmed by the server.
    private var queued: [String: String] = [:]
    private var scanTask: Task<Void, Never>?
    private var sending = false
    private var sendAgain = false
    private var observers: [NSObjectProtocol] = []
    private var pollTask: Task<Void, Never>?

    private static var folder: URL {
        let base = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private static var stateURL: URL { folder.appending(path: "sync-state.json") }
    static var logURL: URL { folder.appending(path: "sync.log") }

    init(container: ModelContainer) {
        self.context = container.mainContext
    }

    // MARK: Lifecycle

    func start() {
        guard engine == nil else { return }
        // The unit-test host is the real app on the real store; it must not sync.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            phase = .off("Running under tests.")
            return
        }
        guard Self.isEntitled else {
            phase = .off("This build is not signed for iCloud.")
            return
        }
        if let data = try? Data(contentsOf: Self.stateURL),
           let saved = try? JSONDecoder().decode(StateFile.self, from: data) {
            state = saved
        }
        let database = CKContainer(identifier: Self.containerID).privateCloudDatabase
        let configuration = CKSyncEngine.Configuration(database: database, stateSerialization: state.engine,
                                                       delegate: self)
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        if state.records.isEmpty {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        }
        log("start: \(state.records.count) records known to the server")

        observers.append(NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleScan() }
            })
        #if canImport(UIKit)
        UIApplication.shared.registerForRemoteNotifications()
        let active = UIApplication.didBecomeActiveNotification
        #else
        NSApplication.shared.registerForRemoteNotifications()
        let active = NSApplication.didBecomeActiveNotification
        #endif
        observers.append(NotificationCenter.default.addObserver(forName: active, object: nil, queue: .main) {
            [weak self] _ in Task { @MainActor in self?.fetchNow() }
        })
        // Safety net for a push that never arrives.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.fetchNow()
            }
        }
        // The engine fetches by itself as soon as it knows the iCloud account.
        scheduleScan()
        runProbeIfAsked()
    }

    func fetchNow() {
        guard let engine else { return }
        Task {
            do { try await engine.fetchChanges() } catch { self.note(error, doing: "fetch") }
        }
    }

    private func sendNow() {
        guard let engine else { return }
        if sending { sendAgain = true; return }
        sending = true
        Task {
            repeat {
                sendAgain = false
                do { try await engine.sendChanges() } catch { self.note(error, doing: "send") }
            } while sendAgain
            sending = false
        }
    }

    // MARK: Local changes → server

    private func scheduleScan() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            // Coalesce a burst of saves (an import) into one scan.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.scan()
        }
    }

    private struct Index {
        var accounts: [UUID: Account] = [:]
        var transactions: [UUID: Transaction] = [:]
    }

    private func loadIndex() -> Index {
        var index = Index()
        for account in (try? context.fetch(FetchDescriptor<Account>())) ?? [] where account.isLedgerAccount {
            index.accounts[account.id] = account
        }
        for transaction in (try? context.fetch(FetchDescriptor<Transaction>())) ?? [] {
            index.transactions[transaction.id] = transaction
        }
        return index
    }

    private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: Self.zoneID) }

    private func scan() {
        guard let engine else { return }
        let index = loadIndex()
        var local: [String: String] = [:]
        for (id, account) in index.accounts {
            local[SyncKey(.account, id).name] = SyncCodec.digest(SyncCodec.fields(of: account))
        }
        for (id, transaction) in index.transactions {
            local[SyncKey(.transaction, id).name] = SyncCodec.digest(SyncCodec.fields(of: transaction))
        }
        let plan = SyncPlanner.plan(local: local, synced: state.records, queued: queued)
        if plan.refusedDeletes {
            log("refused to delete most of the server's records; the local store looks incomplete")
        }
        guard !plan.saves.isEmpty || !plan.deletes.isEmpty else { return }

        // A row that changed without anyone stamping it gets stamped now, so
        // "later edit wins" has something to compare.
        var stamped = false
        let now = Date()
        for name in plan.saves {
            guard let key = SyncKey(name: name) else { continue }
            queued[name] = local[name]
            switch key.kind {
            case .account:
                if let account = index.accounts[key.id], now.timeIntervalSince(account.updatedAt) > 2 {
                    account.updatedAt = now
                    stamped = true
                }
            case .transaction:
                if let transaction = index.transactions[key.id], now.timeIntervalSince(transaction.updatedAt) > 2 {
                    transaction.updatedAt = now
                    stamped = true
                }
            }
        }
        if stamped { try? context.save() }

        engine.state.add(pendingRecordZoneChanges:
            plan.saves.map { .saveRecord(recordID($0)) } + plan.deletes.map { .deleteRecord(recordID($0)) })
        log("queued \(plan.saves.count) saves, \(plan.deletes.count) deletes")
        sendNow()
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        let index = loadIndex()
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await MainActor.run { self.record(for: recordID, index: index, engine: syncEngine) }
        }
    }

    private func record(for recordID: CKRecord.ID, index: Index, engine: CKSyncEngine) -> CKRecord? {
        let name = recordID.recordName
        var fields: SyncFields?
        if let key = SyncKey(name: name) {
            switch key.kind {
            case .account: fields = index.accounts[key.id].map(SyncCodec.fields(of:))
            case .transaction: fields = index.transactions[key.id].map(SyncCodec.fields(of:))
            }
        }
        guard let key = SyncKey(name: name), let fields else {
            // Deleted since it was queued.
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
        let record = state.records[name]?.system.flatMap(Self.record(fromSystemFields:))
            ?? CKRecord(recordType: key.kind.recordType, recordID: recordID)
        for (field, value) in fields { record[field] = value }
        for field in record.allKeys() where fields[field] == nil { record[field] = nil }
        return record
    }

    // MARK: Engine events

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            state.engine = update.stateSerialization
            persist()
        case .accountChange(let change):
            handleAccountChange(change, engine: syncEngine)
        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                // The zone was removed elsewhere: forget what the server had and send everything again.
                log("zone deleted on the server; uploading again")
                resetServerKnowledge(engine: syncEngine)
            }
        case .fetchedRecordZoneChanges(let changes):
            applyFetched(modifications: changes.modifications.map(\.record),
                         deletions: changes.deletions.map(\.recordID.recordName), engine: syncEngine)
        case .sentRecordZoneChanges(let sent):
            handleSent(sent, engine: syncEngine)
        case .willFetchChanges, .willSendChanges:
            phase = .syncing
        case .didFetchChanges, .didSendChanges:
            if case .off = phase { break }
            phase = .idle
        case .sentDatabaseChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break
        @unknown default:
            break
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange, engine: CKSyncEngine) {
        switch change.changeType {
        case .signIn:
            log("iCloud account signed in")
            resetServerKnowledge(engine: engine)
        case .signOut:
            log("iCloud account signed out")
            state = StateFile()
            queued = [:]
            persist()
            phase = .off("Not signed in to iCloud.")
        case .switchAccounts:
            log("iCloud account switched")
            resetServerKnowledge(engine: engine)
        @unknown default:
            break
        }
    }

    /// Local data stays; everything is treated as never sent.
    private func resetServerKnowledge(engine: CKSyncEngine) {
        state.records = [:]
        state.orphans = [:]
        queued = [:]
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        persist()
        scheduleScan()
    }

    // MARK: Server → local

    private func applyFetched(modifications: [CKRecord], deletions: [String], engine: CKSyncEngine) {
        guard !modifications.isEmpty || !deletions.isEmpty else { return }
        var index = loadIndex()
        var byFingerprint: [String: Transaction] = [:]
        for transaction in index.transactions.values { byFingerprint[transaction.fingerprint] = transaction }
        var retired: [String] = []
        let now = Date()

        func accountsForLinks() -> [UUID: Account] {
            var accounts = index.accounts
            for (loser, survivor) in state.aliases {
                if let loserID = UUID(uuidString: loser), let survivorID = UUID(uuidString: survivor),
                   let account = index.accounts[survivorID] {
                    accounts[loserID] = account
                }
            }
            return accounts
        }

        // Accounts first: records point at them.
        for record in modifications {
            guard let key = SyncKey(name: record.recordID.recordName), key.kind == .account else { continue }
            let fields = Self.fields(from: record)
            let account: Account
            if let existing = index.accounts[key.id] {
                account = existing
            } else if let twin = index.accounts.values.first(where: { $0.name == fields["name"] }) {
                // The same account created separately on two devices.
                if SyncPlanner.survivor(twin.id, key.id) == key.id {
                    let old = SyncKey(.account, twin.id).name
                    state.aliases[twin.id.uuidString] = key.id.uuidString
                    index.accounts[twin.id] = nil
                    twin.id = key.id
                    index.accounts[key.id] = twin
                    state.records[old] = nil
                    retired.append(old)
                    account = twin
                } else {
                    state.aliases[key.id.uuidString] = twin.id.uuidString
                    retired.append(key.name)
                    continue
                }
            } else {
                account = Account(name: fields["name"] ?? "", kind: .payment)
                account.id = key.id
                context.insert(account)
                index.accounts[key.id] = account
            }
            SyncCodec.apply(fields, to: account)
            state.records[key.name] = SyncEntry(digest: SyncCodec.digest(SyncCodec.fields(of: account)),
                                                system: Self.systemFields(of: record))
            queued[key.name] = nil
        }

        func applyRecord(_ key: SyncKey, _ fields: SyncFields, system: Data?) {
            let transaction: Transaction
            if let existing = index.transactions[key.id] {
                transaction = existing
            } else if let print = fields["fingerprint"], let twin = byFingerprint[print] {
                // The same export imported separately on two devices.
                if SyncPlanner.survivor(twin.id, key.id) == key.id {
                    let old = SyncKey(.transaction, twin.id).name
                    index.transactions[twin.id] = nil
                    twin.id = key.id
                    index.transactions[key.id] = twin
                    state.records[old] = nil
                    retired.append(old)
                    transaction = twin
                } else {
                    retired.append(key.name)
                    return
                }
            } else {
                transaction = Transaction(date: now, kind: .expense, amount: 0,
                                          fingerprint: fields["fingerprint"])
                transaction.id = key.id
                context.insert(transaction)
                index.transactions[key.id] = transaction
                byFingerprint[transaction.fingerprint] = transaction
            }
            let complete = SyncCodec.apply(fields, to: transaction, accounts: accountsForLinks())
            state.orphans[key.name] = complete ? nil : fields
            let entrySystem = system ?? state.records[key.name]?.system
            state.records[key.name] = SyncEntry(digest: SyncCodec.digest(SyncCodec.fields(of: transaction)),
                                                system: entrySystem)
            queued[key.name] = nil
        }

        var lags: [String] = []
        for record in modifications {
            guard let key = SyncKey(name: record.recordID.recordName), key.kind == .transaction else { continue }
            let fields = Self.fields(from: record)
            applyRecord(key, fields, system: Self.systemFields(of: record))
            if modifications.count <= 5, let updated = SyncCodec.date(fields["updatedAt"]) {
                lags.append(String(format: "%@ %.0f ms after its edit", key.name, now.timeIntervalSince(updated) * 1000))
            }
        }
        // Records that were waiting for an account that has now arrived.
        for (name, fields) in state.orphans {
            if let key = SyncKey(name: name) { applyRecord(key, fields, system: nil) }
        }

        for name in deletions {
            guard let key = SyncKey(name: name) else { continue }
            switch key.kind {
            case .account: if let account = index.accounts[key.id] { context.delete(account) }
            case .transaction: if let transaction = index.transactions[key.id] { context.delete(transaction) }
            }
            state.records[name] = nil
            state.orphans[name] = nil
            queued[name] = nil
        }

        do { try context.save() } catch { note(error, doing: "save fetched changes") }
        if !retired.isEmpty {
            engine.state.add(pendingRecordZoneChanges: retired.map { .deleteRecord(recordID($0)) })
            sendNow()
        }
        receivedCount += modifications.count + deletions.count
        lastActivity = now
        persist()
        log("received \(modifications.count) changes, \(deletions.count) deletions"
            + (lags.isEmpty ? "" : " [" + lags.joined(separator: "; ") + "]"))
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) {
        for record in sent.savedRecords {
            let name = record.recordID.recordName
            state.records[name] = SyncEntry(digest: SyncCodec.digest(Self.fields(from: record)),
                                            system: Self.systemFields(of: record))
            queued[name] = nil
        }
        for recordID in sent.deletedRecordIDs {
            state.records[recordID.recordName] = nil
        }
        var conflicts: [CKRecord] = []
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        for failure in sent.failedRecordSaves {
            let name = failure.record.recordID.recordName
            queued[name] = nil
            switch failure.error.code {
            case .serverRecordChanged:
                guard let server = failure.error.serverRecord else { continue }
                let mine = SyncCodec.date(Self.fields(from: failure.record)["updatedAt"]) ?? .distantPast
                let theirs = SyncCodec.date(Self.fields(from: server)["updatedAt"]) ?? .distantPast
                if mine > theirs {
                    // Ours is the later edit: send it again on top of the server's version.
                    state.records[name] = SyncEntry(digest: SyncCodec.digest(Self.fields(from: server)),
                                                    system: Self.systemFields(of: server))
                    retry.append(.saveRecord(failure.record.recordID))
                } else {
                    conflicts.append(server)
                }
            case .zoneNotFound, .userDeletedZone:
                engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                retry.append(.saveRecord(failure.record.recordID))
            case .unknownItem:
                state.records[name] = nil
                retry.append(.saveRecord(failure.record.recordID))
            default:
                log("could not save \(name): \(failure.error.localizedDescription)")
            }
        }
        if !conflicts.isEmpty { applyFetched(modifications: conflicts, deletions: [], engine: engine) }
        if !retry.isEmpty {
            engine.state.add(pendingRecordZoneChanges: retry)
            sendNow()
        }
        let count = sent.savedRecords.count + sent.deletedRecordIDs.count
        if count > 0 {
            sentCount += count
            lastActivity = Date()
            log("sent \(sent.savedRecords.count) saves, \(sent.deletedRecordIDs.count) deletes"
                + (sent.failedRecordSaves.isEmpty ? "" : ", \(sent.failedRecordSaves.count) failed"))
        }
        persist()
    }

    // MARK: Record plumbing

    private static func fields(from record: CKRecord) -> SyncFields {
        var fields: SyncFields = [:]
        for key in record.allKeys() {
            if let value = record[key] as? String { fields[key] = value }
        }
        return fields
    }

    private static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        return CKRecord(coder: coder)
    }

    // MARK: State, log, errors

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
    }

    private func note(_ error: Error, doing what: String) {
        let message = "\(what) failed: \(error.localizedDescription)"
        log("\(message) — \(String(describing: error).prefix(600))")
        if let cloud = error as? CKError, cloud.code == .notAuthenticated {
            phase = .off("Not signed in to iCloud.")
        } else {
            phase = .failed(message)
        }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Timestamped line to the console and to sync.log (kept under 512 KB).
    private func log(_ message: String) {
        let line = "\(Self.stamp.string(from: Date())) \(message)\n"
        print("[sync] \(line)", terminator: "")
        let url = Self.logURL
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 512_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    // MARK: Connectivity probe
    //
    // Launching with TIDEMARK_SYNC_PROBE=add writes one marked record so the
    // round trip to another device can be timed from the two logs;
    // TIDEMARK_SYNC_PROBE=clear removes every marked record again.

    static let probeCategory = "sync-probe"

    private func runProbeIfAsked() {
        guard let mode = ProcessInfo.processInfo.environment["TIDEMARK_SYNC_PROBE"] else { return }
        if mode == "clear" {
            let probes = ((try? context.fetch(FetchDescriptor<Transaction>())) ?? [])
                .filter { $0.category == Self.probeCategory }
            probes.forEach(context.delete)
            try? context.save()
            log("probe: removed \(probes.count) probe records")
        } else {
            let probe = Transaction(date: Date(), kind: .expense, amount: Decimal(string: "0.01")!,
                                    category: Self.probeCategory, note: "probe \(mode)", excludeFromStats: true)
            probe.updatedAt = Date()
            context.insert(probe)
            try? context.save()
            log("probe: added T:\(probe.id.uuidString)")
        }
    }
}
