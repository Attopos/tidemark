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
// Ledger records, cash accounts and record presets are kept in step between devices through
// the user's private iCloud database, in one record zone.
//
// One sync cycle is: make sure the zone exists, send what changed here, fetch
// what changed elsewhere (by change token, so only the difference travels).
//
// How it stays fast and honest:
//  * Every save of the store is followed by a scan that compares each row's
//    digest with what the server is known to hold (see SyncPlanner); what
//    differs is sent at once.
//  * The other device learns of it by a silent push when the server grants a
//    push subscription, and otherwise by a short poll while the app is in
//    front. The transport is plain CloudKit operations rather than
//    CKSyncEngine: the engine insists on creating its own subscription first
//    and fails the whole cycle when the server refuses it, which the China
//    iCloud gateway did (HTTP 500 on the subscription alone, records fine).
//  * Two edits of the same row: the later `updatedAt` wins.
//  * Nothing is ever deleted here because the store looks empty: a sweep that
//    would remove most known records is refused (a failed store open must
//    not wipe the server).

@MainActor
@Observable
final class CloudSync {
    static let containerID = "iCloud.com.shizhengcao.Tidemark"
    private static let subscriptionID = "ledger-changes"
    private static let zoneID = CKRecordZone.ID(zoneName: "Ledger", ownerName: CKCurrentUserDefaultName)
    private static let batchSize = 200

    /// The running instance, for the app delegates that receive pushes.
    private(set) static weak var current: CloudSync?

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
    /// Whether the push subscription is known to exist on the server.
    private(set) var pushReady = UserDefaults.standard.bool(forKey: "syncPushReady")

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
        /// Server change token of the zone, archived.
        var token: Data?
        var zoneReady = false
        var records: [String: SyncEntry] = [:]
        /// Records that name an account which has not arrived yet.
        var orphans: [String: SyncFields] = [:]
        /// Account ids that lost an identity merge → the id that survived.
        var aliases: [String: String] = [:]
        /// Record names to delete on the server.
        var pendingDeletes: [String] = []
    }

    private let context: ModelContext
    private var database: CKDatabase?
    private var state = StateFile()
    /// Rows to send, and the digest each had when it was queued.
    private var queued: [String: String] = [:]
    private var scanTask: Task<Void, Never>?
    private var syncing = false
    private var again = false
    private var observers: [NSObjectProtocol] = []
    private var pollTask: Task<Void, Never>?

    private static var folder: URL {
        let base = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private static var stateURL: URL { folder.appending(path: "sync-state-v2.json") }
    static var logURL: URL { folder.appending(path: "sync.log") }

    init(container: ModelContainer) {
        self.context = container.mainContext
    }

    // MARK: Lifecycle

    func start() {
        guard database == nil else { return }
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
        self.database = database
        Self.current = self
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
        // While the app is in front, ask for changes every 2 seconds: a fetch
        // with a change token is one small request, and silent pushes are
        // delivered late or not at all (measured: none arrived on the phone,
        // records showed up only on the next poll). Pushes still wake the app
        // in the background.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if self?.isActive == true { self?.fetchNow() }
            }
        }
        if ProcessInfo.processInfo.environment["TIDEMARK_SYNC_DIAG"] != nil {
            Task { await self.diagnose(database) }
            return
        }
        ensureSubscription(in: database)
        scan()
        fetchNow()
        runProbeIfAsked()
    }

    /// Step-by-step check of what the server accepts (TIDEMARK_SYNC_DIAG=1).
    private func diagnose(_ database: CKDatabase) async {
        func step(_ name: String, _ work: () async throws -> String) async {
            do { log("diag \(name): ok \(try await work())") }
            catch { log("diag \(name): FAILED \(String(describing: error).prefix(160))") }
        }
        let container = CKContainer(identifier: Self.containerID)
        await step("account status") { "\(try await container.accountStatus().rawValue)" }
        await step("user record id") { try await container.userRecordID().recordName.prefix(6) + "…" }
        await step("list zones") { try await database.allRecordZones().map(\.zoneID.zoneName).joined(separator: ",") }
        await step("fetch zone changes") {
            let changes = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: nil)
            return "\(changes.modificationResultsByID.count) records"
        }
        await step("save empty record, custom zone") {
            let record = CKRecord(recordType: "Ping", recordID: CKRecord.ID(recordName: "ping-1", zoneID: Self.zoneID))
            return try await database.save(record).recordID.recordName
        }
        await step("save one-field record, custom zone") {
            let record = CKRecord(recordType: "Ping", recordID: CKRecord.ID(recordName: "ping-2", zoneID: Self.zoneID))
            record["text"] = "hello"
            return try await database.save(record).recordID.recordName
        }
        await step("save record, default zone") {
            let record = CKRecord(recordType: "Ping", recordID: CKRecord.ID(recordName: "ping-3"))
            record["text"] = "hello"
            return try await database.save(record).recordID.recordName
        }
        await step("save record, public database") {
            let record = CKRecord(recordType: "Ping", recordID: CKRecord.ID(recordName: "ping-\(UUID().uuidString.prefix(8))"))
            record["text"] = "hello"
            return try await container.publicCloudDatabase.save(record).recordID.recordName
        }
        log("diag done")
    }

    private var isActive: Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState == .active
        #else
        NSApplication.shared.windows.contains { $0.isVisible && !$0.isMiniaturized }
        #endif
    }

    /// Ask the server to push when the zone changes. Failing is not fatal:
    /// polling covers it, and the next launch tries again.
    private func ensureSubscription(in database: CKDatabase) {
        guard !pushReady else { return }
        Task {
            let subscription = CKDatabaseSubscription(subscriptionID: Self.subscriptionID)
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            do {
                _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
                self.pushReady = true
                UserDefaults.standard.set(true, forKey: "syncPushReady")
                self.log("push subscription created")
            } catch {
                self.log("push subscription refused by the server (\(error.localizedDescription)); polling instead")
            }
        }
    }

    func pushArrived() {
        log("push received")
        fetchNow()
    }

    /// Run a sync cycle now (or right after the one in flight).
    func fetchNow() {
        guard database != nil else { return }
        if syncing { again = true; return }
        syncing = true
        Task {
            var rounds = 0
            repeat {
                again = false
                rounds += 1
                await cycle()
            } while again && rounds < 5
            syncing = false
        }
    }

    private func cycle() async {
        guard let database else { return }
        do {
            if !state.zoneReady {
                let result = try await database.modifyRecordZones(
                    saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
                // The call succeeds even when the one zone in it was refused.
                for outcome in result.saveResults.values { _ = try outcome.get() }
                state.zoneReady = true
                persist()
                log("zone ready")
            }
            try await push(to: database)
            try await pull(from: database)
            if case .off = phase { return }
            phase = .idle
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // The zone went away (or never existed here): start over from local data.
            log("zone missing on the server; creating it and uploading again")
            state.zoneReady = false
            state.token = nil
            state.records = [:]
            queued = [:]
            persist()
            scan()
            again = true
        } catch let error as CKError where error.code == .changeTokenExpired {
            state.token = nil
            again = true
        } catch {
            note(error, doing: "sync")
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
            self?.fetchNow()
        }
    }

    private struct Index {
        var accounts: [UUID: Account] = [:]
        var transactions: [UUID: Transaction] = [:]
        var presets: [UUID: RecordPreset] = [:]
    }

    private func loadIndex() -> Index {
        var index = Index()
        for account in (try? context.fetch(FetchDescriptor<Account>())) ?? [] where account.isLedgerAccount {
            index.accounts[account.id] = account
        }
        for transaction in (try? context.fetch(FetchDescriptor<Transaction>())) ?? [] {
            index.transactions[transaction.id] = transaction
        }
        for preset in (try? context.fetch(FetchDescriptor<RecordPreset>())) ?? [] {
            index.presets[preset.id] = preset
        }
        return index
    }

    private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: Self.zoneID) }

    /// Compare the store with what the server holds and queue the difference.
    private func scan() {
        guard database != nil else { return }
        let index = loadIndex()
        var local: [String: String] = [:]
        for (id, account) in index.accounts {
            local[SyncKey(.account, id).name] = SyncCodec.digest(SyncCodec.fields(of: account))
        }
        for (id, transaction) in index.transactions {
            local[SyncKey(.transaction, id).name] = SyncCodec.digest(SyncCodec.fields(of: transaction))
        }
        for (id, preset) in index.presets {
            local[SyncKey(.preset, id).name] = SyncCodec.digest(SyncCodec.fields(of: preset))
        }
        let plan = SyncPlanner.plan(local: local, synced: state.records, queued: queued)
        if plan.refusedDeletes {
            log("refused to delete most of the server's records; the local store looks incomplete")
        }
        // A queued row that no longer exists is no longer queued.
        for name in queued.keys where local[name] == nil { queued[name] = nil }
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
            case .preset:
                if let preset = index.presets[key.id], now.timeIntervalSince(preset.updatedAt) > 2 {
                    preset.updatedAt = now
                    stamped = true
                }
            }
        }
        if stamped { try? context.save() }
        for name in plan.deletes where !state.pendingDeletes.contains(name) { state.pendingDeletes.append(name) }
        persist()
        log("queued \(plan.saves.count) saves, \(plan.deletes.count) deletes")
    }

    private func push(to database: CKDatabase) async throws {
        guard !queued.isEmpty || !state.pendingDeletes.isEmpty else { return }
        phase = .syncing
        let index = loadIndex()
        var saves = queued.keys.sorted()
        var deletes = state.pendingDeletes
        var conflicts: [CKRecord] = []
        var saved = 0, deleted = 0, failed = 0

        while !saves.isEmpty || !deletes.isEmpty {
            let saveNames = Array(saves.prefix(Self.batchSize))
            saves.removeFirst(saveNames.count)
            let deleteNames = Array(deletes.prefix(Self.batchSize - saveNames.count))
            deletes.removeFirst(deleteNames.count)

            var records: [CKRecord] = []
            var sentDigest: [String: String] = [:]
            for name in saveNames {
                guard let record = record(for: recordID(name), index: index) else {
                    queued[name] = nil
                    continue
                }
                sentDigest[name] = SyncCodec.digest(Self.fields(from: record))
                records.append(record)
            }
            let result = try await database.modifyRecords(
                saving: records, deleting: deleteNames.map(recordID),
                savePolicy: .ifServerRecordUnchanged, atomically: false)

            for (id, outcome) in result.saveResults {
                let name = id.recordName
                switch outcome {
                case .success(let record):
                    state.records[name] = SyncEntry(digest: sentDigest[name] ?? "", system: Self.systemFields(of: record))
                    // Edited again while in flight: stays queued with its new digest.
                    if queued[name] == sentDigest[name] { queued[name] = nil }
                    saved += 1
                case .failure(let error):
                    failed += 1
                    guard let cloud = error as? CKError else { continue }
                    switch cloud.code {
                    case .serverRecordChanged:
                        guard let server = cloud.serverRecord else { continue }
                        let mine = records.first { $0.recordID == id }
                            .flatMap { SyncCodec.date(Self.fields(from: $0)["updatedAt"]) } ?? .distantPast
                        let theirs = SyncCodec.date(Self.fields(from: server)["updatedAt"]) ?? .distantPast
                        if mine > theirs {
                            // Ours is the later edit: send it again on top of the server's version.
                            state.records[name] = SyncEntry(digest: SyncCodec.digest(Self.fields(from: server)),
                                                            system: Self.systemFields(of: server))
                            again = true
                        } else {
                            queued[name] = nil
                            conflicts.append(server)
                        }
                    case .unknownItem:
                        state.records[name] = nil
                        again = true
                    case .zoneNotFound, .userDeletedZone:
                        throw cloud
                    default:
                        log("could not save \(name): \(cloud.localizedDescription)")
                    }
                }
            }
            for (id, outcome) in result.deleteResults {
                let name = id.recordName
                var done = true
                if case .failure(let error) = outcome, (error as? CKError)?.code != .unknownItem {
                    done = false
                    log("could not delete \(name): \(error.localizedDescription)")
                }
                if done {
                    state.records[name] = nil
                    state.pendingDeletes.removeAll { $0 == name }
                    deleted += 1
                }
            }
            persist()
        }
        if !conflicts.isEmpty { applyFetched(modifications: conflicts, deletions: []) }
        if saved + deleted > 0 {
            sentCount += saved + deleted
            lastActivity = Date()
        }
        log("sent \(saved) saves, \(deleted) deletes" + (failed > 0 ? ", \(failed) to settle" : ""))
        // Latency check: the edit time travels in the record.
    }

    private func pull(from database: CKDatabase) async throws {
        var token = state.token.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }
        var more = true
        while more {
            let changes = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: token)
            let modifications = changes.modificationResultsByID.values.compactMap { try? $0.get().record }
            applyFetched(modifications: modifications, deletions: changes.deletions.map(\.recordID.recordName))
            token = changes.changeToken
            state.token = try? NSKeyedArchiver.archivedData(withRootObject: changes.changeToken,
                                                            requiringSecureCoding: true)
            more = changes.moreComing
            persist()
        }
    }

    private func record(for recordID: CKRecord.ID, index: Index) -> CKRecord? {
        let name = recordID.recordName
        var fields: SyncFields?
        if let key = SyncKey(name: name) {
            switch key.kind {
            case .account: fields = index.accounts[key.id].map(SyncCodec.fields(of:))
            case .transaction: fields = index.transactions[key.id].map(SyncCodec.fields(of:))
            case .preset: fields = index.presets[key.id].map(SyncCodec.fields(of:))
            }
        }
        guard let key = SyncKey(name: name), let fields else {
            // Deleted since it was queued.
            return nil
        }
        let record = state.records[name]?.system.flatMap(Self.record(fromSystemFields:))
            ?? CKRecord(recordType: key.kind.recordType, recordID: recordID)
        for (field, value) in fields { record[field] = value }
        for field in record.allKeys() where fields[field] == nil { record[field] = nil }
        return record
    }

    // MARK: Server → local

    private func applyFetched(modifications fetched: [CKRecord], deletions: [String]) {
        // What we sent comes back in the next fetch; skip what is already here.
        let modifications = fetched.filter { record in
            let name = record.recordID.recordName
            guard let entry = state.records[name],
                  entry.digest == SyncCodec.digest(Self.fields(from: record)) else { return true }
            state.records[name] = SyncEntry(digest: entry.digest, system: Self.systemFields(of: record))
            return false
        }
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

        for record in modifications {
            guard let key = SyncKey(name: record.recordID.recordName), key.kind == .preset else { continue }
            let fields = Self.fields(from: record)
            let preset: RecordPreset
            if let existing = index.presets[key.id] {
                preset = existing
            } else {
                preset = RecordPreset(name: "", kind: .expense, amount: 0)
                preset.id = key.id
                context.insert(preset)
                index.presets[key.id] = preset
            }
            SyncCodec.apply(fields, to: preset)
            state.records[key.name] = SyncEntry(digest: SyncCodec.digest(SyncCodec.fields(of: preset)),
                                                system: Self.systemFields(of: record))
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
            case .preset: if let preset = index.presets[key.id] { context.delete(preset) }
            }
            state.records[name] = nil
            state.orphans[name] = nil
            queued[name] = nil
        }

        do { try context.save() } catch { note(error, doing: "save fetched changes") }
        if !retired.isEmpty {
            for name in retired where !state.pendingDeletes.contains(name) { state.pendingDeletes.append(name) }
            again = true
        }
        receivedCount += modifications.count + deletions.count
        lastActivity = now
        persist()
        log("received \(modifications.count) changes, \(deletions.count) deletions"
            + (lags.isEmpty ? "" : " [" + lags.joined(separator: "; ") + "]"))
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
        // The server's own explanation, when it gives one.
        let info = (error as NSError).userInfo
        let detail = ["ServerErrorDescription", "NSUnderlyingError", "CKErrorDescription", "NSDebugDescription"]
            .compactMap { key in info[key].map { "\(key)=\(String(describing: $0).prefix(400))" } }
            .joined(separator: " | ")
        log("\(message) — \(detail)")
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

// MARK: - Push delivery
//
// A silent push from the subscription means "the zone changed": fetch now.

#if canImport(UIKit)
final class SyncPushDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await MainActor.run { CloudSync.current?.pushArrived() }
        return .newData
    }
}
#elseif canImport(AppKit)
final class SyncPushDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { @MainActor in CloudSync.current?.pushArrived() }
    }
}
#endif
