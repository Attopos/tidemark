import Foundation
import SwiftData
import CloudKit
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
@Observable
final class CloudSync {
    static let containerID = "iCloud.com.shizhengcao.Tidemark"
    private static let subscriptionID = "ledger-changes"
    private static let zoneID = CKRecordZone.ID(zoneName: "Ledger", ownerName: CKCurrentUserDefaultName)
    private static let batchSize = 200

    private(set) static weak var current: CloudSync?

    enum Phase: Equatable {
        case off(String)
        case idle
        case syncing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastActivity: Date?
    private(set) var sentCount = 0
    private(set) var receivedCount = 0
    private(set) var pushReady = UserDefaults.standard.bool(forKey: "syncPushReady")
    private(set) var portfolioBlocked = false

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
        var token: Data?
        var zoneReady = false
        var records: [String: SyncEntry] = [:]
        var orphans: [String: SyncFields] = [:]
        var aliases: [String: String] = [:]
        var pendingDeletes: [String] = []
        var environment: String?
    }

    private static let environment = "production"

    private let context: ModelContext
    private var database: CKDatabase?
    private var state = StateFile()
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

    func start() {
        guard database == nil else { return }
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
        if state.environment != Self.environment {
            state = StateFile()
            state.environment = Self.environment
            UserDefaults.standard.set(false, forKey: "syncPushReady")
            pushReady = false
            persist()
        }
        let database = CKContainer(identifier: Self.containerID).privateCloudDatabase
        if ProcessInfo.processInfo.environment["TIDEMARK_SYNC_SCHEMA"] != nil {
            phase = .off("Seeding the iCloud schema.")
            Task { await self.seedSchema(database) }
            return
        }
        self.database = database
        Self.current = self
        log("start: \(state.records.count) records known to the server")

        observers.append(NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] note in
                let changed = Self.changedIdentifiers(note)
                Task { @MainActor in self?.scheduleScan(changed) }
            })
        #if canImport(UIKit)
        UIApplication.shared.registerForRemoteNotifications()
        let active = UIApplication.didBecomeActiveNotification
        #else
        NSApplication.shared.registerForRemoteNotifications()
        let active = NSApplication.didBecomeActiveNotification
        #endif
        observers.append(NotificationCenter.default.addObserver(
            forName: CategoryStyles.didChange, object: nil, queue: .main) { [weak self] _ in
                UserDefaults.standard.set(true, forKey: Self.catalogDirtyKey)
                Task { @MainActor in
                    self?.catalogRetryAt = .distantPast
                    self?.fetchNow()
                }
            })
        observers.append(NotificationCenter.default.addObserver(forName: active, object: nil, queue: .main) {
            [weak self] _ in Task { @MainActor in self?.fetchNow() }
        })
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

    private func seedSchema(_ database: CKDatabase) async {
        let account = Account(name: "schema", kind: .liability, currencyCode: "CNY")
        account.cardNumber = "0000"; account.typeLabel = "t"; account.groupRaw = "credit"
        account.creditLimit = 1; account.billingDay = 1; account.repaymentDay = 2; account.note = "n"
        let other = Account(name: "schema-2", kind: .payment)
        let record = Transaction(date: Date(), kind: .transfer, amount: 1, category: "c", subcategory: "s",
                                 merchant: "m", note: "n", tags: "t", account: account, transferAccount: other,
                                 externalID: "e", rawPayload: "{}")
        record.address = "a"; record.transferAmount = 1; record.claimStatusRaw = "pending"; record.claimAmount = 1
        record.presetID = UUID(); record.refundAmount = 1; record.discountAmount = 1; record.feeAmount = 1
        let preset = RecordPreset(name: "schema", kind: .expense, amount: 1)
        preset.category = "c"; preset.subcategory = "s"; preset.note = "n"; preset.tags = "t"
        preset.accountID = UUID(); preset.transferAccountID = UUID(); preset.schedule = .monthly
        preset.endDate = Date(); preset.occurrenceLimit = 2
        let asset = Asset(name: "schema", symbol: "S", assetClass: .other, note: "n")
        asset.exposureRaw = "e"; asset.customName = "c"
        let fund = Account(name: "schema-fund", kind: .investment)
        let holding = Holding(asset: asset, account: fund, quantity: 1, costBasis: 1)
        holding.openedAt = Date()
        let valuation = HoldingSnapshot(holding: holding, date: Date(), marketValue: 1, quantity: 1, unitNAV: 1,
                                        costBasis: 1, unrealizedPL: 1, returnRate: 1)
        let seeds: [(String, String, SyncFields)] = [
            ("Account", "schema-seed-A", SyncCodec.fields(of: account)),
            ("LedgerRecord", "schema-seed-T", SyncCodec.fields(of: record)),
            ("Preset", "schema-seed-P", SyncCodec.fields(of: preset)),
            ("PortfolioAsset", "schema-seed-S", SyncCodec.fields(of: asset)),
            ("PortfolioHolding", "schema-seed-H", SyncCodec.fields(of: holding)),
            ("PortfolioValuation", "schema-seed-V", SyncCodec.fields(of: valuation)),
        ]
        do {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
            for (type, name, fields) in seeds {
                let ckRecord = CKRecord(recordType: type, recordID: recordID(name))
                for (key, value) in fields { ckRecord[key] = value.isEmpty ? "x" : value }
                _ = try await database.save(ckRecord)
                _ = try await database.deleteRecord(withID: ckRecord.recordID)
                log("schema seed: \(type) with \(fields.count) fields")
            }
            let catalog = CKRecord(recordType: Self.catalogType, recordID: recordID("schema-seed-C"))
            catalog["json"] = "{}"
            _ = try await database.save(catalog)
            _ = try await database.deleteRecord(withID: catalog.recordID)
            log("schema seed: \(Self.catalogType) with 1 field")
            log("schema seed done")
        } catch {
            log("schema seed failed: \(error)")
        }
    }

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
                for outcome in result.saveResults.values { _ = try outcome.get() }
                state.zoneReady = true
                persist()
                log("zone ready")
            }
            await pushCatalog(to: database)
            try await push(to: database)
            try await pull(from: database)
            if case .off = phase { return }
            if phase != .idle { phase = .idle }
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
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

    nonisolated private static func changedIdentifiers(_ note: Notification) -> [PersistentIdentifier]? {
        let info = note.userInfo ?? [:]
        let deleted = info[ModelContext.NotificationKey.deletedIdentifiers.rawValue] as? [PersistentIdentifier] ?? []
        guard deleted.isEmpty, info[ModelContext.NotificationKey.invalidatedAllIdentifiers.rawValue] == nil else { return nil }
        let inserted = info[ModelContext.NotificationKey.insertedIdentifiers.rawValue] as? [PersistentIdentifier]
        let updated = info[ModelContext.NotificationKey.updatedIdentifiers.rawValue] as? [PersistentIdentifier]
        guard inserted != nil || updated != nil else { return nil }
        return (inserted ?? []) + (updated ?? [])
    }

    private var pendingChanges: Set<PersistentIdentifier> = []
    private var pendingFullScan = false

    private func scheduleScan(_ changed: [PersistentIdentifier]? = nil) {
        if let changed { pendingChanges.formUnion(changed) } else { pendingFullScan = true }
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            let full = self.pendingFullScan || self.pendingChanges.count > 300
            let changes = self.pendingChanges
            self.pendingChanges = []
            self.pendingFullScan = false
            if full { self.scan() } else if !changes.isEmpty { self.scan(only: changes) }
            self.fetchNow()
        }
    }

    private func scan(only changes: Set<PersistentIdentifier>) {
        guard database != nil else { return }
        var saves: [String] = []
        var stamped = false
        let now = Date()
        func consider(_ name: String, _ fields: SyncFields, stamp: () -> Void) {
            let digest = SyncCodec.digest(fields)
            guard state.records[name]?.digest != digest, queued[name] != digest else { return }
            queued[name] = digest
            saves.append(name)
            stamp()
        }
        for id in changes {
            switch context.model(for: id) {
            case let account as Account where account.isLedgerAccount:
                consider(SyncKey(.account, account.id).name, SyncCodec.fields(of: account)) {
                    if now.timeIntervalSince(account.updatedAt) > 2 { account.updatedAt = now; stamped = true }
                }
            case let transaction as Transaction:
                consider(SyncKey(.transaction, transaction.id).name, SyncCodec.fields(of: transaction)) {
                    if now.timeIntervalSince(transaction.updatedAt) > 2 { transaction.updatedAt = now; stamped = true }
                }
            case let preset as RecordPreset:
                consider(SyncKey(.preset, preset.id).name, SyncCodec.fields(of: preset)) {
                    if now.timeIntervalSince(preset.updatedAt) > 2 { preset.updatedAt = now; stamped = true }
                }
            case let asset as Asset:
                guard !portfolioBlocked else { continue }
                consider(SyncKey(.asset, asset.id).name, SyncCodec.fields(of: asset)) {}
            case let holding as Holding:
                guard !portfolioBlocked else { continue }
                consider(SyncKey(.holding, holding.id).name, SyncCodec.fields(of: holding)) {}
            case let valuation as HoldingSnapshot:
                guard !portfolioBlocked else { continue }
                consider(SyncKey(.valuation, valuation.id).name, SyncCodec.fields(of: valuation)) {}
            default:
                continue
            }
        }
        guard !saves.isEmpty else { return }
        if stamped { try? context.save() }
        persist()
        log("queued \(saves.count) saves")
    }

    private struct Index {
        var accounts: [UUID: Account] = [:]
        var transactions: [UUID: Transaction] = [:]
        var presets: [UUID: RecordPreset] = [:]
        var assets: [UUID: Asset] = [:]
        var holdings: [UUID: Holding] = [:]
        var valuations: [UUID: HoldingSnapshot] = [:]
        var allAccounts: [Account] = []
    }

    private func loadIndex(transactions only: Set<UUID>? = nil) -> Index {
        var index = Index()
        index.allAccounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        for account in index.allAccounts where account.isLedgerAccount {
            index.accounts[account.id] = account
        }
        for asset in (try? context.fetch(FetchDescriptor<Asset>())) ?? [] { index.assets[asset.id] = asset }
        for holding in (try? context.fetch(FetchDescriptor<Holding>())) ?? [] { index.holdings[holding.id] = holding }
        for valuation in (try? context.fetch(FetchDescriptor<HoldingSnapshot>())) ?? [] {
            index.valuations[valuation.id] = valuation
        }
        var records = FetchDescriptor<Transaction>()
        if let only {
            let ids = Array(only)
            records.predicate = #Predicate { ids.contains($0.id) }
        }
        for transaction in (try? context.fetch(records)) ?? [] {
            index.transactions[transaction.id] = transaction
        }
        for preset in (try? context.fetch(FetchDescriptor<RecordPreset>())) ?? [] {
            index.presets[preset.id] = preset
        }
        return index
    }

    private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: Self.zoneID) }

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
        for (id, asset) in index.assets {
            local[SyncKey(.asset, id).name] = SyncCodec.digest(SyncCodec.fields(of: asset))
        }
        for (id, holding) in index.holdings {
            local[SyncKey(.holding, id).name] = SyncCodec.digest(SyncCodec.fields(of: holding))
        }
        for (id, valuation) in index.valuations {
            local[SyncKey(.valuation, id).name] = SyncCodec.digest(SyncCodec.fields(of: valuation))
        }
        var plan = SyncPlanner.plan(local: local, synced: state.records, queued: queued)
        if portfolioBlocked {
            plan.saves.removeAll { SyncKey(name: $0)?.kind.isPortfolio == true }
        }
        if plan.refusedDeletes {
            log("refused to delete most of the server's records; the local store looks incomplete")
        }
        for name in queued.keys where local[name] == nil { queued[name] = nil }
        guard !plan.saves.isEmpty || !plan.deletes.isEmpty else { return }

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
            case .asset, .holding, .valuation:
                break
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
        let index = loadIndex(transactions: Set(queued.keys.compactMap { name in
            SyncKey(name: name).flatMap { $0.kind == .transaction ? $0.id : nil }
        }))
        var saves = queued.keys.sorted()
        var deletes = state.pendingDeletes
        var conflicts: [CKRecord] = []
        var saved = 0, deleted = 0, failed = 0

        while !saves.isEmpty || !deletes.isEmpty {
            if portfolioBlocked { saves.removeAll { SyncKey(name: $0)?.kind.isPortfolio == true } }
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
                    if queued[name] == sentDigest[name] { queued[name] = nil }
                    saved += 1
                case .failure(let error):
                    failed += 1
                    guard let cloud = error as? CKError else { continue }
                    if SyncKey(name: name)?.kind.isPortfolio == true,
                       [.serverRejectedRequest, .invalidArguments, .permissionFailure].contains(cloud.code) {
                        if !portfolioBlocked {
                            log("server refused portfolio records (schema not deployed?): \(cloud.localizedDescription)")
                        }
                        portfolioBlocked = true
                        for queuedName in queued.keys where SyncKey(name: queuedName)?.kind.isPortfolio == true {
                            queued[queuedName] = nil
                        }
                        continue
                    }
                    switch cloud.code {
                    case .serverRecordChanged:
                        guard let server = cloud.serverRecord else { continue }
                        let mine = records.first { $0.recordID == id }
                            .flatMap { SyncCodec.date(Self.fields(from: $0)["updatedAt"]) } ?? .distantPast
                        let theirs = SyncCodec.date(Self.fields(from: server)["updatedAt"]) ?? .distantPast
                        if mine > theirs {
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
    }

    private func pull(from database: CKDatabase) async throws {
        var token = state.token.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }
        var more = true
        while more {
            let changes = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: token)
            let fetched = changes.modificationResultsByID.values.compactMap { try? $0.get().record }
            applyCatalog(fetched.filter { $0.recordType == Self.catalogType })
            let modifications = fetched.filter { $0.recordType != Self.catalogType }
            let deletions = changes.deletions.map(\.recordID.recordName)
            applyFetched(modifications: modifications, deletions: deletions)
            token = changes.changeToken
            let archived = try? NSKeyedArchiver.archivedData(withRootObject: changes.changeToken,
                                                             requiringSecureCoding: true)
            more = changes.moreComing
            guard archived != state.token || !modifications.isEmpty || !deletions.isEmpty else { continue }
            state.token = archived
            persist()
        }
    }

    nonisolated static let catalogType = "CategoryCatalog"
    nonisolated static let catalogDirtyKey = "categoryCatalogDirty"
    private var catalogRecordID: CKRecord.ID { recordID("category-catalog") }
    private var catalogRetryAt = Date.distantPast

    private func pushCatalog(to database: CKDatabase) async {
        guard UserDefaults.standard.bool(forKey: Self.catalogDirtyKey), Date() >= catalogRetryAt,
              let data = try? JSONEncoder().encode(CategoryStyles.shared.catalog),
              let json = String(data: data, encoding: .utf8) else { return }
        do {
            let existing = try? await database.record(for: catalogRecordID)
            if let existing, let remote = Self.catalog(from: existing),
               remote.updatedAt > CategoryStyles.shared.catalog.updatedAt {
                CategoryStyles.shared.replace(with: remote)
                UserDefaults.standard.set(false, forKey: Self.catalogDirtyKey)
                return
            }
            let record = existing ?? CKRecord(recordType: Self.catalogType, recordID: catalogRecordID)
            record["json"] = json
            let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            for outcome in result.saveResults.values { _ = try outcome.get() }
            UserDefaults.standard.set(false, forKey: Self.catalogDirtyKey)
            log("category catalog sent")
        } catch {
            catalogRetryAt = Date().addingTimeInterval(600)
            log("category catalog not sent: \(String(describing: error).prefix(160))")
        }
    }

    private func applyCatalog(_ records: [CKRecord]) {
        for record in records {
            guard let remote = Self.catalog(from: record) else { continue }
            CategoryStyles.shared.replace(with: remote)
        }
    }

    private static func catalog(from record: CKRecord) -> CategoryCatalog? {
        guard let json = record["json"] as? String, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CategoryCatalog.self, from: data)
    }

    private func record(for recordID: CKRecord.ID, index: Index) -> CKRecord? {
        let name = recordID.recordName
        var fields: SyncFields?
        if let key = SyncKey(name: name) {
            switch key.kind {
            case .account: fields = index.accounts[key.id].map(SyncCodec.fields(of:))
            case .transaction: fields = index.transactions[key.id].map(SyncCodec.fields(of:))
            case .preset: fields = index.presets[key.id].map(SyncCodec.fields(of:))
            case .asset: fields = index.assets[key.id].map(SyncCodec.fields(of:))
            case .holding: fields = index.holdings[key.id].map(SyncCodec.fields(of:))
            case .valuation: fields = index.valuations[key.id].map(SyncCodec.fields(of:))
            }
        }
        guard let key = SyncKey(name: name), let fields else {
            return nil
        }
        let record = state.records[name]?.system.flatMap(Self.record(fromSystemFields:))
            ?? CKRecord(recordType: key.kind.recordType, recordID: recordID)
        for (field, value) in fields { record[field] = value }
        for field in record.allKeys() where fields[field] == nil { record[field] = nil }
        return record
    }

    private func applyFetched(modifications fetched: [CKRecord], deletions: [String]) {
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

        for record in modifications {
            guard let key = SyncKey(name: record.recordID.recordName), key.kind == .account else { continue }
            let fields = Self.fields(from: record)
            let account: Account
            if let existing = index.accounts[key.id] {
                account = existing
            } else if let twin = index.accounts.values.first(where: { $0.name == fields["name"] }) {
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

        func holdingAccount(_ fields: SyncFields) -> Account? {
            guard let name = fields["accountName"], !name.isEmpty else { return nil }
            let kind = fields["accountKind"] ?? AccountKind.investment.rawValue
            if let existing = index.allAccounts.first(where: { $0.name == name && $0.kindRaw == kind }) {
                return existing
            }
            let created = Account(name: name, kind: AccountKind(rawValue: kind) ?? .investment,
                                  currencyCode: fields["accountCurrency"] ?? "CNY")
            context.insert(created)
            index.allAccounts.append(created)
            return created
        }

        func applyHolding(_ key: SyncKey, _ fields: SyncFields, system: Data?) {
            let holding: Holding
            if let existing = index.holdings[key.id] {
                holding = existing
            } else {
                holding = Holding(asset: nil, account: nil)
                holding.id = key.id
                context.insert(holding)
                index.holdings[key.id] = holding
            }
            let complete = SyncCodec.apply(fields, to: holding, assets: index.assets, account: holdingAccount)
            state.orphans[key.name] = complete ? nil : fields
            state.records[key.name] = SyncEntry(digest: SyncCodec.digest(SyncCodec.fields(of: holding)),
                                                system: system ?? state.records[key.name]?.system)
            queued[key.name] = nil
        }

        func applyValuation(_ key: SyncKey, _ fields: SyncFields, system: Data?) {
            let valuation: HoldingSnapshot
            if let existing = index.valuations[key.id] {
                valuation = existing
            } else {
                valuation = HoldingSnapshot(holding: nil, date: now, marketValue: 0)
                valuation.id = key.id
                context.insert(valuation)
                index.valuations[key.id] = valuation
            }
            let complete = SyncCodec.apply(fields, to: valuation, holdings: index.holdings)
            state.orphans[key.name] = complete ? nil : fields
            state.records[key.name] = SyncEntry(digest: SyncCodec.digest(SyncCodec.fields(of: valuation)),
                                                system: system ?? state.records[key.name]?.system)
            queued[key.name] = nil
        }

        for record in modifications {
            guard let key = SyncKey(name: record.recordID.recordName), key.kind == .asset else { continue }
            let fields = Self.fields(from: record)
            let asset: Asset
            if let existing = index.assets[key.id] {
                asset = existing
            } else {
                asset = Asset(name: fields["name"] ?? "", symbol: "", assetClass: .other)
                asset.id = key.id
                context.insert(asset)
                index.assets[key.id] = asset
            }
            SyncCodec.apply(fields, to: asset)
            state.records[key.name] = SyncEntry(digest: SyncCodec.digest(SyncCodec.fields(of: asset)),
                                                system: Self.systemFields(of: record))
            queued[key.name] = nil
        }
        for record in modifications {
            guard let key = SyncKey(name: record.recordID.recordName), key.kind == .holding else { continue }
            applyHolding(key, Self.fields(from: record), system: Self.systemFields(of: record))
        }
        for record in modifications {
            guard let key = SyncKey(name: record.recordID.recordName), key.kind == .valuation else { continue }
            applyValuation(key, Self.fields(from: record), system: Self.systemFields(of: record))
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
        for kind in [SyncKind.transaction, .holding, .valuation] {
            for (name, fields) in state.orphans {
                guard let key = SyncKey(name: name), key.kind == kind else { continue }
                switch kind {
                case .holding: applyHolding(key, fields, system: nil)
                case .valuation: applyValuation(key, fields, system: nil)
                default: applyRecord(key, fields, system: nil)
                }
            }
        }

        for name in deletions {
            guard let key = SyncKey(name: name) else { continue }
            switch key.kind {
            case .account: if let account = index.accounts[key.id] { context.delete(account) }
            case .transaction: if let transaction = index.transactions[key.id] { context.delete(transaction) }
            case .preset: if let preset = index.presets[key.id] { context.delete(preset) }
            case .asset: if let asset = index.assets[key.id] { context.delete(asset) }
            case .holding: if let holding = index.holdings[key.id] { context.delete(holding) }
            case .valuation: if let valuation = index.valuations[key.id] { context.delete(valuation) }
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

    private let writer = StateWriter()

    private func persist() {
        let snapshot = state
        writer.write(to: Self.stateURL) { try? JSONEncoder().encode(snapshot) }
    }

    private func note(_ error: Error, doing what: String) {
        let message = "\(what) failed: \(error.localizedDescription)"
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

private final class StateWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.shizhengcao.Tidemark.sync-state", qos: .utility)
    private let lock = NSLock()
    private var pending: (() -> Data?)?

    func write(to url: URL, _ encode: @escaping () -> Data?) {
        lock.lock()
        let scheduled = pending != nil
        pending = encode
        lock.unlock()
        guard !scheduled else { return }
        queue.async { [self] in
            lock.lock()
            let job = pending
            pending = nil
            lock.unlock()
            if let data = job?() { try? data.write(to: url, options: .atomic) }
        }
    }
}
