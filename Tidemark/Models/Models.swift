import Foundation
import SwiftData

// MARK: - Canonical financial schema
//
// Design rules that keep the numbers honest:
//  * Money is stored as Decimal in the transaction's original currency.
//  * Cash-like accounts are ledger-driven: value = opening balance + signed
//    transactions, re-anchored by the most recent BalanceSnapshot (reconciliation).
//  * Investment/crypto accounts are holdings-driven: value = Σ holding values
//    (quantity × latest price, else the latest dated HoldingSnapshot). Account
//    BalanceSnapshots are used only when an account has no holdings — one source
//    of truth per account, so nothing is double counted.
//  * Every imported record keeps its source, raw payload and a deterministic
//    fingerprint so imports are idempotent and reviewable.

@Model
final class Account {
    @Attribute(.unique) var id: UUID
    var name: String
    var kindRaw: String
    var currencyCode: String
    var openingBalance: Decimal
    var includeInNetWorth: Bool
    var sourceRaw: String
    var note: String
    var createdAt: Date
    var updatedAt: Date
    var isArchived: Bool

    @Relationship(deleteRule: .cascade, inverse: \Transaction.account)
    var transactions: [Transaction] = []
    @Relationship(deleteRule: .nullify, inverse: \Transaction.transferAccount)
    var incomingTransfers: [Transaction] = []
    @Relationship(deleteRule: .cascade, inverse: \Holding.account)
    var holdings: [Holding] = []
    @Relationship(deleteRule: .cascade, inverse: \BalanceSnapshot.account)
    var snapshots: [BalanceSnapshot] = []

    var kind: AccountKind {
        get { AccountKind(rawValue: kindRaw) ?? .cash }
        set { kindRaw = newValue.rawValue }
    }
    var source: DataSource {
        get { DataSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    init(name: String,
         kind: AccountKind,
         currencyCode: String = "CNY",
         openingBalance: Decimal = 0,
         source: DataSource = .manual,
         note: String = "",
         includeInNetWorth: Bool = true) {
        self.id = UUID()
        self.name = name
        self.kindRaw = kind.rawValue
        self.currencyCode = currencyCode
        self.openingBalance = openingBalance
        self.includeInNetWorth = includeInNetWorth
        self.sourceRaw = source.rawValue
        self.note = note
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isArchived = false
    }
}

@Model
final class Transaction {
    @Attribute(.unique) var id: UUID
    var date: Date
    var kindRaw: String
    /// Positive magnitude in `currencyCode` (sign comes from `kind`;
    /// `.adjustment` may carry a signed amount).
    var amount: Decimal
    var currencyCode: String
    var category: String
    var subcategory: String
    var merchant: String
    var note: String
    var tags: String
    var account: Account?
    /// Destination account for transfers / repayments.
    var transferAccount: Account?
    var sourceRaw: String
    var externalID: String?
    /// Deterministic dedup key — unique across the store.
    @Attribute(.unique) var fingerprint: String
    /// JSON of the original source row, preserved verbatim.
    var rawPayload: String?
    var createdAt: Date
    var excludeFromStats: Bool
    var importRecord: ImportRecord?

    var kind: TransactionKind {
        get { TransactionKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }
    var source: DataSource {
        get { DataSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    /// Signed effect of this transaction on the given account's balance.
    func cashDelta(for target: Account) -> Decimal {
        let isSource = account?.id == target.id
        let isDestination = transferAccount?.id == target.id
        switch kind {
        case .income:
            return isSource ? amount : 0
        case .expense:
            return isSource ? -amount : 0
        case .transfer, .liabilityPayment:
            if isSource && isDestination { return 0 }
            if isSource { return -amount }
            if isDestination { return amount }
            return 0
        case .investBuy:
            // Cash leaves the paying account; the invested value is tracked by holdings.
            return isSource ? -amount : 0
        case .investSell:
            return isSource ? amount : 0
        case .adjustment:
            return isSource ? amount : 0
        }
    }

    init(date: Date,
         kind: TransactionKind,
         amount: Decimal,
         currencyCode: String = "CNY",
         category: String = "",
         subcategory: String = "",
         merchant: String = "",
         note: String = "",
         tags: String = "",
         account: Account? = nil,
         transferAccount: Account? = nil,
         source: DataSource = .manual,
         externalID: String? = nil,
         fingerprint: String? = nil,
         rawPayload: String? = nil,
         excludeFromStats: Bool = false) {
        self.id = UUID()
        self.date = date
        self.kindRaw = kind.rawValue
        self.amount = amount
        self.currencyCode = currencyCode
        self.category = category
        self.subcategory = subcategory
        self.merchant = merchant
        self.note = note
        self.tags = tags
        self.account = account
        self.transferAccount = transferAccount
        self.sourceRaw = source.rawValue
        self.externalID = externalID
        self.fingerprint = fingerprint ?? "manual:\(UUID().uuidString)"
        self.rawPayload = rawPayload
        self.createdAt = Date()
        self.excludeFromStats = excludeFromStats
    }
}

@Model
final class Asset {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Fund code ("005827") or ticker ("BTC").
    var symbol: String
    var classRaw: String
    /// Currency its price/valuation is quoted in.
    var currencyCode: String
    var note: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Holding.asset)
    var holdings: [Holding] = []
    @Relationship(deleteRule: .cascade, inverse: \PricePoint.asset)
    var prices: [PricePoint] = []

    var assetClass: AssetClass {
        get { AssetClass(rawValue: classRaw) ?? .other }
        set { classRaw = newValue.rawValue }
    }

    init(name: String, symbol: String, assetClass: AssetClass, currencyCode: String = "CNY", note: String = "") {
        self.id = UUID()
        self.name = name
        self.symbol = symbol
        self.classRaw = assetClass.rawValue
        self.currencyCode = currencyCode
        self.note = note
        self.createdAt = Date()
    }
}

@Model
final class Holding {
    @Attribute(.unique) var id: UUID
    var asset: Asset?
    var account: Account?
    /// Units/shares, when known. Nil means only valuation snapshots exist.
    var quantity: Decimal?
    /// Total cost in the asset's currency, when known. Never fabricated.
    var costBasis: Decimal?
    var openedAt: Date?
    var isActive: Bool
    var lastUpdated: Date
    var sourceRaw: String

    @Relationship(deleteRule: .cascade, inverse: \HoldingSnapshot.holding)
    var snapshots: [HoldingSnapshot] = []

    var source: DataSource {
        get { DataSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    init(asset: Asset?, account: Account?, quantity: Decimal? = nil,
         costBasis: Decimal? = nil, source: DataSource = .manual) {
        self.id = UUID()
        self.asset = asset
        self.account = account
        self.quantity = quantity
        self.costBasis = costBasis
        self.openedAt = nil
        self.isActive = true
        self.lastUpdated = Date()
        self.sourceRaw = source.rawValue
    }
}

/// A dated valuation of one holding (the unit the Alipay OCR importer writes).
@Model
final class HoldingSnapshot {
    @Attribute(.unique) var id: UUID
    var holding: Holding?
    var date: Date
    /// Market value in the asset's currency.
    var marketValue: Decimal
    var quantity: Decimal?
    var unitNAV: Decimal?
    var costBasis: Decimal?
    var unrealizedPL: Decimal?
    var returnRate: Decimal?
    var sourceRaw: String
    var createdAt: Date
    var importRecord: ImportRecord?

    var source: DataSource {
        get { DataSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    init(holding: Holding?, date: Date, marketValue: Decimal,
         quantity: Decimal? = nil, unitNAV: Decimal? = nil, costBasis: Decimal? = nil,
         unrealizedPL: Decimal? = nil, returnRate: Decimal? = nil,
         source: DataSource = .manual) {
        self.id = UUID()
        self.holding = holding
        self.date = date
        self.marketValue = marketValue
        self.quantity = quantity
        self.unitNAV = unitNAV
        self.costBasis = costBasis
        self.unrealizedPL = unrealizedPL
        self.returnRate = returnRate
        self.sourceRaw = source.rawValue
        self.createdAt = Date()
    }
}

@Model
final class PricePoint {
    @Attribute(.unique) var id: UUID
    var asset: Asset?
    var date: Date
    var price: Decimal
    var currencyCode: String
    var sourceRaw: String

    init(asset: Asset?, date: Date, price: Decimal, currencyCode: String, source: DataSource = .manual) {
        self.id = UUID()
        self.asset = asset
        self.date = date
        self.price = price
        self.currencyCode = currencyCode
        self.sourceRaw = source.rawValue
    }
}

/// Account-level reconciliation anchor ("the real balance was X on date D").
@Model
final class BalanceSnapshot {
    @Attribute(.unique) var id: UUID
    var account: Account?
    var date: Date
    var balance: Decimal
    var sourceRaw: String
    var note: String

    init(account: Account?, date: Date, balance: Decimal, source: DataSource = .manual, note: String = "") {
        self.id = UUID()
        self.account = account
        self.date = date
        self.balance = balance
        self.sourceRaw = source.rawValue
        self.note = note
    }
}

@Model
final class RecurringCommitment {
    @Attribute(.unique) var id: UUID
    var name: String
    var amount: Decimal
    var currencyCode: String
    var frequencyRaw: String
    var nextDueDate: Date
    var category: String
    var endDate: Date?
    var isActive: Bool
    var note: String
    /// Substring used to match real imported transactions, so a commitment
    /// that already appears in the ledger isn't projected twice.
    var matchKeyword: String
    var sourceRaw: String
    var createdAt: Date

    var frequency: Frequency {
        get { Frequency(rawValue: frequencyRaw) ?? .monthly }
        set { frequencyRaw = newValue.rawValue }
    }

    init(name: String, amount: Decimal, currencyCode: String = "CNY",
         frequency: Frequency = .monthly, nextDueDate: Date,
         category: String = "", endDate: Date? = nil, note: String = "",
         matchKeyword: String = "", source: DataSource = .manual) {
        self.id = UUID()
        self.name = name
        self.amount = amount
        self.currencyCode = currencyCode
        self.frequencyRaw = frequency.rawValue
        self.nextDueDate = nextDueDate
        self.category = category
        self.endDate = endDate
        self.isActive = true
        self.note = note
        self.matchKeyword = matchKeyword.isEmpty ? name : matchKeyword
        self.sourceRaw = source.rawValue
        self.createdAt = Date()
    }
}

@Model
final class FinancialGoal {
    @Attribute(.unique) var id: UUID
    var name: String
    var targetAmount: Decimal
    var targetDate: Date?
    var note: String
    var isPrimary: Bool
    var sourceRaw: String
    var createdAt: Date

    init(name: String, targetAmount: Decimal, targetDate: Date? = nil,
         note: String = "", isPrimary: Bool = false, source: DataSource = .manual) {
        self.id = UUID()
        self.name = name
        self.targetAmount = targetAmount
        self.targetDate = targetDate
        self.note = note
        self.isPrimary = isPrimary
        self.sourceRaw = source.rawValue
        self.createdAt = Date()
    }
}

/// A named what-if configuration for the Planning module. All outputs derived
/// from it are projections, never promises.
@Model
final class PlanScenario {
    @Attribute(.unique) var id: UUID
    var name: String
    var startingPortfolio: Decimal
    var monthlySavings: Decimal
    var annualSpending: Decimal
    /// Expected *real* annual return, as a fraction (0.04 = 4%).
    var expectedRealReturn: Double
    /// Safe withdrawal rate, as a fraction (0.04 = 4%).
    var withdrawalRate: Double
    /// Months of zero income at the start of the projection (stress case).
    var incomeGapMonths: Int
    var isBaseline: Bool
    var sortOrder: Int
    var sourceRaw: String
    var createdAt: Date

    init(name: String, startingPortfolio: Decimal, monthlySavings: Decimal,
         annualSpending: Decimal, expectedRealReturn: Double = 0.04,
         withdrawalRate: Double = 0.04, incomeGapMonths: Int = 0,
         isBaseline: Bool = false, sortOrder: Int = 0, source: DataSource = .manual) {
        self.id = UUID()
        self.name = name
        self.startingPortfolio = startingPortfolio
        self.monthlySavings = monthlySavings
        self.annualSpending = annualSpending
        self.expectedRealReturn = expectedRealReturn
        self.withdrawalRate = withdrawalRate
        self.incomeGapMonths = incomeGapMonths
        self.isBaseline = isBaseline
        self.sortOrder = sortOrder
        self.sourceRaw = source.rawValue
        self.createdAt = Date()
    }
}

@Model
final class ImportRecord {
    @Attribute(.unique) var id: UUID
    var sourceRaw: String
    var date: Date
    var fileName: String?
    var inserted: Int
    var skipped: Int
    var flagged: Int
    var statusRaw: String
    var summary: String
    var errorLog: String

    @Relationship(deleteRule: .cascade, inverse: \Transaction.importRecord)
    var transactions: [Transaction] = []
    @Relationship(deleteRule: .cascade, inverse: \HoldingSnapshot.importRecord)
    var holdingSnapshots: [HoldingSnapshot] = []

    var source: DataSource {
        get { DataSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }
    var status: ImportStatus {
        get { ImportStatus(rawValue: statusRaw) ?? .success }
        set { statusRaw = newValue.rawValue }
    }

    init(source: DataSource, fileName: String? = nil) {
        self.id = UUID()
        self.sourceRaw = source.rawValue
        self.date = Date()
        self.fileName = fileName
        self.inserted = 0
        self.skipped = 0
        self.flagged = 0
        self.statusRaw = ImportStatus.success.rawValue
        self.summary = ""
        self.errorLog = ""
    }
}

/// Per-source connection state shown on the Import Center cards.
@Model
final class ImportSourceState {
    @Attribute(.unique) var sourceRaw: String
    var lastSuccessAt: Date?
    var lastMessage: String
    var totalRecords: Int
    var isConnected: Bool
    var updatedAt: Date

    var source: DataSource {
        get { DataSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    init(source: DataSource) {
        self.sourceRaw = source.rawValue
        self.lastSuccessAt = nil
        self.lastMessage = ""
        self.totalRecords = 0
        self.isConnected = false
        self.updatedAt = Date()
    }
}

/// 1 unit of `code` = `rate` CNY (all rates pivot through CNY).
/// Dated rows are kept as history so period FX effects can be estimated.
@Model
final class CurrencyRate {
    @Attribute(.unique) var id: UUID
    var code: String
    var rate: Decimal
    var date: Date
    var sourceRaw: String
    var isSeeded: Bool

    init(code: String, rate: Decimal, date: Date = Date(), source: DataSource = .manual, isSeeded: Bool = false) {
        self.id = UUID()
        self.code = code
        self.rate = rate
        self.date = date
        self.sourceRaw = source.rawValue
        self.isSeeded = isSeeded
    }
}

// MARK: - Container

enum TidemarkSchema {
    static let models: [any PersistentModel.Type] = [
        Account.self, Transaction.self, Asset.self, Holding.self,
        HoldingSnapshot.self, PricePoint.self, BalanceSnapshot.self,
        RecurringCommitment.self, FinancialGoal.self, PlanScenario.self,
        ImportRecord.self, ImportSourceState.self, CurrencyRate.self,
    ]

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
