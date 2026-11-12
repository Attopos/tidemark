import Foundation

// MARK: - Cash-flow analytics
//
// Pure calculations over ledger records, independent of SwiftData and of the
// views, so every figure on the Ledger, Accounts and Analysis pages can be
// unit-tested.
//
// Conventions:
//  * Income and expense are the only kinds that count as cash flow. Moving
//    money between own accounts (transfer, repayment, lending) never does.
//  * An expense counts net of its refund.
//  * Every amount is converted to the display currency at the rate of the
//    record's own date, so a past month does not change when rates move.
//  * Averages divide by the days (or months) that have already started, so
//    the current period is not diluted by its future days.

/// One ledger record, reduced to what statistics need.
struct CashEntry: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let kind: TransactionKind
    let category: String
    let subcategory: String
    /// Net amount in the display currency, always positive.
    let base: Decimal
    var refund: Decimal = 0
    var discount: Decimal = 0
    var fee: Decimal = 0
    /// Reimbursable spending not yet paid back / what was paid back.
    var claimPending: Decimal = 0
    var claimed: Decimal = 0
    var excluded = false
}

struct CashPeriod: Equatable, Hashable {
    enum Unit: String, CaseIterable { case month, year }

    let unit: Unit
    /// First instant of the period.
    let start: Date

    init(unit: Unit, containing date: Date, calendar: Calendar = .current) {
        self.unit = unit
        switch unit {
        case .month:
            start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        case .year:
            start = calendar.date(from: calendar.dateComponents([.year], from: date)) ?? date
        }
    }

    private var component: Calendar.Component { unit == .month ? .month : .year }

    /// First instant after the period.
    func end(_ calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: component, value: 1, to: start) ?? start
    }

    func shifted(by value: Int, calendar: Calendar = .current) -> CashPeriod {
        CashPeriod(unit: unit, containing: calendar.date(byAdding: component, value: value, to: start) ?? start,
                   calendar: calendar)
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        date >= start && date < end(calendar)
    }

    /// Starts of the buckets a chart shows: days of a month, months of a year.
    func bucketStarts(_ calendar: Calendar = .current) -> [Date] {
        let step: Calendar.Component = unit == .month ? .day : .month
        var starts: [Date] = []
        var cursor = start
        let limit = end(calendar)
        while cursor < limit {
            starts.append(cursor)
            guard let next = calendar.date(byAdding: step, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return starts
    }
}

struct CashSummary: Equatable {
    var expense: Decimal = 0
    var income: Decimal = 0
    var refund: Decimal = 0
    var discount: Decimal = 0
    var fee: Decimal = 0
    var claimPending: Decimal = 0
    var claimed: Decimal = 0
    var count = 0
    /// Buckets (days or months) that have started.
    var elapsedBuckets = 0

    var balance: Decimal { income - expense }
    var averageExpense: Decimal { elapsedBuckets > 0 ? (expense / Decimal(elapsedBuckets)).rounded(2) : 0 }
    var averageIncome: Decimal { elapsedBuckets > 0 ? (income / Decimal(elapsedBuckets)).rounded(2) : 0 }
    var averageBalance: Decimal { elapsedBuckets > 0 ? (balance / Decimal(elapsedBuckets)).rounded(2) : 0 }
}

struct CashBucket: Identifiable, Equatable {
    let start: Date
    var expense: Decimal = 0
    var income: Decimal = 0
    var id: Date { start }
    var balance: Decimal { income - expense }
}

struct CategoryStat: Identifiable, Equatable {
    let name: String
    let amount: Decimal
    /// Fraction of the period total, 0…1.
    let share: Double
    let count: Int
    /// Change against the previous period (positive = more than before).
    let change: Decimal
    var id: String { name }
}

enum CategoryLevel: String, CaseIterable { case first, second }

enum CashflowAnalytics {

    static func summary(_ entries: [CashEntry], in period: CashPeriod,
                        now: Date = Date(), calendar: Calendar = .current) -> CashSummary {
        var summary = CashSummary()
        for entry in entries where !entry.excluded && period.contains(entry.date, calendar: calendar) {
            switch entry.kind {
            case .expense:
                summary.expense += entry.base
                summary.refund += entry.refund
                summary.claimPending += entry.claimPending
                summary.claimed += entry.claimed
            case .income:
                summary.income += entry.base
            default:
                continue
            }
            summary.discount += entry.discount
            summary.fee += entry.fee
            summary.count += 1
        }
        summary.elapsedBuckets = period.bucketStarts(calendar).filter { $0 <= now }.count
        return summary
    }

    /// One bucket per day (month view) or month (year view), empty ones included.
    static func buckets(_ entries: [CashEntry], in period: CashPeriod,
                        calendar: Calendar = .current) -> [CashBucket] {
        let starts = period.bucketStarts(calendar)
        var buckets = starts.map { CashBucket(start: $0) }
        let positions = Dictionary(uniqueKeysWithValues: starts.enumerated().map { ($1, $0) })
        let components: Set<Calendar.Component> = period.unit == .month ? [.year, .month, .day] : [.year, .month]
        for entry in entries where !entry.excluded && period.contains(entry.date, calendar: calendar) {
            guard let key = calendar.date(from: calendar.dateComponents(components, from: entry.date)),
                  let position = positions[key] else { continue }
            if entry.kind == .expense { buckets[position].expense += entry.base }
            if entry.kind == .income { buckets[position].income += entry.base }
        }
        return buckets
    }

    /// Categories of one kind in a period, largest first, with the change
    /// against the previous period. Level two falls back to the first-level
    /// name for records that have no second level.
    static func categories(_ entries: [CashEntry], kind: TransactionKind, level: CategoryLevel,
                           in period: CashPeriod, calendar: Calendar = .current) -> [CategoryStat] {
        func name(_ entry: CashEntry) -> String {
            let first = entry.category.isEmpty ? "—" : entry.category
            guard level == .second, !entry.subcategory.isEmpty else { return first }
            return entry.subcategory
        }
        let previous = period.shifted(by: -1, calendar: calendar)
        var current: [String: (amount: Decimal, count: Int)] = [:]
        var before: [String: Decimal] = [:]
        for entry in entries where entry.kind == kind && !entry.excluded {
            if period.contains(entry.date, calendar: calendar) {
                let old = current[name(entry)] ?? (0, 0)
                current[name(entry)] = (old.amount + entry.base, old.count + 1)
            } else if previous.contains(entry.date, calendar: calendar) {
                before[name(entry), default: 0] += entry.base
            }
        }
        let total = current.values.reduce(Decimal(0)) { $0 + $1.amount }
        return current.map { key, value in
            CategoryStat(name: key, amount: value.amount,
                         share: total > 0 ? (value.amount / total).doubleValue : 0,
                         count: value.count, change: value.amount - (before[key] ?? 0))
        }
        .sorted { $0.amount == $1.amount ? $0.name < $1.name : $0.amount > $1.amount }
    }

    /// Money moved between own accounts in a period, by the record's label
    /// ("Transfer", "Repayment", "Lend"…).
    static func transfers(_ entries: [CashEntry], in period: CashPeriod,
                          calendar: Calendar = .current) -> [(label: String, amount: Decimal)] {
        var totals: [String: Decimal] = [:]
        for entry in entries where period.contains(entry.date, calendar: calendar) {
            guard entry.kind == .transfer || entry.kind == .liabilityPayment else { continue }
            totals[entry.category.isEmpty ? "Transfer" : entry.category, default: 0] += entry.base
        }
        return totals.map { ($0.key, $0.value) }.sorted { $0.amount > $1.amount }
    }
}

// MARK: - Account balances
//
// A cash account's balance is its opening balance plus every record that
// touched it. A record in another currency is converted to the account's
// currency at the record's date; a transfer with an explicit arrival amount
// uses that amount instead.

struct AccountMovement: Equatable {
    let account: UUID
    let date: Date
    /// Signed, in the account's own currency.
    let delta: Decimal
}

struct LedgerAccount: Equatable {
    let id: UUID
    let currency: String
    let opening: Decimal
    let isLiability: Bool
    let countsInNetWorth: Bool
}

struct NetAssetPoint: Identifiable, Equatable {
    let date: Date
    let assets: Decimal
    let debts: Decimal
    var id: Date { date }
    var net: Decimal { assets - debts }
}

enum AccountLedger {
    static func convert(_ amount: Decimal, from: String, to: String, at date: Date,
                        using converter: CurrencyConverter) -> Decimal {
        if from.uppercased() == to.uppercased() { return amount }
        guard let source = converter.rateToCNY(from, at: date),
              let target = converter.rateToCNY(to, at: date), target != 0 else { return amount }
        return amount * source / target
    }

    /// What one record does to the accounts it names.
    static func movements(kind: TransactionKind, amount: Decimal, refund: Decimal, currency: String,
                          date: Date, source: (id: UUID, currency: String)?,
                          destination: (id: UUID, currency: String)?, arrival: Decimal?,
                          converter: CurrencyConverter) -> [AccountMovement] {
        var result: [AccountMovement] = []
        func inSourceCurrency(_ value: Decimal) -> Decimal {
            guard let source else { return value }
            return convert(value, from: currency, to: source.currency, at: date, using: converter)
        }
        switch kind {
        case .income, .investSell, .adjustment:
            if let source { result.append(.init(account: source.id, date: date, delta: inSourceCurrency(amount))) }
        case .expense, .investBuy:
            if let source {
                result.append(.init(account: source.id, date: date, delta: -inSourceCurrency(amount - refund)))
            }
        case .transfer, .liabilityPayment:
            if source?.id == destination?.id, source != nil { break }
            if let source { result.append(.init(account: source.id, date: date, delta: -inSourceCurrency(amount))) }
            if let destination {
                let arrived = arrival ?? convert(amount, from: currency, to: destination.currency,
                                                 at: date, using: converter)
                result.append(.init(account: destination.id, date: date, delta: arrived))
            }
        }
        return result
    }

    /// Balance of every account at the end of `date`, in its own currency.
    static func balances(accounts: [LedgerAccount], movements: [AccountMovement],
                         at date: Date = .distantFuture) -> [UUID: Decimal] {
        var balances = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.opening) })
        for movement in movements where movement.date <= date {
            balances[movement.account, default: 0] += movement.delta
        }
        return balances
    }

    /// Assets and debts in the display currency. A liability account's
    /// negative balance is debt; a positive balance anywhere is an asset.
    static func netAssets(accounts: [LedgerAccount], balances: [UUID: Decimal],
                          converter: CurrencyConverter, at date: Date = Date()) -> (assets: Decimal, debts: Decimal) {
        var assets: Decimal = 0
        var debts: Decimal = 0
        for account in accounts where account.countsInNetWorth {
            let value = converter.toBase(balances[account.id] ?? 0, account.currency, at: date)
            if value >= 0 { assets += value } else { debts += -value }
        }
        return (assets, debts)
    }

    /// Net assets at the end of each bucket that has started.
    static func trend(accounts: [LedgerAccount], movements: [AccountMovement], period: CashPeriod,
                      converter: CurrencyConverter, now: Date = Date(),
                      calendar: Calendar = .current) -> [NetAssetPoint] {
        let sorted = movements.sorted { $0.date < $1.date }
        var balances = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.opening) })
        var cursor = 0
        var points: [NetAssetPoint] = []
        let starts = period.bucketStarts(calendar)
        for (index, start) in starts.enumerated() where start <= now {
            let end = index + 1 < starts.count ? starts[index + 1] : period.end(calendar)
            while cursor < sorted.count, sorted[cursor].date < end {
                balances[sorted[cursor].account, default: 0] += sorted[cursor].delta
                cursor += 1
            }
            let totals = netAssets(accounts: accounts, balances: balances, converter: converter, at: now)
            points.append(NetAssetPoint(date: start, assets: totals.assets, debts: totals.debts))
        }
        return points
    }
}

// MARK: - Store adapters

extension Transaction {
    func cashEntry(using converter: CurrencyConverter) -> CashEntry {
        func base(_ value: Decimal) -> Decimal { converter.toBase(value, currencyCode, at: date) }
        return CashEntry(id: id, date: date, kind: kind, category: category, subcategory: subcategory,
                         base: base(netAmount),
                         refund: base(refundAmount), discount: base(discountAmount), fee: base(feeAmount),
                         claimPending: claimStatus == .pending ? base(amount - refundAmount) : 0,
                         claimed: claimStatus == .claimed ? base(claimAmount) : 0,
                         excluded: excludeFromStats)
    }

    func movements(using converter: CurrencyConverter) -> [AccountMovement] {
        AccountLedger.movements(
            kind: kind, amount: amount, refund: returnedAmount, currency: currencyCode, date: date,
            source: account.map { ($0.id, $0.currencyCode) },
            destination: transferAccount.map { ($0.id, $0.currencyCode) },
            arrival: transferAmount, converter: converter)
    }
}

extension Account {
    /// Holdings-driven accounts are valued by the portfolio, not the ledger.
    var isLedgerAccount: Bool { kind != .investment && kind != .crypto }

    var ledgerAccount: LedgerAccount {
        LedgerAccount(id: id, currency: currencyCode, opening: openingBalance,
                      isLiability: kind == .liability, countsInNetWorth: includeInNetWorth && !isArchived)
    }
}
