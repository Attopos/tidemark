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
    /// Text, lines and bars: deeper shades in light mode so they read on white.
    static let expense = Color(light: 0x7458E0, dark: 0xA98BFA)
    static let income = Color(light: 0x6B8E12, dark: 0xD5F56B)
    private static let expenseRamp = [expense, DS.violetSoft, DS.violetDeep, DS.violetDark]
    private static let incomeRamp = [income, Color(light: 0xB9D95A, dark: 0xE9FAB0), DS.limeDeep]

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
        // The "Today" shortcut is the first thing to go when space is short.
        ViewThatFits(in: .horizontal) {
            bar(withToday: true)
            bar(withToday: false)
        }
    }

    private func bar(withToday: Bool) -> some View {
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
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 88)
            arrow("chevron.right") { period = period.shifted(by: 1) }
            if withToday {
                Button(tr("Today")) { period = CashPeriod(unit: period.unit, containing: Date()) }
                    .buttonStyle(GhostButtonStyle())
            }
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
    /// Nil shows the privacy mask.
    let value: Decimal?
    let code: String
    /// Label and formatted figure.
    let details: [(String, String)]

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.textSecondary)
                Text(value.map { Fmt.money($0, code) } ?? Fmt.privacyMask)
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
    /// Line instead of bars (remembered).
    @AppStorage("statisticsAsLine") private var asLine = false

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
            Button { asLine.toggle() } label: {
                Image(systemName: asLine ? "chart.bar" : "chart.xyaxis.line")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(DS.tile)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(asLine ? tr("Show as bars") : tr("Show as a line"))
        }) {
            VStack(spacing: 10) {
                Text(focusLabel)
                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(DS.tile)
                    .clipShape(Capsule())
                Chart {
                    ForEach(buckets) { bucket in
                        if asLine {
                            // Days still to come are left off the line.
                            if bucket.start <= Date() {
                                AreaMark(x: .value("Date", bucket.start, unit: unit),
                                         y: .value("Amount", value(bucket).doubleValue))
                                    .foregroundStyle(color(1).opacity(0.15))
                                    .interpolationMethod(.monotone)
                                LineMark(x: .value("Date", bucket.start, unit: unit),
                                         y: .value("Amount", value(bucket).doubleValue),
                                         series: .value("Part", "past"))
                                    .foregroundStyle(color(1))
                                    .lineStyle(StrokeStyle(lineWidth: 2))
                                    .interpolationMethod(.monotone)
                            }
                            if bucket.start > Date() {
                                LineMark(x: .value("Date", bucket.start, unit: unit), y: .value("Amount", 0),
                                         series: .value("Part", "ahead"))
                                    .foregroundStyle(color(1))
                                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            }
                            if focus?.start == bucket.start {
                                PointMark(x: .value("Date", bucket.start, unit: unit),
                                          y: .value("Amount", value(bucket).doubleValue))
                                    .foregroundStyle(color(1))
                            }
                        } else {
                            BarMark(x: .value("Date", bucket.start, unit: unit),
                                    y: .value("Amount", value(bucket).doubleValue))
                                .foregroundStyle(color(value(bucket)))
                                .cornerRadius(3)
                                .opacity(focus == nil || focus?.start == bucket.start ? 1 : 0.55)
                        }
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
                CapsuleSwitch(options: FlowMode.allCases, selection: $mode, compact: true) { $0.label }
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
        // Days still to come: the last value, carried flat and dashed.
        let ahead: [(Date, Double)] = {
            guard let last = points.last else { return [] }
            return period.bucketStarts().filter { $0 >= last.date }.map { ($0, value(last).doubleValue) }
        }()
        Panel(title: tr("Cash net assets")) {
            VStack(spacing: 10) {
                if let focus {
                    Text("\(Fmt.dateShort.string(from: focus.date))  \(Fmt.money(value(focus), code))")
                        .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(DS.tile)
                        .clipShape(Capsule())
                }
                Chart {
                    // A solid area and line for what happened; the days still
                    // to come carry the last value as a flat dashed line.
                    ForEach(points) { point in
                        AreaMark(x: .value("Date", point.date), y: .value("Value", value(point).doubleValue))
                            .foregroundStyle(color.opacity(0.18))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", point.date), y: .value("Value", value(point).doubleValue))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                    }
                    if let last = points.last, let end = ahead.last?.0, end > last.date {
                        RectangleMark(xStart: .value("Date", last.date), xEnd: .value("Date", end),
                                      yStart: .value("Base", 0), yEnd: .value("Value", value(last).doubleValue))
                            .foregroundStyle(color.opacity(0.08))
                        RuleMark(xStart: .value("Date", last.date), xEnd: .value("Date", end),
                                 y: .value("Value", value(last).doubleValue))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                    if let focus {
                        PointMark(x: .value("Date", focus.date), y: .value("Value", value(focus).doubleValue))
                            .symbol(Circle().strokeBorder(lineWidth: 2))
                            .symbolSize(60)
                            .foregroundStyle(color)
                    }
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
                                       ? .dateTime.month(.defaultDigits).day() : .dateTime.month(.abbreviated))
                            .font(.system(size: 10.5))
                            .foregroundStyle(DS.textTertiary)
                    }
                }
                .frame(height: 170)
                CapsuleSwitch(options: Series.allCases, selection: $series, compact: true) {
                    switch $0 {
                    case .net: return tr("Net")
                    case .assets: return tr("Assets")
                    case .debts: return tr("Debts")
                    }
                }
            }
        }
    }
}

// MARK: - Categories

struct CategoryPanel: View {
    let entries: [CashEntry]
    let period: CashPeriod
    let code: String

    /// Category whose detail sheet is open.
    @State private var selection: CategorySelection?
    @State private var kind: TransactionKind = .expense
    @State private var level: CategoryLevel = .first
    @State private var expanded = false
    /// Row under the pointer; highlights its slice.
    @State private var hovered: String?

    private static let collapsedCount = 10

    private var stats: [CategoryStat] {
        CashflowAnalytics.categories(entries, kind: kind, level: level, in: period)
    }

    var body: some View {
        let stats = self.stats
        let total = stats.reduce(Decimal(0)) { $0 + $1.amount }
        Panel(title: tr("Categories")) {
            HStack(spacing: 8) {
                CapsuleSwitch(options: [TransactionKind.expense, .income], selection: $kind) { $0.displayName }
                Spacer(minLength: 4)
                CapsuleSwitch(options: CategoryLevel.allCases, selection: $level) {
                    $0 == .first ? tr("Level 1") : tr("Level 2")
                }
            }
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
        .sheet(item: $selection) { CategoryDetailSheet(selection: $0, period: period, code: code) }
    }

    private func donut(_ stats: [CategoryStat], total: Decimal) -> some View {
        ZStack {
            Chart(Array(stats.enumerated()), id: \.element.id) { rank, stat in
                SectorMark(angle: .value("Amount", stat.amount.doubleValue),
                           innerRadius: .ratio(0.68), angularInset: 1.2)
                    .foregroundStyle(FlowPalette.color(kind: kind, rank: rank))
                    .cornerRadius(3)
                    .opacity(hovered == nil || hovered == stat.name ? 1 : 0.35)
            }
            .chartLegend(.hidden)
            VStack(spacing: 3) {
                Text(hovered.map(CategoryName.label) ?? kind.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                Text(Fmt.money(stats.first { $0.name == hovered }?.amount ?? total, code))
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
        let selected = hovered == stat.name
        let color = FlowPalette.color(kind: kind, rank: rank)
        return Button {
            selection = CategorySelection(name: stat.name, level: level, kind: kind)
        } label: {
            HStack(spacing: 10) {
            CategoryIcon(name: stat.name, kind: kind, size: 34)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(CategoryName.label(stat.name))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.textPrimary)
                        .lineLimit(1)
                    Text(Fmt.percent(stat.share, decimals: 2, showSign: false))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(DS.textSecondary)
                    Spacer(minLength: 6)
                    Text(Fmt.money(stat.amount, code))
                        .font(DS.money(14, weight: .semibold))
                        .foregroundStyle(DS.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
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
                    // Change against the previous period, then the record count.
                    Text((stat.change == 0 ? "" : "\(stat.change > 0 ? "▲" : "▼") \(Fmt.money(abs(stat.change), code)) · ")
                         + "\(stat.count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(DS.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? DS.tile : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? stat.name : (hovered == stat.name ? nil : hovered) }
    }
}

struct CategorySelection: Equatable, Identifiable {
    var id: String { "\(kind.rawValue)|\(level.rawValue)|\(name)" }
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

    private var categoryName: String {
        if !transaction.subcategory.isEmpty { return transaction.subcategory }
        if !transaction.category.isEmpty { return transaction.category }
        return transaction.kind.displayName
    }

    private var title: String { CategoryName.label(categoryName) }

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
        let net = transaction.netAmount
        switch transaction.kind {
        case .expense: return Fmt.money(-net, transaction.currencyCode)
        case .income: return Fmt.money(net, transaction.currencyCode, showSign: true)
        default: return Fmt.money(net, transaction.currencyCode)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(name: categoryName, kind: transaction.kind, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.textPrimary)
                        .lineLimit(1)
                    if transaction.claimStatus != .none {
                        TagChip(text: transaction.claimStatus.displayName,
                                color: transaction.claimStatus == .pending ? DS.warning : DS.textSecondary)
                    }
                }
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
                    .fixedSize()
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
                        .onOpenGesture { editing = transaction }
                        .contextMenu {
                            Button(tr("Edit…")) { editing = transaction }
                            if transaction.claimStatus == .pending {
                                Button(tr("Mark as claimed")) {
                                    transaction.claimAmount = transaction.amount - transaction.refundAmount
                                    transaction.claimStatus = .claimed
                                    transaction.updatedAt = Date()
                                    try? context.save()
                                }
                            } else if transaction.kind == .expense && transaction.claimStatus == .none {
                                Button(tr("Mark as reimbursable")) {
                                    transaction.claimStatus = .pending
                                    transaction.updatedAt = Date()
                                    try? context.save()
                                }
                            }
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

// MARK: - Category detail

/// One category over time: this period's total, the last twelve periods,
/// its second-level split, and its records.
struct CategoryDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var rates: [CurrencyRate]

    let selection: CategorySelection
    let period: CashPeriod
    let code: String

    @State private var editing: Transaction?

    var body: some View {
        let converter = CurrencyConverter(rates: rates, base: code)
        let matching = transactions.filter { selection.matches($0) && !$0.excludeFromStats }
        let inPeriod = matching.filter { period.contains($0.date) }
        let entries = matching.map { $0.cashEntry(using: converter) }
        let total = entries.filter { period.contains($0.date) }.reduce(Decimal(0)) { $0 + $1.base }
        let history = (0..<12).reversed().map { offset -> (Date, Decimal) in
            let slice = period.shifted(by: -offset)
            return (slice.start, entries.filter { slice.contains($0.date) }.reduce(Decimal(0)) { $0 + $1.base })
        }
        let subcategories: [CategoryStat] = selection.level == .first
            ? CashflowAnalytics.categories(entries, kind: selection.kind, level: .second, in: period)
                .filter { $0.name != selection.name }
            : []

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                CategoryIcon(name: selection.name, kind: selection.kind, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(CategoryName.label(selection.name))
                        .font(DS.title(20))
                        .foregroundStyle(DS.textPrimary)
                    Text("\(Fmt.money(total, code)) · \(trf("%d records", inPeriod.count))")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(DS.textSecondary)
                }
                Spacer()
                Button(tr("Done")) { dismiss() }
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            Chart(history, id: \.0) { start, amount in
                BarMark(x: .value("Date", start, unit: period.unit == .month ? .month : .year),
                        y: .value("Amount", amount.doubleValue))
                    .foregroundStyle(selection.kind == .income ? FlowPalette.income : FlowPalette.expense)
                    .cornerRadius(3)
                    .opacity(start == period.start ? 1 : 0.55)
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(DS.border.opacity(0.6))
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(Fmt.moneyCompact(Decimal(amount), code)).font(.system(size: 10.5))
                                .foregroundStyle(DS.textTertiary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisValueLabel(format: period.unit == .month ? .dateTime.month(.abbreviated) : .dateTime.year())
                        .font(.system(size: 10.5)).foregroundStyle(DS.textTertiary)
                }
            }
            .frame(height: 140)
            if !subcategories.isEmpty {
                VStack(spacing: 6) {
                    ForEach(subcategories) { stat in
                        HStack(spacing: 10) {
                            CategoryIcon(name: stat.name, kind: selection.kind, size: 26)
                            Text(CategoryName.label(stat.name))
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(DS.textPrimary)
                                .lineLimit(1)
                            Text(Fmt.percent(stat.share, decimals: 1, showSign: false))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(DS.textSecondary)
                            Spacer()
                            Text(Fmt.money(stat.amount, code))
                                .font(DS.money(13.5, weight: .semibold))
                                .foregroundStyle(DS.textPrimary)
                        }
                    }
                }
                .padding(12)
                .background(DS.tile)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            ScrollView {
                RecordList(transactions: inPeriod, showsDate: true, editing: $editing)
            }
            .frame(minHeight: 200)
        }
        .editorSheet(width: 560)
        .sheet(item: $editing) { TransactionEditor(transaction: $0) }
    }
}
