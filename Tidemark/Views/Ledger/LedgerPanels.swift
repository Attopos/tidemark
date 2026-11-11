import SwiftUI
import SwiftData
import Charts

// MARK: - Shared ledger data
//
// Everything the Ledger, Accounts and Analysis pages draw comes from one
// snapshot built per render: records reduced to statistics entries, account
// movements, and the converter for the display currency.

struct LedgerSnapshot {
    let code: String
    let converter: CurrencyConverter
    let transactions: [Transaction]
    let entries: [CashEntry]
    let accounts: [Account]
    let ledgerAccounts: [LedgerAccount]
    let movements: [AccountMovement]
    let balances: [UUID: Decimal]

    init(transactions: [Transaction], accounts: [Account], rates: [CurrencyRate], code: String) {
        let converter = CurrencyConverter(rates: rates, base: code)
        let ledger = accounts.filter(\.isLedgerAccount)
        let ledgerIDs = Set(ledger.map(\.id))
        let ledgerAccounts = ledger.map(\.ledgerAccount)
        let movements = transactions.flatMap { $0.movements(using: converter) }
            .filter { ledgerIDs.contains($0.account) }
        self.code = code
        self.converter = converter
        self.transactions = transactions
        self.entries = transactions.map { $0.cashEntry(using: converter) }
        self.accounts = ledger
        self.ledgerAccounts = ledgerAccounts
        self.movements = movements
        self.balances = AccountLedger.balances(accounts: ledgerAccounts, movements: movements)
    }

    var netAssets: (assets: Decimal, debts: Decimal) {
        AccountLedger.netAssets(accounts: ledgerAccounts, balances: balances, converter: converter)
    }
}

/// Meaning of color on the cash-flow pages: violet is money going out,
/// lime is money coming in. Shades rank categories inside one family.
enum FlowPalette {
    static let expense = DS.violet
    static let income = DS.lime
    private static let expenseRamp = [DS.violet, DS.violetSoft, DS.violetDeep, DS.violetDark]
    private static let incomeRamp = [DS.lime, DS.limeSoft, DS.limeDeep]

    static func color(kind: TransactionKind, rank: Int) -> Color {
        let ramp = kind == .income ? incomeRamp : expenseRamp
        if rank < ramp.count { return ramp[rank] }
        return ramp[ramp.count - 1].opacity(max(0.25, 0.75 - Double(rank - ramp.count) * 0.12))
    }

    static func amountColor(_ kind: TransactionKind) -> Color {
        switch kind {
        case .income: return income
        case .expense: return DS.textPrimary
        default: return DS.textSecondary
        }
    }
}

enum FlowMode: String, CaseIterable {
    case expense, income, balance

    var label: String {
        switch self {
        case .expense: return tr("Expense")
        case .income: return tr("Income")
        case .balance: return tr("Balance")
        }
    }
}

// MARK: - Period bar

struct PeriodBar: View {
    @Binding var period: CashPeriod

    private var title: String {
        let formatter = DateFormatter()
        formatter.locale = L10n.current.locale
        formatter.setLocalizedDateFormatFromTemplate(period.unit == .month ? "yMMM" : "y")
        return formatter.string(from: period.start)
    }

    var body: some View {
        HStack(spacing: 10) {
            CapsuleSwitch(options: CashPeriod.Unit.allCases, selection: Binding(
                get: { period.unit },
                set: { period = CashPeriod(unit: $0, containing: period.start) })) {
                $0 == .month ? tr("Month") : tr("Year")
            }
            arrow("chevron.left") { period = period.shifted(by: -1) }
            Text(title)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(DS.textPrimary)
                .frame(minWidth: 96)
            arrow("chevron.right") { period = period.shifted(by: 1) }
            Button(tr("Today")) { period = CashPeriod(unit: period.unit, containing: Date()) }
                .buttonStyle(GhostButtonStyle())
        }
    }

    private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(DS.textPrimary)
                .frame(width: 28, height: 28)
                .background(DS.tile)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Small figures

struct StatTile: View {
    let title: String
    let value: Decimal
    let code: String
    var color: Color = DS.textPrimary
    var signed = false
    /// Plain number instead of money (a count).
    var isCount = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
            Text(isCount ? "\(NSDecimalNumber(decimal: value).intValue)" : Fmt.money(value, code, showSign: signed))
                .font(DS.money(17, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.tile)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct HeroFigure: View {
    let title: String
    let value: Decimal
    let code: String
    /// Label and formatted figure.
    let details: [(String, String)]

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.textSecondary)
                Text(Fmt.money(value, code))
                    .font(DS.money(28, weight: .bold))
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                HStack(spacing: 16) {
                    ForEach(details, id: \.0) { label, figure in
                        HStack(spacing: 5) {
                            Text(label).foregroundStyle(DS.textTertiary)
                            Text(figure).foregroundStyle(DS.textSecondary)
                        }
                        .font(.system(size: 12.5).monospacedDigit())
                        .lineLimit(1)
                    }
                }
            }
        }
    }
}

// MARK: - Expense / income bars

struct FlowBarsPanel: View {
    let buckets: [CashBucket]
    let summary: CashSummary
    let period: CashPeriod
    let code: String
    /// Day picked in the calendar; highlighted when nothing is hovered.
    var selectedDay: Date?

    @State private var mode: FlowMode = .expense
    @State private var hovered: Date?

    private func value(_ bucket: CashBucket) -> Decimal {
        switch mode {
        case .expense: return bucket.expense
        case .income: return bucket.income
        case .balance: return bucket.balance
        }
    }

    private var average: Decimal {
        switch mode {
        case .expense: return summary.averageExpense
        case .income: return summary.averageIncome
        case .balance: return summary.averageBalance
        }
    }

    private func color(_ amount: Decimal) -> Color {
        switch mode {
        case .expense: return FlowPalette.expense
        case .income: return FlowPalette.income
        case .balance: return amount >= 0 ? FlowPalette.income : FlowPalette.expense
        }
    }

    private var unit: Calendar.Component { period.unit == .month ? .day : .month }

    private var focus: CashBucket? {
        let target = hovered ?? selectedDay
        return buckets.first { bucket in
            guard let target else { return false }
            return Calendar.current.isDate(bucket.start, equalTo: target, toGranularity: unit)
        }
    }

    private var focusLabel: String {
        guard let focus else {
            return "\(tr("Average")) \(Fmt.money(average, code))"
        }
        let formatter = DateFormatter()
        formatter.locale = L10n.current.locale
        formatter.setLocalizedDateFormatFromTemplate(period.unit == .month ? "MMMd" : "yMMM")
        return "\(formatter.string(from: focus.start))  \(Fmt.money(value(focus), code))"
    }

    var body: some View {
        Panel(title: tr("Statistics"), accessory: {
            CapsuleSwitch(options: FlowMode.allCases, selection: $mode) { $0.label }
        }) {
            VStack(alignment: .leading, spacing: 10) {
                Text(focusLabel)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(DS.textSecondary)
                Chart {
                    ForEach(buckets) { bucket in
                        BarMark(x: .value("Date", bucket.start, unit: unit),
                                y: .value("Amount", value(bucket).doubleValue))
                            .foregroundStyle(color(value(bucket)))
                            .cornerRadius(3)
                            .opacity(focus == nil || focus?.start == bucket.start ? 1 : 0.55)
                    }
                    if average != 0 {
                        RuleMark(y: .value("Average", average.doubleValue))
                            .foregroundStyle(DS.textTertiary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartXSelection(value: $hovered)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(DS.border.opacity(0.6))
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(Fmt.moneyCompact(Decimal(amount), code))
                                    .font(.system(size: 10.5).monospacedDigit())
                                    .foregroundStyle(DS.textTertiary)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisValueLabel(format: period.unit == .month
                                       ? .dateTime.day() : .dateTime.month(.abbreviated))
                            .font(.system(size: 10.5))
                            .foregroundStyle(DS.textTertiary)
                    }
                }
                .frame(height: 190)
            }
        }
    }
}

// MARK: - Net assets trend

struct NetTrendPanel: View {
    enum Series: String, CaseIterable { case net, assets, debts }

    let points: [NetAssetPoint]
    let period: CashPeriod
    let code: String
    @State private var series: Series = .net
    @State private var hovered: Date?

    private func value(_ point: NetAssetPoint) -> Decimal {
        switch series {
        case .net: return point.net
        case .assets: return point.assets
        case .debts: return point.debts
        }
    }

    private var color: Color { series == .debts ? FlowPalette.expense : FlowPalette.income }

    private var focus: NetAssetPoint? {
        guard let hovered else { return points.last }
        return points.last { $0.date <= hovered } ?? points.first
    }

    var body: some View {
        Panel(title: tr("Cash net assets"), accessory: {
            CapsuleSwitch(options: Series.allCases, selection: $series) {
                switch $0 {
                case .net: return tr("Net")
                case .assets: return tr("Assets")
                case .debts: return tr("Debts")
                }
            }
        }) {
            VStack(alignment: .leading, spacing: 10) {
                if let focus {
                    Text("\(Fmt.dateShort.string(from: focus.date))  \(Fmt.money(value(focus), code))")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(DS.textSecondary)
                }
                Chart(points) { point in
                    AreaMark(x: .value("Date", point.date), y: .value("Value", value(point).doubleValue))
                        .foregroundStyle(color.opacity(0.18))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", point.date), y: .value("Value", value(point).doubleValue))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
                .chartXSelection(value: $hovered)
                .chartXScale(domain: period.start...period.end())
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(DS.border.opacity(0.6))
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(Fmt.moneyCompact(Decimal(amount), code))
                                    .font(.system(size: 10.5).monospacedDigit())
                                    .foregroundStyle(DS.textTertiary)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisValueLabel(format: period.unit == .month
                                       ? .dateTime.day() : .dateTime.month(.abbreviated))
                            .font(.system(size: 10.5))
                            .foregroundStyle(DS.textTertiary)
                    }
                }
                .frame(height: 170)
            }
        }
    }
}

// MARK: - Categories

struct CategoryPanel: View {
    let entries: [CashEntry]
    let period: CashPeriod
    let code: String
    /// Selected category name and the level it belongs to.
    @Binding var selection: CategorySelection?

    @State private var kind: TransactionKind = .expense
    @State private var level: CategoryLevel = .first
    @State private var expanded = false

    private static let collapsedCount = 10

    private var stats: [CategoryStat] {
        CashflowAnalytics.categories(entries, kind: kind, level: level, in: period)
    }

    var body: some View {
        let stats = self.stats
        let total = stats.reduce(Decimal(0)) { $0 + $1.amount }
        Panel(title: tr("Categories"), accessory: {
            HStack(spacing: 8) {
                CapsuleSwitch(options: CategoryLevel.allCases, selection: $level) {
                    $0 == .first ? tr("Level 1") : tr("Level 2")
                }
                CapsuleSwitch(options: [TransactionKind.expense, .income], selection: $kind) { $0.displayName }
            }
        }) {
            if stats.isEmpty {
                Text(tr("No records in this period"))
                    .font(DS.caption)
                    .foregroundStyle(DS.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 16) {
                    donut(stats, total: total)
                    VStack(spacing: 4) {
                        ForEach(Array(stats.enumerated()), id: \.element.id) { rank, stat in
                            if expanded || rank < Self.collapsedCount {
                                row(stat, rank: rank)
                            }
                        }
                    }
                    if stats.count > Self.collapsedCount {
                        Button(expanded ? tr("Show less") : trf("Show all %d", stats.count)) { expanded.toggle() }
                            .buttonStyle(GhostButtonStyle())
                    }
                }
            }
        }
        .onChange(of: kind) { _, _ in selection = nil }
        .onChange(of: level) { _, _ in selection = nil }
    }

    private func donut(_ stats: [CategoryStat], total: Decimal) -> some View {
        ZStack {
            Chart(Array(stats.enumerated()), id: \.element.id) { rank, stat in
                SectorMark(angle: .value("Amount", stat.amount.doubleValue),
                           innerRadius: .ratio(0.68), angularInset: 1.2)
                    .foregroundStyle(FlowPalette.color(kind: kind, rank: rank))
                    .cornerRadius(3)
                    .opacity(selection == nil || selection?.name == stat.name ? 1 : 0.35)
            }
            .chartLegend(.hidden)
            VStack(spacing: 3) {
                Text(selection?.name ?? kind.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                Text(Fmt.money(stats.first { $0.name == selection?.name }?.amount ?? total, code))
                    .font(DS.money(17, weight: .bold))
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(width: 118)
        }
        .frame(height: 190)
    }

    private func row(_ stat: CategoryStat, rank: Int) -> some View {
        let selected = selection?.name == stat.name
        let color = FlowPalette.color(kind: kind, rank: rank)
        return Button {
            selection = selected ? nil : CategorySelection(name: stat.name, level: level, kind: kind)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(stat.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.textPrimary)
                        .lineLimit(1)
                    Text(Fmt.percent(stat.share, decimals: 2, showSign: false))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(DS.textSecondary)
                    Spacer(minLength: 6)
                    if stat.change != 0 {
                        // Against the previous period; more spending is not "good".
                        Text("\(stat.change > 0 ? "▲" : "▼") \(Fmt.money(abs(stat.change), code))")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(DS.textTertiary)
                    }
                    Text(Fmt.money(stat.amount, code))
                        .font(DS.money(14, weight: .semibold))
                        .foregroundStyle(DS.textPrimary)
                }
                HStack(spacing: 8) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.tile)
                            Capsule().fill(color)
                                .frame(width: max(2, geometry.size.width * stat.share))
                        }
                    }
                    .frame(height: 4)
                    Text("\(stat.count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(DS.textTertiary)
                        .frame(minWidth: 18, alignment: .trailing)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? DS.tile : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CategorySelection: Equatable {
    let name: String
    let level: CategoryLevel
    let kind: TransactionKind

    func matches(_ transaction: Transaction) -> Bool {
        guard transaction.kind == kind else { return false }
        let first = transaction.category.isEmpty ? "—" : transaction.category
        switch level {
        case .first: return first == name
        case .second: return (transaction.subcategory.isEmpty ? first : transaction.subcategory) == name
        }
    }
}

// MARK: - Record rows

struct RecordRow: View {
    let transaction: Transaction
    var showsDate = false

    private var title: String {
        if !transaction.subcategory.isEmpty { return transaction.subcategory }
        if !transaction.category.isEmpty { return transaction.category }
        return transaction.kind.displayName
    }

    private var subtitle: String {
        let time = showsDate ? Fmt.dateTime.string(from: transaction.date)
                             : transaction.date.formatted(date: .omitted, time: .shortened)
        let note = transaction.note.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? time : "\(time) · \(note)"
    }

    private var accountText: String {
        let from = transaction.account?.name ?? ""
        guard let to = transaction.transferAccount?.name else { return from }
        return from.isEmpty ? "→ \(to)" : "\(from) → \(to)"
    }

    private var amountText: String {
        let net = transaction.kind == .expense ? transaction.amount - transaction.refundAmount : transaction.amount
        switch transaction.kind {
        case .expense: return Fmt.money(-net, transaction.currencyCode)
        case .income: return Fmt.money(net, transaction.currencyCode, showSign: true)
        default: return Fmt.money(net, transaction.currencyCode)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transaction.kind.icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(transaction.kind == .income ? DS.ink : DS.textPrimary)
                .frame(width: 30, height: 30)
                .background(transaction.kind == .income ? FlowPalette.income : DS.tile)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(amountText)
                    .font(DS.money(14, weight: .semibold))
                    .foregroundStyle(FlowPalette.amountColor(transaction.kind))
                    .lineLimit(1)
                Text(accountText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

/// A list of records with edit and delete, used by every page.
struct RecordList: View {
    @Environment(\.modelContext) private var context
    let transactions: [Transaction]
    var showsDate = false
    var limit = 200
    @Binding var editing: Transaction?

    var body: some View {
        if transactions.isEmpty {
            Text(tr("No records"))
                .font(DS.caption)
                .foregroundStyle(DS.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 70)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(transactions.prefix(limit)) { transaction in
                    RecordRow(transaction: transaction, showsDate: showsDate)
                        .onTapGesture(count: 2) { editing = transaction }
                        .contextMenu {
                            Button(tr("Edit…")) { editing = transaction }
                            Button(tr("Delete"), role: .destructive) {
                                context.delete(transaction)
                                try? context.save()
                            }
                        }
                    Divider().overlay(DS.border.opacity(0.5))
                }
                if transactions.count > limit {
                    Text(trf("Showing the first %d of %d", limit, transactions.count))
                        .font(.system(size: 12))
                        .foregroundStyle(DS.textTertiary)
                        .padding(.top, 8)
                }
            }
        }
    }
}
