import Foundation
import SwiftData

struct CashEntry: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let kind: TransactionKind
    let category: String
    let subcategory: String
    let base: Decimal
    var refund: Decimal = 0
    var discount: Decimal = 0
    var fee: Decimal = 0
    var claimPending: Decimal = 0
    var claimed: Decimal = 0
    var excluded = false
}

struct CashPeriod: Equatable, Hashable {
    enum Unit: String, CaseIterable { case week, month, year, all, range }

    let unit: Unit
    let start: Date
    let limit: Date

    init(unit: Unit, containing date: Date, calendar: Calendar = .current) {
        self.unit = unit
        let component: Calendar.Component
        switch unit {
        case .week: component = .weekOfYear
        case .year: component = .year
        default: component = .month
        }
        let interval = calendar.dateInterval(of: component, for: date)
        start = interval?.start ?? date
        limit = interval?.end ?? date
    }

    init(from: Date, through to: Date, calendar: Calendar = .current) {
        unit = .range
        let first = calendar.startOfDay(for: min(from, to))
        let last = calendar.startOfDay(for: max(from, to))
        start = first
        limit = calendar.date(byAdding: .day, value: 1, to: last) ?? last
    }

    private init(unit: Unit, start: Date, limit: Date) {
        self.unit = unit
        self.start = start
        self.limit = limit
    }

    static func all(spanning dates: [Date], now: Date = Date(), calendar: Calendar = .current) -> CashPeriod {
        let first = min(dates.min() ?? now, now)
        let last = max(dates.max() ?? now, now)
        let start = calendar.dateInterval(of: .month, for: first)?.start ?? first
        let limit = calendar.dateInterval(of: .month, for: last)?.end ?? last
        return CashPeriod(unit: .all, start: start, limit: limit)
    }

    func end(_ calendar: Calendar = .current) -> Date { limit }

    func dayCount(_ calendar: Calendar = .current) -> Int {
        max(1, calendar.dateComponents([.day], from: start, to: limit).day ?? 1)
    }

    var bucketComponent: Calendar.Component {
        switch unit {
        case .week, .month: return .day
        case .year, .all: return .month
        case .range: return dayCount() > 62 ? .month : .day
        }
    }

    var isShiftable: Bool { unit != .all }

    func shifted(by value: Int, calendar: Calendar = .current) -> CashPeriod {
        switch unit {
        case .all:
            return self
        case .range:
            let days = dayCount(calendar) * value
            let from = calendar.date(byAdding: .day, value: days, to: start) ?? start
            let to = calendar.date(byAdding: .day, value: days - 1, to: limit) ?? limit
            return CashPeriod(from: from, through: to, calendar: calendar)
        case .week, .month, .year:
            let component: Calendar.Component = unit == .week ? .weekOfYear : (unit == .month ? .month : .year)
            return CashPeriod(unit: unit,
                              containing: calendar.date(byAdding: component, value: value, to: start) ?? start,
                              calendar: calendar)
        }
    }

    func previous(_ calendar: Calendar = .current) -> CashPeriod? {
        isShiftable ? shifted(by: -1, calendar: calendar) : nil
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        date >= start && date < limit
    }

    func bucketStarts(_ calendar: Calendar = .current) -> [Date] {
        let step = bucketComponent
        var starts: [Date] = []
        var cursor = step == .month ? (calendar.dateInterval(of: .month, for: start)?.start ?? start) : start
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
    let share: Double
    let count: Int
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

    static func buckets(_ entries: [CashEntry], in period: CashPeriod,
                        calendar: Calendar = .current) -> [CashBucket] {
        let starts = period.bucketStarts(calendar)
        var buckets = starts.map { CashBucket(start: $0) }
        let positions = Dictionary(uniqueKeysWithValues: starts.enumerated().map { ($1, $0) })
        let components: Set<Calendar.Component> = period.bucketComponent == .day
            ? [.year, .month, .day] : [.year, .month]
        for entry in entries where !entry.excluded && period.contains(entry.date, calendar: calendar) {
            guard let key = calendar.date(from: calendar.dateComponents(components, from: entry.date)),
                  let position = positions[key] else { continue }
            if entry.kind == .expense { buckets[position].expense += entry.base }
            if entry.kind == .income { buckets[position].income += entry.base }
        }
        return buckets
    }

    static func categories(_ entries: [CashEntry], kind: TransactionKind, level: CategoryLevel,
                           in period: CashPeriod, calendar: Calendar = .current) -> [CategoryStat] {
        func name(_ entry: CashEntry) -> String {
            let first = entry.category.isEmpty ? "—" : entry.category
            guard level == .second, !entry.subcategory.isEmpty else { return first }
            return entry.subcategory
        }
        let previous = period.previous(calendar)
        var current: [String: (amount: Decimal, count: Int)] = [:]
        var before: [String: Decimal] = [:]
        for entry in entries where entry.kind == kind && !entry.excluded {
            if period.contains(entry.date, calendar: calendar) {
                let old = current[name(entry)] ?? (0, 0)
                current[name(entry)] = (old.amount + entry.base, old.count + 1)
            } else if previous?.contains(entry.date, calendar: calendar) == true {
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

struct AccountMovement: Equatable {
    let account: UUID
    let date: Date
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

    static func balances(accounts: [LedgerAccount], movements: [AccountMovement],
                         at date: Date = .distantFuture) -> [UUID: Decimal] {
        var balances = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.opening) })
        for movement in movements where movement.date <= date {
            balances[movement.account, default: 0] += movement.delta
        }
        return balances
    }

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

extension Transaction {
    var canBeExcluded: Bool { kind == .expense || kind == .income }

    var excludeActionTitle: String {
        switch (kind, excludeFromStats) {
        case (.income, false): return tr("Exclude from income")
        case (.income, true): return tr("Count in income")
        case (_, false): return tr("Exclude from expense")
        case (_, true): return tr("Count in expense")
        }
    }

    func toggleExcluded(in context: ModelContext) {
        excludeFromStats.toggle()
        updatedAt = Date()
        try? context.save()
    }
}

extension Account {
    var isLedgerAccount: Bool { kind != .investment && kind != .crypto }

    var ledgerAccount: LedgerAccount {
        LedgerAccount(id: id, currency: currencyCode, opening: openingBalance,
                      isLiability: kind == .liability, countsInNetWorth: includeInNetWorth && !isArchived)
    }
}
