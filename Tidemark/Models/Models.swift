import Foundation
import SwiftData

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
    var groupRaw: String = ""
    var cardNumber: String = ""
    var typeLabel: String = ""
    var creditLimit: Decimal? = nil
    var billingDay: Int? = nil
    var repaymentDay: Int? = nil

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
    var amount: Decimal
    var currencyCode: String
    var category: String
    var subcategory: String
    var merchant: String
    var note: String
    var tags: String
    var account: Account?
    var transferAccount: Account?
    var sourceRaw: String
    var externalID: String?
    @Attribute(.unique) var fingerprint: String
    var rawPayload: String?
    var createdAt: Date
    var excludeFromStats: Bool
    var importRecord: ImportRecord?
    var address: String = ""
    var refundAmount: Decimal = 0
    var discountAmount: Decimal = 0
    var feeAmount: Decimal = 0
    var transferAmount: Decimal? = nil
    var updatedAt: Date = Date()
    var claimStatusRaw: String = ""
    var claimAmount: Decimal = 0
    var presetID: UUID? = nil

    var claimStatus: ClaimStatus {
        get { ClaimStatus(rawValue: claimStatusRaw) ?? .none }
        set { claimStatusRaw = newValue.rawValue }
    }

    var netAmount: Decimal {
        guard kind == .expense else { return amount }
        return amount - refundAmount - (claimStatus == .claimed ? claimAmount : 0)
    }

    var returnedAmount: Decimal { amount - netAmount }

    var kind: TransactionKind {
        get { TransactionKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }
    var source: DataSource {
        get { DataSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    func cashDelta(for target: Account) -> Decimal {
        let isSource = account?.id == target.id
        let isDestination = transferAccount?.id == target.id
        switch kind {
        case .income:
            return isSource ? amount : 0
        case .expense:
            return isSource ? -netAmount : 0
        case .transfer, .liabilityPayment:
            if isSource && isDestination { return 0 }
            if isSource { return -amount }
            if isDestination { return amount }
            return 0
        case .investBuy:
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

enum ClaimStatus: String, CaseIterable, Identifiable {
    case none = ""
    case pending
    case claimed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return tr("Not reimbursable")
        case .pending: return tr("Pending")
        case .claimed: return tr("Claimed")
        }
    }
}

@Model
final class RecordPreset {
    @Attribute(.unique) var id: UUID
    var name: String
    var kindRaw: String
    var amount: Decimal
    var currencyCode: String
    var category: String
    var subcategory: String
    var accountID: UUID?
    var transferAccountID: UUID?
    var note: String
    var tags: String
    var scheduleRaw: String
    var startDate: Date
    var endDate: Date?
    var occurrenceLimit: Int?
    var generatedThrough: Int
    var isActive: Bool
    var createdAt: Date
    var updatedAt: Date

    var kind: TransactionKind {
        get { TransactionKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    var schedule: Frequency? {
        get { Frequency(rawValue: scheduleRaw) }
        set { scheduleRaw = newValue?.rawValue ?? "" }
    }

    init(name: String, kind: TransactionKind, amount: Decimal, currencyCode: String = "CNY") {
        self.id = UUID()
        self.name = name
        self.kindRaw = kind.rawValue
        self.amount = amount
        self.currencyCode = currencyCode
        self.category = ""
        self.subcategory = ""
        self.accountID = nil
        self.transferAccountID = nil
        self.note = ""
        self.tags = ""
        self.scheduleRaw = ""
        self.startDate = Date()
        self.endDate = nil
        self.occurrenceLimit = nil
        self.generatedThrough = -1
        self.isActive = true
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

@Model
final class Asset {
    @Attribute(.unique) var id: UUID
    var name: String
    var symbol: String
    var classRaw: String
    var currencyCode: String
    var note: String
    var createdAt: Date
    var exposureRaw: String? = nil
    var customName: String? = nil

    var displayName: String {
        if let customName, !customName.trimmingCharacters(in: .whitespaces).isEmpty { return customName }
        return name
    }

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
    var quantity: Decimal?
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

@Model
final class HoldingSnapshot {
    @Attribute(.unique) var id: UUID
    var holding: Holding?
    var date: Date
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

@Model
final class PlanScenario {
    @Attribute(.unique) var id: UUID
    var name: String
    var startingPortfolio: Decimal
    var monthlySavings: Decimal
    var annualSpending: Decimal
    var expectedRealReturn: Double
    var withdrawalRate: Double
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

enum TidemarkSchema {
    static let models: [any PersistentModel.Type] = [
        Account.self, Transaction.self, Asset.self, Holding.self,
        HoldingSnapshot.self, PricePoint.self, BalanceSnapshot.self,
        RecurringCommitment.self, FinancialGoal.self, PlanScenario.self,
        ImportRecord.self, ImportSourceState.self, CurrencyRate.self, RecordPreset.self,
    ]

    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory || isTesting, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
