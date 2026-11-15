import SwiftUI
import SwiftData
import Charts

// MARK: - Analysis (iPhone)
//
// One column of stacked cards under a full-width period switcher: totals,
// the daily (or monthly) statistics, categories, the net assets trend and
// the summary table.

struct PhoneAnalysisView: View {
    @Environment(AppState.self) private var app
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var accounts: [Account]
    @Query private var rates: [CurrencyRate]

    @State private var editingRange = false
    @State private var records: PhoneRecordsSelection?

    private var allPeriod: CashPeriod {
        .all(spanning: [transactions.last?.date, transactions.first?.date].compactMap { $0 })
    }

    private var period: CashPeriod {
        app.cashPeriod.unit == .all ? allPeriod : app.cashPeriod
    }

    var body: some View {
        @Bindable var app = app
        let period = self.period
        let snapshot = LedgerSnapshot(transactions: transactions, accounts: accounts, rates: rates,
                                      code: app.baseCurrency)
        let code = snapshot.code
        let summary = CashflowAnalytics.summary(snapshot.entries, in: period)
        let buckets = CashflowAnalytics.buckets(snapshot.entries, in: period)
        let trend = AccountLedger.trend(accounts: snapshot.ledgerAccounts, movements: snapshot.movements,
                                        period: period, converter: snapshot.converter)
        let transfers = CashflowAnalytics.transfers(snapshot.entries, in: period)

        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    PhonePeriodSwitcher(selected: period.unit) { select($0, from: period) }
                    navigator(period)
                    PhoneOverviewCard(summary: summary, period: period, code: code) { title, kinds in
                        records = PhoneRecordsSelection(title: title, kinds: kinds, period: period)
                    }
                    PhoneStatisticsCard(buckets: buckets, summary: summary, period: period, code: code)
                    PhoneCategoriesCard(entries: snapshot.entries, period: period, code: code)
                    PhoneNetTrendCard(points: trend, period: period, code: code)
                    PhoneSummaryCard(buckets: buckets, summary: summary, period: period, code: code)
                    if !transfers.isEmpty {
                        PhoneCard(title: tr("Between accounts"), icon: "arrow.left.arrow.right") {
                            LazyVGrid(columns: PhoneCard<EmptyView, EmptyView>.twoColumns, spacing: 10) {
                                ForEach(transfers, id: \.label) { item in
                                    StatTile(title: tr(item.label), value: item.amount, code: code)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.phoneMargin)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .background(DS.page)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(tr("Analysis"))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(DS.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { app.amountsHidden.toggle() } label: {
                        Image(systemName: app.amountsHidden ? "eye.slash" : "eye")
                    }
                    .tint(DS.textPrimary)
                }
            }
        }
        .sheet(isPresented: $editingRange) {
            PhoneRangeSheet(period: period) { app.cashPeriod = $0 }
        }
        .sheet(item: $records) { PhoneRecordsSheet(selection: $0) }
    }

    private func select(_ unit: CashPeriod.Unit, from current: CashPeriod) {
        switch unit {
        case .range:
            editingRange = true
        case .all:
            app.cashPeriod = allPeriod
        case .week, .month, .year:
            let anchor = current.contains(Date()) ? Date() : current.start
            app.cashPeriod = CashPeriod(unit: unit, containing: anchor)
        }
    }

    private func navigator(_ period: CashPeriod) -> some View {
        HStack {
            arrow("arrow.left", enabled: period.isShiftable) { app.cashPeriod = period.shifted(by: -1) }
            Spacer(minLength: 8)
            Button {
                switch period.unit {
                case .range: editingRange = true
                case .all: break
                case .week, .month, .year: app.cashPeriod = CashPeriod(unit: period.unit, containing: Date())
                }
            } label: {
                Text(period.title)
                    .font(.system(size: 18, weight: .medium).monospacedDigit())
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            arrow("arrow.right", enabled: period.isShiftable) { app.cashPeriod = period.shifted(by: 1) }
        }
        .padding(.horizontal, 2)
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(DS.ink)
                .frame(width: 34, height: 34)
                .background(DS.accent)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.25)
    }
}

// MARK: - Period switcher

struct PhonePeriodSwitcher: View {
    let selected: CashPeriod.Unit
    let select: (CashPeriod.Unit) -> Void
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CashPeriod.Unit.allCases, id: \.self) { unit in
                let on = unit == selected
                Button { select(unit) } label: {
                    Text(unit.title)
                        .font(.system(size: 16, weight: on ? .bold : .medium))
                        .foregroundStyle(on ? DS.ink : DS.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background {
                            if on { Capsule().fill(DS.accent).matchedGeometryEffect(id: "pill", in: pill) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(DS.tile)
        .clipShape(Capsule())
        .animation(.snappy(duration: 0.25), value: selected)
    }
}

// MARK: - Card

struct PhoneCard<Accessory: View, Content: View>: View {
    static var twoColumns: [GridItem] { [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)] }

    let title: String
    let icon: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DS.ink)
                    .frame(width: 24, height: 24)
                    .background(DS.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(title)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
                accessory
            }
            .frame(minHeight: 32)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.panel)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

extension PhoneCard where Accessory == EmptyView {
    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.accessory = EmptyView()
        self.content = content()
    }
}

/// Small toggle chip in a card's title row ("Level 1 ⇄").
struct PhoneChip: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(text)
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 10, weight: .bold))
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(DS.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(DS.tile)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The figure above a chart: the picked day and its value.
struct PhoneFocusChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold).monospacedDigit())
            .foregroundStyle(DS.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(DS.tile)
            .clipShape(Capsule())
    }
}

enum PhoneChartAxis {
    /// First, middle and last bucket.
    static func ticks(_ starts: [Date]) -> [Date] {
        guard let first = starts.first, let last = starts.last else { return [] }
        return Array(Set([first, starts[(starts.count - 1) / 2], last])).sorted()
    }

    static func label(_ date: Date, period: CashPeriod) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.current.locale
        let last = Calendar.current.date(byAdding: .second, value: -1, to: period.end()) ?? period.start
        if period.bucketComponent == .day {
            formatter.dateFormat = "M-d"
        } else if Calendar.current.isDate(period.start, equalTo: last, toGranularity: .year) {
            formatter.setLocalizedDateFormatFromTemplate("MMM")
        } else {
            formatter.dateFormat = "yyyy-M"
        }
        return formatter.string(from: date)
    }

    static func focus(_ date: Date, period: CashPeriod) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.current.locale
        formatter.setLocalizedDateFormatFromTemplate(period.bucketComponent == .day ? "MMMd" : "yMMM")
        return formatter.string(from: date)
    }
}

// MARK: - Expense & income

struct PhoneOverviewCard: View {
    let summary: CashSummary
    let period: CashPeriod
    let code: String
    let open: (String, Set<TransactionKind>) -> Void
    @State private var showsMore = false

    var body: some View {
        let average = period.bucketComponent == .day ? tr("Daily expense") : tr("Monthly expense")
        PhoneCard(title: tr("Expense & income"), icon: "square.grid.2x2.fill") {
            Spacer(minLength: 8)
            Button { withAnimation(.snappy) { showsMore.toggle() } } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.textSecondary)
                    .rotationEffect(.degrees(showsMore ? 90 : 0))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } content: {
            LazyVGrid(columns: PhoneCard<EmptyView, EmptyView>.twoColumns, spacing: 10) {
                tile(tr("Expense"), summary.expense) { open(tr("Expense"), [.expense]) }
                tile(tr("Income"), summary.income, color: FlowPalette.income) { open(tr("Income"), [.income]) }
                tile(tr("Balance"), summary.balance,
                     color: summary.balance >= 0 ? FlowPalette.income : FlowPalette.expense, signed: true) {
                    open(tr("Balance"), [.expense, .income])
                }
                tile(average, summary.averageExpense) { open(tr("Expense"), [.expense]) }
                if showsMore {
                    StatTile(title: tr("Refund"), value: summary.refund, code: code)
                    StatTile(title: tr("Discount"), value: summary.discount, code: code)
                    StatTile(title: tr("Fee"), value: summary.fee, code: code)
                    StatTile(title: tr("Reimbursement pending"), value: summary.claimPending, code: code)
                    StatTile(title: tr("Claimed"), value: summary.claimed, code: code)
                    StatTile(title: tr("Records"), value: Decimal(summary.count), code: "", isCount: true)
                }
            }
        }
    }

    private func tile(_ title: String, _ value: Decimal, color: Color = DS.textPrimary, signed: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text(title).lineLimit(1).minimumScaleFactor(0.8)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DS.textSecondary)
                Text(Fmt.money(value, code, showSign: signed))
                    .font(DS.money(22, weight: .bold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.tile)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Statistics

struct PhoneStatisticsCard: View {
    let buckets: [CashBucket]
    let summary: CashSummary
    let period: CashPeriod
    let code: String

    @State private var mode: FlowMode = .expense
    @State private var selected: Date?
    @AppStorage("phoneStatisticsAsLine") private var asLine = true

    private var unit: Calendar.Component { period.bucketComponent }

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

    private var title: String {
        switch mode {
        case .expense: return tr("Expense statistics")
        case .income: return tr("Income statistics")
        case .balance: return tr("Balance statistics")
        }
    }

    /// The picked bucket, else the largest one so far.
    private var focus: CashBucket? {
        if let selected {
            return buckets.first { Calendar.current.isDate($0.start, equalTo: selected, toGranularity: unit) }
        }
        let peak = buckets.filter { $0.start <= Date() }.max { abs(value($0)) < abs(value($1)) }
        return peak.flatMap { value($0) == 0 ? nil : $0 }
    }

    var body: some View {
        let focus = self.focus
        let lineColor = color(mode == .balance ? summary.balance : 1)
        PhoneCard(title: title, icon: "chart.xyaxis.line") {
            Text(trf("Avg: %@", Fmt.money(average, code)))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(DS.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 6)
            Button { asLine.toggle() } label: {
                Image(systemName: asLine ? "chart.bar.xaxis" : "chart.xyaxis.line")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.textSecondary)
                    .frame(width: 42, height: 32)
                    .background(DS.tile)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
        } content: {
            VStack(spacing: 12) {
                PhoneFocusChip(text: focus.map {
                    "\(PhoneChartAxis.focus($0.start, period: period))  \(Fmt.money(value($0), code))"
                } ?? "\(tr("Average")) \(Fmt.money(average, code))")
                Chart {
                    ForEach(buckets) { bucket in
                        if asLine {
                            if bucket.start <= Date() {
                                AreaMark(x: .value("Date", bucket.start, unit: unit),
                                         y: .value("Amount", value(bucket).doubleValue))
                                    .foregroundStyle(LinearGradient(colors: [lineColor.opacity(0.35), lineColor.opacity(0.02)],
                                                                    startPoint: .top, endPoint: .bottom))
                                    .interpolationMethod(.monotone)
                                LineMark(x: .value("Date", bucket.start, unit: unit),
                                         y: .value("Amount", value(bucket).doubleValue),
                                         series: .value("Part", "past"))
                                    .foregroundStyle(lineColor)
                                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .interpolationMethod(.monotone)
                            } else {
                                LineMark(x: .value("Date", bucket.start, unit: unit), y: .value("Amount", 0),
                                         series: .value("Part", "ahead"))
                                    .foregroundStyle(lineColor)
                                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            }
                        } else {
                            BarMark(x: .value("Date", bucket.start, unit: unit),
                                    y: .value("Amount", value(bucket).doubleValue))
                                .foregroundStyle(color(value(bucket)))
                                .cornerRadius(3)
                                .opacity(focus == nil || focus?.start == bucket.start ? 1 : 0.5)
                        }
                    }
                    if asLine, let focus {
                        PointMark(x: .value("Date", focus.start, unit: unit),
                                  y: .value("Amount", value(focus).doubleValue))
                            .symbol(Circle().strokeBorder(lineWidth: 2))
                            .symbolSize(80)
                            .foregroundStyle(lineColor)
                    }
                }
                .chartXSelection(value: $selected)
                .phoneChartAxes(starts: buckets.map(\.start), period: period, code: code)
                .frame(height: 240)
                CapsuleSwitch(options: FlowMode.allCases, selection: $mode) {
                    switch $0 {
                    case .expense: return tr("Exp")
                    case .income: return tr("Inc")
                    case .balance: return tr("Bal")
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

extension View {
    /// Dashed grid per bucket, three date labels, compact amounts on the left.
    func phoneChartAxes(starts: [Date], period: CashPeriod, code: String) -> some View {
        chartXAxis {
            AxisMarks(values: starts) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                    .foregroundStyle(DS.border.opacity(0.7))
            }
            AxisMarks(values: PhoneChartAxis.ticks(starts)) { value in
                AxisValueLabel(centered: false, collisionResolution: .disabled) {
                    if let date = value.as(Date.self) {
                        Text(PhoneChartAxis.label(date, period: period))
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(DS.textSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                    .foregroundStyle(DS.border.opacity(0.7))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(Fmt.moneyCompact(Decimal(amount), code))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(DS.textSecondary)
                    }
                }
            }
        }
    }
}

// MARK: - Categories

struct PhoneCategoriesCard: View {
    let entries: [CashEntry]
    let period: CashPeriod
    let code: String

    @State private var kind: TransactionKind = .expense
    @State private var level: CategoryLevel = .first
    @AppStorage("phoneCategoriesCompare") private var compares = false
    @State private var showsAll = false
    @State private var opened: Set<String> = []
    @State private var selection: CategorySelection?

    private static let collapsedCount = 8

    var body: some View {
        let stats = CashflowAnalytics.categories(entries, kind: kind, level: level, in: period)
        let total = stats.reduce(Decimal(0)) { $0 + $1.amount }
        PhoneCard(title: kind == .income ? tr("Income categories") : tr("Expense categories"), icon: "chart.pie.fill") {
            Spacer(minLength: 6)
            if period.isShiftable {
                PhoneChip(text: compares ? tr("Compared") : tr("No comparison")) { compares.toggle() }
            }
            PhoneChip(text: level == .first ? tr("Level 1") : tr("Level 2")) {
                level = level == .first ? .second : .first
                opened = []
            }
        } content: {
            VStack(spacing: 0) {
                if stats.isEmpty {
                    Text(tr("No records in this period"))
                        .font(DS.caption)
                        .foregroundStyle(DS.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 140)
                } else {
                    PhoneCalloutDonut(
                        slices: stats.enumerated().map { rank, stat in
                            .init(id: stat.name, label: stat.name, share: stat.share,
                                  color: FlowPalette.color(kind: kind, rank: rank))
                        },
                        title: kind.displayName,
                        value: Fmt.money(total, code)
                    ) { kind = kind == .expense ? .income : .expense }
                    .frame(height: 280)
                }
                CapsuleSwitch(options: [TransactionKind.expense, .income], selection: $kind) {
                    $0 == .expense ? tr("Exp") : tr("Inc")
                }
                .padding(.top, 6)
                .padding(.bottom, 4)
                ForEach(Array(stats.enumerated()), id: \.element.id) { rank, stat in
                    if showsAll || rank < Self.collapsedCount {
                        if rank > 0 { Divider().overlay(DS.border.opacity(0.6)).padding(.leading, 56) }
                        row(stat, rank: rank)
                    }
                }
                if stats.count > Self.collapsedCount {
                    Button { withAnimation(.snappy) { showsAll.toggle() } } label: {
                        Text(showsAll ? tr("Fold") : trf("Show all %d", stats.count))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(DS.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
        }
        .sheet(item: $selection) { CategoryDetailSheet(selection: $0, period: period, code: code) }
        .onChange(of: kind) { _, _ in opened = [] }
    }

    private func subcategories(of name: String) -> [CategoryStat] {
        let mine = entries.filter { ($0.category.isEmpty ? "—" : $0.category) == name }
        let stats = CashflowAnalytics.categories(mine, kind: kind, level: .second, in: period)
        return stats.allSatisfy { $0.name == name } ? [] : stats
    }

    private func row(_ stat: CategoryStat, rank: Int) -> some View {
        let color = FlowPalette.color(kind: kind, rank: rank)
        let subs = level == .first ? subcategories(of: stat.name) : []
        let isOpen = opened.contains(stat.name)
        let change = compares && stat.change != 0
            ? "\(stat.change > 0 ? "▲" : "▼")\(Fmt.money(abs(stat.change), code)) · " : ""
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                CategoryIcon(name: stat.name, kind: kind, size: 44)
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(CategoryName.label(stat.name))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(DS.textPrimary)
                            .lineLimit(1)
                        Text(Fmt.percent(stat.share, decimals: 2, showSign: false))
                            .font(.system(size: 14.5).monospacedDigit())
                            .foregroundStyle(DS.textSecondary)
                            .fixedSize()
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.tile)
                            Capsule().fill(color).frame(width: max(5, geometry.size.width * stat.share))
                        }
                    }
                    .frame(height: 6)
                }
                VStack(alignment: .trailing, spacing: 6) {
                    Text(Fmt.money(stat.amount, code))
                        .font(DS.money(17, weight: .semibold))
                        .foregroundStyle(DS.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                    Text("\(change)\(stat.count)")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(DS.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Button {
                    if subs.isEmpty {
                        selection = CategorySelection(name: stat.name, level: level, kind: kind)
                    } else {
                        withAnimation(.snappy) {
                            if isOpen { opened.remove(stat.name) } else { opened.insert(stat.name) }
                        }
                    }
                } label: {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.textTertiary)
                        .frame(width: 24, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture { selection = CategorySelection(name: stat.name, level: level, kind: kind) }
            if isOpen {
                VStack(spacing: 6) {
                    ForEach(subs) { sub in
                        Button {
                            selection = CategorySelection(name: sub.name, level: .second, kind: kind)
                        } label: {
                            HStack(spacing: 10) {
                                CategoryIcon(name: sub.name, kind: kind, size: 30)
                                Text(CategoryName.label(sub.name))
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(DS.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text("\(Fmt.money(sub.amount, code)) [\(sub.count)/\(Fmt.percent(sub.share, decimals: 2, showSign: false))]")
                                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                                    .foregroundStyle(DS.textSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(DS.tile)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 28)
                .padding(.bottom, 12)
            }
        }
    }
}

/// Ring chart with each slice's share and name pulled out on a leader line.
struct PhoneCalloutDonut: View {
    struct Slice: Identifiable {
        let id: String
        let label: String
        let share: Double
        let color: Color
    }

    private struct Callout: Identifiable {
        let id: String
        let percent: String
        let label: String
        let color: Color
        let anchor: CGPoint
        var y: CGFloat
        let elbowRadius: CGFloat
        let angle: Double
        let right: Bool
    }

    let slices: [Slice]
    let title: String
    let value: String
    let onCenterTap: () -> Void

    private static let maxCallouts = 9
    private static let lineGap: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width * 0.28, size.height * 0.40)
            let inner = outer * 0.64
            let arcs = arcs()
            let callouts = callouts(center: center, outer: outer, height: size.height)
            let labelWidth = max(34, size.width / 2 - outer - 34)
            ZStack {
                ForEach(arcs, id: \.id) { arc in
                    DonutSlice(start: arc.start, end: arc.end, inner: inner, outer: outer)
                        .fill(arc.color)
                }
                ForEach(callouts) { callout in
                    let elbow = CGPoint(x: center.x + callout.elbowRadius * cos(callout.angle), y: callout.y)
                    let textX = center.x + (callout.right ? 1 : -1) * (outer + 24)
                    Path { path in
                        path.move(to: callout.anchor)
                        path.addLine(to: elbow)
                        path.addLine(to: CGPoint(x: textX, y: callout.y))
                    }
                    .stroke(callout.color, lineWidth: 1)
                    VStack(alignment: callout.right ? .leading : .trailing, spacing: 0) {
                        Text(callout.percent).monospacedDigit()
                        Text(callout.label)
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: labelWidth, alignment: callout.right ? .leading : .trailing)
                    .position(x: textX + (callout.right ? 1 : -1) * (labelWidth / 2 + 3), y: callout.y)
                }
                Button(action: onCenterTap) {
                    VStack(spacing: 4) {
                        HStack(spacing: 3) {
                            Text(title)
                            Image(systemName: "arrow.left.arrow.right").font(.system(size: 11, weight: .bold))
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DS.textSecondary)
                        Text(value)
                            .font(DS.money(19, weight: .bold))
                            .foregroundStyle(DS.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    .frame(width: inner * 1.7)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .position(center)
            }
        }
    }

    private func arcs() -> [(id: String, start: Double, end: Double, color: Color)] {
        var cursor = -Double.pi / 2
        return slices.map { slice in
            let start = cursor
            cursor += slice.share * 2 * .pi
            return (slice.id, start, cursor, slice.color)
        }
    }

    private func callouts(center: CGPoint, outer: CGFloat, height: CGFloat) -> [Callout] {
        var cursor = -Double.pi / 2
        var all: [Callout] = []
        for slice in slices {
            let start = cursor
            cursor += slice.share * 2 * .pi
            let mid = (start + cursor) / 2
            let parts = CategoryName.split(slice.label)
            all.append(Callout(
                id: slice.id,
                percent: Fmt.percent(slice.share, decimals: 2, showSign: false),
                label: "\(parts.emoji ?? "")\(parts.label)",
                color: slice.color,
                anchor: CGPoint(x: center.x + (outer + 3) * cos(mid), y: center.y + (outer + 3) * sin(mid)),
                y: center.y + (outer + 16) * sin(mid),
                elbowRadius: outer + 12,
                angle: mid,
                right: cos(mid) >= 0))
        }
        let shown = Set(all.enumerated()
            .filter { slices[$0.offset].share >= 0.015 }
            .sorted { slices[$0.offset].share > slices[$1.offset].share }
            .prefix(Self.maxCallouts)
            .map(\.element.id))
        var result: [Callout] = []
        for side in [true, false] {
            var column = all.filter { $0.right == side && shown.contains($0.id) }.sorted { $0.y < $1.y }
            for index in column.indices {
                let floor = index == 0 ? 14 : column[index - 1].y + Self.lineGap
                column[index].y = max(column[index].y, floor)
            }
            for index in column.indices.reversed() {
                let ceiling = index == column.count - 1 ? height - 14 : column[index + 1].y - Self.lineGap
                column[index].y = min(column[index].y, ceiling)
            }
            result += column
        }
        return result
    }
}

private struct DonutSlice: Shape {
    let start: Double
    let end: Double
    let inner: CGFloat
    let outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let inset = end - start > 0.03 ? 0.008 : 0
        let from = Angle(radians: start + inset)
        let to = Angle(radians: end - inset)
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: from, endAngle: to, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: to, endAngle: from, clockwise: true)
        path.closeSubpath()
        return path
    }
}

// MARK: - Net assets trend

struct PhoneNetTrendCard: View {
    enum Series: String, CaseIterable { case net, assets, debts }

    let points: [NetAssetPoint]
    let period: CashPeriod
    let code: String
    @State private var series: Series = .net
    @State private var selected: Date?

    private func value(_ point: NetAssetPoint) -> Decimal {
        switch series {
        case .net: return point.net
        case .assets: return point.assets
        case .debts: return point.debts
        }
    }

    private var color: Color { series == .debts ? FlowPalette.expense : FlowPalette.income }

    private var focus: NetAssetPoint? {
        guard let selected else { return points.last }
        return points.last { $0.date <= selected } ?? points.first
    }

    var body: some View {
        let starts = period.bucketStarts()
        let ahead: [Date] = points.last.map { last in starts.filter { $0 > last.date } } ?? []
        PhoneCard(title: tr("Net assets trend"), icon: "chart.line.uptrend.xyaxis") {
            Spacer(minLength: 0)
        } content: {
            VStack(spacing: 12) {
                if let focus {
                    PhoneFocusChip(text: "\(PhoneChartAxis.focus(focus.date, period: period))  \(Fmt.money(value(focus), code))")
                }
                Chart {
                    ForEach(points) { point in
                        AreaMark(x: .value("Date", point.date), y: .value("Value", value(point).doubleValue))
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.06)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", point.date), y: .value("Value", value(point).doubleValue))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            .interpolationMethod(.monotone)
                    }
                    if let last = points.last, let end = ahead.last {
                        RectangleMark(xStart: .value("Date", last.date), xEnd: .value("Date", end),
                                      yStart: .value("Base", 0), yEnd: .value("Value", value(last).doubleValue))
                            .foregroundStyle(color.opacity(0.12))
                        RuleMark(xStart: .value("Date", last.date), xEnd: .value("Date", end),
                                 y: .value("Value", value(last).doubleValue))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                    if let focus {
                        PointMark(x: .value("Date", focus.date), y: .value("Value", value(focus).doubleValue))
                            .symbol(Circle().strokeBorder(lineWidth: 2))
                            .symbolSize(80)
                            .foregroundStyle(color)
                    }
                }
                .chartXSelection(value: $selected)
                .chartYScale(domain: .automatic(includesZero: false))
                .phoneChartAxes(starts: starts, period: period, code: code)
                .frame(height: 240)
                CapsuleSwitch(options: Series.allCases, selection: $series) {
                    switch $0 {
                    case .net: return tr("Net")
                    case .assets: return tr("Assets")
                    case .debts: return tr("Debts")
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Summary table

struct PhoneSummaryCard: View {
    let buckets: [CashBucket]
    let summary: CashSummary
    let period: CashPeriod
    let code: String
    @AppStorage("phoneSummaryBalanceColor") private var balanceColor = true

    private var rows: [CashBucket] {
        buckets.filter { $0.expense != 0 || $0.income != 0 }.reversed()
    }

    private func label(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.current.locale
        formatter.setLocalizedDateFormatFromTemplate(period.bucketComponent == .day ? "Md" : "yyMMM")
        return formatter.string(from: date)
    }

    var body: some View {
        let title = period.bucketComponent == .day ? tr("Daily summary") : tr("Monthly summary")
        PhoneCard(title: "\(title)(\(code))", icon: "tablecells.fill") {
            Spacer(minLength: 6)
            PhoneChip(text: balanceColor ? tr("Balance color") : tr("No balance color")) { balanceColor.toggle() }
        } content: {
            Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 12) {
                GridRow {
                    Text(tr("Date")).gridColumnAlignment(.leading)
                    Text(tr("Expense"))
                    Text(tr("Income"))
                    Text(tr("Balance"))
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.textSecondary)
                line(tr("Total"), summary.expense, summary.income, summary.balance, strong: true)
                line(tr("Average"), summary.averageExpense, summary.averageIncome, summary.averageBalance, strong: true)
                Divider().overlay(DS.border)
                ForEach(rows) { bucket in
                    line(label(bucket.start), bucket.expense, bucket.income, bucket.balance, strong: false)
                }
            }
            .padding(14)
            .background(DS.tile)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func line(_ title: String, _ expense: Decimal, _ income: Decimal, _ balance: Decimal,
                      strong: Bool) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(strong ? DS.textPrimary : DS.textSecondary)
                .gridColumnAlignment(.leading)
            Text(Fmt.money(expense, code)).foregroundStyle(DS.textPrimary)
            Text(Fmt.money(income, code)).foregroundStyle(DS.textPrimary)
            Text(Fmt.money(balance, code, showSign: true))
                .foregroundStyle(balanceColor ? (balance >= 0 ? FlowPalette.income : FlowPalette.expense)
                                              : DS.textPrimary)
        }
        .font(.system(size: 13, weight: strong ? .semibold : .regular).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

// MARK: - Sheets

struct PhoneRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var from: Date
    @State private var to: Date
    let apply: (CashPeriod) -> Void

    init(period: CashPeriod, apply: @escaping (CashPeriod) -> Void) {
        _from = State(initialValue: period.start)
        _to = State(initialValue: Calendar.current.date(byAdding: .second, value: -1, to: period.end()) ?? period.start)
        self.apply = apply
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(tr("Start"), selection: $from, displayedComponents: .date)
                DatePicker(tr("End"), selection: $to, in: from..., displayedComponents: .date)
            }
            .contentMargins(.horizontal, DS.phoneMargin, for: .scrollContent)
            .navigationTitle(tr("Custom range"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Done")) {
                        apply(CashPeriod(from: from, through: to))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct PhoneRecordsSelection: Identifiable {
    let id = UUID()
    let title: String
    let kinds: Set<TransactionKind>
    let period: CashPeriod
}

struct PhoneRecordsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    let selection: PhoneRecordsSelection
    @State private var editing: Transaction?

    var body: some View {
        let shown = transactions.filter {
            selection.kinds.contains($0.kind) && selection.period.contains($0.date) && !$0.excludeFromStats
        }
        NavigationStack {
            ScrollView {
                RecordList(transactions: shown, showsDate: true, editing: $editing)
                    .padding(.horizontal, DS.phoneMargin)
            }
            .background(DS.panel)
            .navigationTitle("\(selection.title) · \(selection.period.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(tr("Done")) { dismiss() } }
            }
        }
        .sheet(item: $editing) { TransactionEditor(transaction: $0) }
    }
}
