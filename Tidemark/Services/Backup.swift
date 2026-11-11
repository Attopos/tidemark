import Foundation
import SwiftData

// MARK: - Backup & restore
//
// The store lives in the app's sandbox container on one Mac. A backup is a
// plain JSON file of everything the board is built from (accounts that hold
// something, assets, holdings, every dated valuation, prices, fetched rates,
// settings), written to iCloud Drive › Tidemark so it follows the user to
// another device. The format is independent of SwiftData: ids and raw
// strings, amounts as decimal strings (JSON numbers would round them).
//
// Restoring merges by id: records in the backup are added or updated,
// nothing is ever deleted. Restoring twice changes nothing.

struct BackupFile: Codable {
    static let formatID = "tidemark.backup"
    static let currentVersion = 1

    var format: String
    var version: Int
    var createdAt: Date
    var settings: Settings
    var accounts: [AccountRecord]
    var assets: [AssetRecord]
    var holdings: [HoldingRecord]
    var snapshots: [SnapshotRecord]
    var prices: [PriceRecord]
    var rates: [RateRecord]
    /// Ledger records. Optional so backups made before the ledger still load.
    var transactions: [TransactionRecord]? = nil

    struct Settings: Codable {
        var baseCurrency: String?
        var language: String?
        var targets: [String: Double]?
    }

    struct AccountRecord: Codable {
        var id: UUID
        var name: String
        var kind: String
        var currency: String
        var source: String
        var note: String
        var includeInNetWorth: Bool
        var isArchived: Bool
        var createdAt: Date
        var openingBalance: String? = nil
    }

    struct TransactionRecord: Codable {
        var id: UUID
        var date: Date
        var kind: String
        var amount: String
        var currency: String
        var category: String
        var subcategory: String
        var merchant: String
        var note: String
        var tags: String
        var address: String
        var account: UUID?
        var transferAccount: UUID?
        var transferAmount: String?
        var refund: String
        var discount: String
        var fee: String
        var source: String
        var externalID: String?
        var fingerprint: String
        var rawPayload: String?
        var excludeFromStats: Bool
        var createdAt: Date
        var updatedAt: Date
    }

    struct AssetRecord: Codable {
        var id: UUID
        var name: String
        var symbol: String
        var assetClass: String
        var currency: String
        var note: String
        var exposure: String?
        var customName: String?
        var createdAt: Date
    }

    struct HoldingRecord: Codable {
        var id: UUID
        var asset: UUID?
        var account: UUID?
        var quantity: String?
        var costBasis: String?
        var openedAt: Date?
        var isActive: Bool
        var lastUpdated: Date
        var source: String
    }

    struct SnapshotRecord: Codable {
        var id: UUID
        var holding: UUID
        var date: Date
        var marketValue: String
        var quantity: String?
        var unitNAV: String?
        var costBasis: String?
        var unrealizedPL: String?
        var returnRate: String?
        var source: String
        var createdAt: Date
    }

    struct PriceRecord: Codable {
        var id: UUID
        var asset: UUID
        var date: Date
        var price: String
        var currency: String
        var source: String
    }

    struct RateRecord: Codable {
        var id: UUID
        var code: String
        var rate: String
        var date: Date
        var source: String
    }
}

enum BackupError: LocalizedError {
    case notABackup
    case newerVersion(Int)

    var errorDescription: String? {
        switch self {
        case .notABackup: return "This file is not a Tidemark backup."
        case .newerVersion(let version): return "This backup was made by a newer Tidemark (format \(version)). Update the app first."
        }
    }
}

@MainActor
enum BackupService {
    struct RestoreStats: Equatable {
        var added = 0
        var updated = 0
    }

    // MARK: Decimal <-> string

    private static let posix = Locale(identifier: "en_US_POSIX")

    static func string(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).description(withLocale: posix)
    }

    static func decimal(_ text: String) -> Decimal {
        Decimal(string: text, locale: posix) ?? 0
    }

    // MARK: Store -> backup

    static func makeBackup(from context: ModelContext, settings: BackupFile.Settings) throws -> BackupFile {
        let holdings = try context.fetch(FetchDescriptor<Holding>())
        let assets = try context.fetch(FetchDescriptor<Asset>())
        let rates = try context.fetch(FetchDescriptor<CurrencyRate>())

        let transactions = try context.fetch(FetchDescriptor<Transaction>())

        // Accounts that hold something, plus every cash-side ledger account.
        var accounts: [UUID: Account] = [:]
        for holding in holdings {
            if let account = holding.account { accounts[account.id] = account }
        }
        for account in try context.fetch(FetchDescriptor<Account>()) where account.isLedgerAccount {
            accounts[account.id] = account
        }

        return BackupFile(
            format: BackupFile.formatID,
            version: BackupFile.currentVersion,
            createdAt: Date(),
            settings: settings,
            accounts: accounts.values.sorted { $0.createdAt < $1.createdAt }.map {
                .init(id: $0.id, name: $0.name, kind: $0.kindRaw, currency: $0.currencyCode,
                      source: $0.sourceRaw, note: $0.note, includeInNetWorth: $0.includeInNetWorth,
                      isArchived: $0.isArchived, createdAt: $0.createdAt,
                      openingBalance: string($0.openingBalance))
            },
            assets: assets.sorted { $0.createdAt < $1.createdAt }.map {
                .init(id: $0.id, name: $0.name, symbol: $0.symbol, assetClass: $0.classRaw,
                      currency: $0.currencyCode, note: $0.note, exposure: $0.exposureRaw,
                      customName: $0.customName, createdAt: $0.createdAt)
            },
            holdings: holdings.sorted { $0.lastUpdated < $1.lastUpdated }.map {
                .init(id: $0.id, asset: $0.asset?.id, account: $0.account?.id,
                      quantity: $0.quantity.map(string), costBasis: $0.costBasis.map(string),
                      openedAt: $0.openedAt, isActive: $0.isActive, lastUpdated: $0.lastUpdated,
                      source: $0.sourceRaw)
            },
            snapshots: holdings.flatMap { holding in
                holding.snapshots.map {
                    BackupFile.SnapshotRecord(
                        id: $0.id, holding: holding.id, date: $0.date,
                        marketValue: string($0.marketValue),
                        quantity: $0.quantity.map(string), unitNAV: $0.unitNAV.map(string),
                        costBasis: $0.costBasis.map(string), unrealizedPL: $0.unrealizedPL.map(string),
                        returnRate: $0.returnRate.map(string),
                        source: $0.sourceRaw, createdAt: $0.createdAt)
                }
            }.sorted { $0.date < $1.date },
            prices: assets.flatMap { asset in
                asset.prices.map {
                    BackupFile.PriceRecord(id: $0.id, asset: asset.id, date: $0.date,
                                           price: string($0.price), currency: $0.currencyCode,
                                           source: $0.sourceRaw)
                }
            }.sorted { $0.date < $1.date },
            // Seed rates are rebuilt by the app; only real ones are history.
            rates: rates.filter { !$0.isSeeded }.sorted { $0.date < $1.date }.map {
                .init(id: $0.id, code: $0.code, rate: string($0.rate), date: $0.date, source: $0.sourceRaw)
            },
            transactions: transactions.sorted { $0.date < $1.date }.map {
                .init(id: $0.id, date: $0.date, kind: $0.kindRaw, amount: string($0.amount),
                      currency: $0.currencyCode, category: $0.category, subcategory: $0.subcategory,
                      merchant: $0.merchant, note: $0.note, tags: $0.tags, address: $0.address,
                      account: $0.account?.id, transferAccount: $0.transferAccount?.id,
                      transferAmount: $0.transferAmount.map(string), refund: string($0.refundAmount),
                      discount: string($0.discountAmount), fee: string($0.feeAmount),
                      source: $0.sourceRaw, externalID: $0.externalID, fingerprint: $0.fingerprint,
                      rawPayload: $0.rawPayload, excludeFromStats: $0.excludeFromStats,
                      createdAt: $0.createdAt, updatedAt: $0.updatedAt)
            })
    }

    static func encode(_ backup: BackupFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    static func decode(_ data: Data) throws -> BackupFile {
        struct Header: Decodable {
            let format: String
            let version: Int
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(Header.self, from: data),
              header.format == BackupFile.formatID else { throw BackupError.notABackup }
        guard header.version <= BackupFile.currentVersion else { throw BackupError.newerVersion(header.version) }
        return try decoder.decode(BackupFile.self, from: data)
    }

    // MARK: Backup -> store (merge by id, never delete)

    @discardableResult
    static func restore(_ backup: BackupFile, into context: ModelContext) throws -> RestoreStats {
        var stats = RestoreStats()

        var accounts: [UUID: Account] = [:]
        for account in try context.fetch(FetchDescriptor<Account>()) { accounts[account.id] = account }
        var assets: [UUID: Asset] = [:]
        for asset in try context.fetch(FetchDescriptor<Asset>()) { assets[asset.id] = asset }
        var holdings: [UUID: Holding] = [:]
        for holding in try context.fetch(FetchDescriptor<Holding>()) { holdings[holding.id] = holding }
        var snapshots: [UUID: HoldingSnapshot] = [:]
        for snapshot in try context.fetch(FetchDescriptor<HoldingSnapshot>()) { snapshots[snapshot.id] = snapshot }
        var prices: [UUID: PricePoint] = [:]
        for price in try context.fetch(FetchDescriptor<PricePoint>()) { prices[price.id] = price }
        var rates: [UUID: CurrencyRate] = [:]
        for rate in try context.fetch(FetchDescriptor<CurrencyRate>()) { rates[rate.id] = rate }

        for record in backup.accounts {
            let account: Account
            if let existing = accounts[record.id] {
                account = existing
                stats.updated += 1
            } else {
                account = Account(name: record.name, kind: .investment)
                account.id = record.id
                context.insert(account)
                accounts[record.id] = account
                stats.added += 1
            }
            account.name = record.name
            account.kindRaw = record.kind
            account.currencyCode = record.currency
            account.sourceRaw = record.source
            account.note = record.note
            account.includeInNetWorth = record.includeInNetWorth
            account.isArchived = record.isArchived
            account.createdAt = record.createdAt
            if let opening = record.openingBalance { account.openingBalance = decimal(opening) }
        }

        for record in backup.assets {
            let asset: Asset
            if let existing = assets[record.id] {
                asset = existing
                stats.updated += 1
            } else {
                asset = Asset(name: record.name, symbol: record.symbol, assetClass: .other)
                asset.id = record.id
                context.insert(asset)
                assets[record.id] = asset
                stats.added += 1
            }
            asset.name = record.name
            asset.symbol = record.symbol
            asset.classRaw = record.assetClass
            asset.currencyCode = record.currency
            asset.note = record.note
            asset.exposureRaw = record.exposure
            asset.customName = record.customName
            asset.createdAt = record.createdAt
        }

        for record in backup.holdings {
            let holding: Holding
            if let existing = holdings[record.id] {
                holding = existing
                stats.updated += 1
            } else {
                holding = Holding(asset: nil, account: nil)
                holding.id = record.id
                context.insert(holding)
                holdings[record.id] = holding
                stats.added += 1
            }
            holding.asset = record.asset.flatMap { assets[$0] }
            holding.account = record.account.flatMap { accounts[$0] }
            holding.quantity = record.quantity.map(decimal)
            holding.costBasis = record.costBasis.map(decimal)
            holding.openedAt = record.openedAt
            holding.isActive = record.isActive
            holding.lastUpdated = record.lastUpdated
            holding.sourceRaw = record.source
        }

        for record in backup.snapshots {
            guard let holding = holdings[record.holding] else { continue }
            let snapshot: HoldingSnapshot
            if let existing = snapshots[record.id] {
                snapshot = existing
                stats.updated += 1
            } else {
                snapshot = HoldingSnapshot(holding: holding, date: record.date, marketValue: decimal(record.marketValue))
                snapshot.id = record.id
                context.insert(snapshot)
                snapshots[record.id] = snapshot
                stats.added += 1
            }
            snapshot.holding = holding
            snapshot.date = record.date
            snapshot.marketValue = decimal(record.marketValue)
            snapshot.quantity = record.quantity.map(decimal)
            snapshot.unitNAV = record.unitNAV.map(decimal)
            snapshot.costBasis = record.costBasis.map(decimal)
            snapshot.unrealizedPL = record.unrealizedPL.map(decimal)
            snapshot.returnRate = record.returnRate.map(decimal)
            snapshot.sourceRaw = record.source
            snapshot.createdAt = record.createdAt
        }

        for record in backup.prices {
            guard let asset = assets[record.asset] else { continue }
            let price: PricePoint
            if let existing = prices[record.id] {
                price = existing
                stats.updated += 1
            } else {
                price = PricePoint(asset: asset, date: record.date, price: decimal(record.price),
                                   currencyCode: record.currency)
                price.id = record.id
                context.insert(price)
                prices[record.id] = price
                stats.added += 1
            }
            price.asset = asset
            price.date = record.date
            price.price = decimal(record.price)
            price.currencyCode = record.currency
            price.sourceRaw = record.source
        }

        for record in backup.rates {
            let rate: CurrencyRate
            if let existing = rates[record.id] {
                rate = existing
                stats.updated += 1
            } else {
                rate = CurrencyRate(code: record.code, rate: decimal(record.rate), date: record.date)
                rate.id = record.id
                context.insert(rate)
                rates[record.id] = rate
                stats.added += 1
            }
            rate.code = record.code
            rate.rate = decimal(record.rate)
            rate.date = record.date
            rate.sourceRaw = record.source
            rate.isSeeded = false
        }

        // Ledger records: matched by id, then by fingerprint (the same export
        // imported on two devices yields the same fingerprints).
        var transactions: [UUID: Transaction] = [:]
        var byFingerprint: [String: Transaction] = [:]
        for transaction in try context.fetch(FetchDescriptor<Transaction>()) {
            transactions[transaction.id] = transaction
            byFingerprint[transaction.fingerprint] = transaction
        }
        for record in backup.transactions ?? [] {
            let transaction: Transaction
            if let existing = transactions[record.id] ?? byFingerprint[record.fingerprint] {
                transaction = existing
                stats.updated += 1
            } else {
                transaction = Transaction(date: record.date, kind: .expense, amount: 0,
                                          fingerprint: record.fingerprint)
                transaction.id = record.id
                context.insert(transaction)
                transactions[record.id] = transaction
                byFingerprint[record.fingerprint] = transaction
                stats.added += 1
            }
            transaction.date = record.date
            transaction.kindRaw = record.kind
            transaction.amount = decimal(record.amount)
            transaction.currencyCode = record.currency
            transaction.category = record.category
            transaction.subcategory = record.subcategory
            transaction.merchant = record.merchant
            transaction.note = record.note
            transaction.tags = record.tags
            transaction.address = record.address
            transaction.account = record.account.flatMap { accounts[$0] }
            transaction.transferAccount = record.transferAccount.flatMap { accounts[$0] }
            transaction.transferAmount = record.transferAmount.map(decimal)
            transaction.refundAmount = decimal(record.refund)
            transaction.discountAmount = decimal(record.discount)
            transaction.feeAmount = decimal(record.fee)
            transaction.sourceRaw = record.source
            transaction.externalID = record.externalID
            transaction.rawPayload = record.rawPayload
            transaction.excludeFromStats = record.excludeFromStats
            transaction.createdAt = record.createdAt
            transaction.updatedAt = record.updatedAt
        }

        try context.save()
        return stats
    }

    // MARK: Files

    /// The user's real home; inside the sandbox NSHomeDirectory() is the container.
    private static var realHome: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// iCloud Drive › Tidemark. The sandbox is allowed exactly this folder
    /// (see Tidemark.entitlements); it only exists when iCloud Drive is on.
    static var automaticFolder: URL {
        realHome.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Tidemark", isDirectory: true)
    }

    static let filePrefix = "Tidemark-backup-"
    static let keepFiles = 60

    static func fileName(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(filePrefix)\(formatter.string(from: date)).json"
    }

    /// One file per day (a later backup the same day replaces it); the
    /// oldest files beyond `keepFiles` are removed.
    @discardableResult
    static func writeBackup(_ backup: BackupFile, to folder: URL) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(for: backup.createdAt))
        try encode(backup).write(to: url, options: .atomic)
        let old = backupFiles(in: folder).dropFirst(keepFiles)
        for stale in old { try? files.removeItem(at: stale) }
        return url
    }

    /// Backup files in a folder, newest first (the name carries the date).
    static func backupFiles(in folder: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return all
            .filter { $0.lastPathComponent.hasPrefix(filePrefix) && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
