import SwiftUI
import SwiftData

// MARK: - Ledger — day-to-day cash flow
//
// Month (or year) at a glance: what went out and came in, the trend of cash
// net assets, spending by category, a calendar of daily totals and the
// records of the selected day. Picking a category or typing in the search
// field replaces the day list with the matching records of the period.

struct LedgerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var accounts: [Account]
    @Query private var rates: [CurrencyRate]

    @State private var selectedDay: Date? = Calendar.current.startOfDay(for: Date())
    @State private var categorySelection: CategorySelection?
    @State private var search = ""
    @State private var editing: Transaction?
    @State private var creating = false

    var body: some View {
        @Bindable var app = app
        let snapshot = LedgerSnapshot(transactions: transactions, accounts: accounts, rates: rates,
                                      code: app.baseCurrency)
        let period = app.cashPeriod
        let summary = CashflowAnalytics.summary(snapshot.entries, in: period)
        let buckets = CashflowAnalytics.buckets(snapshot.entries, in: period)
        let trend = AccountLedger.trend(accounts: snapshot.ledgerAccounts, movements: snapshot.movements,
                                        period: period, converter: snapshot.converter)
        let net = snapshot.netAssets

        GeometryReader { geometry in
            let columns = geometry.size.width >= 1180 ? 3 : (geometry.size.width >= 780 ? 2 : 1)
            ScrollView {
                VStack(alignment: .leading, spacing: DS.gridGap) {
                    header(period: $app.cashPeriod)
                    if transactions.isEmpty {
                        emptyState
                    } else {
                        heroRow(summary: summary, net: net, code: snapshot.code, stacked: columns == 1)
                        let statistics = FlowBarsPanel(buckets: buckets, summary: summary, period: period,
                                                       code: snapshot.code, selectedDay: selectedDay)
                        let trendPanel = NetTrendPanel(points: trend, period: period, code: snapshot.code)
                        let categories = CategoryPanel(entries: snapshot.entries, period: period,
                                                       code: snapshot.code, selection: $categorySelection)
                        let days = dayColumn(period: period, buckets: buckets, code: snapshot.code)
                        switch columns {
                        case 3:
                            HStack(alignment: .top, spacing: DS.gridGap) {
                                VStack(spacing: DS.gridGap) { statistics; trendPanel }
                                categories
                                days
                            }
                        case 2:
                            HStack(alignment: .top, spacing: DS.gridGap) {
                                VStack(spacing: DS.gridGap) { statistics; trendPanel; categories }
                                days
                            }
                        default:
                            statistics; days; categories; trendPanel
                        }
                    }
                }
                .padding(.horizontal, columns == 1 ? 20 : DS.pagePadding)
                .padding(.top, columns == 1 ? 24 : 38)
                .padding(.bottom, DS.pagePadding)
                .frame(maxWidth: 1500, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(DS.page)
        .sheet(item: $editing) { TransactionEditor(transaction: $0) }
        .sheet(isPresented: $creating) {
            TransactionEditor(transaction: nil, defaultDate: selectedDay)
        }
        .onChange(of: app.cashPeriod) { _, period in
            categorySelection = nil
            let today = Calendar.current.startOfDay(for: Date())
            selectedDay = period.contains(today) ? today : nil
        }
    }

    // MARK: Header

    private func header(period: Binding<CashPeriod>) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                title
                Spacer(minLength: 12)
                PeriodBar(period: period)
                searchField
                addButton
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack { title; Spacer(); addButton }
                PeriodBar(period: period)
                searchField
            }
        }
        .padding(.bottom, 6)
    }

    private var title: some View {
        Text(tr("Ledger"))
            .font(DS.title(30))
            .foregroundStyle(DS.textPrimary)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.textTertiary)
            TextField(tr("Search"), text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(DS.textPrimary)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(DS.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .frame(width: 190, height: 30)
        .background(DS.tile)
        .clipShape(Capsule())
    }

    private var addButton: some View {
        Button { creating = true } label: {
            Label(tr("Add record"), systemImage: "plus")
        }
        .buttonStyle(AccentButtonStyle())
        .keyboardShortcut("n", modifiers: .command)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(DS.textTertiary)
            Text(tr("No records yet"))
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(DS.textPrimary)
            Text(tr("Add a record, or import a bookkeeping export (.xlsx) from Settings or by dropping it here."))
                .font(DS.body)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private func heroRow(summary: CashSummary, net: (assets: Decimal, debts: Decimal),
                         code: String, stacked: Bool) -> some View {
        let expense = HeroFigure(title: tr("Expense"), value: summary.expense, code: code,
                                 details: [(tr("Income"), Fmt.money(summary.income, code)), (tr("Balance"), Fmt.money(summary.balance, code, showSign: true))])
        let daily = HeroFigure(title: app.cashPeriod.unit == .month ? tr("Daily average") : tr("Monthly average"),
                               value: summary.averageExpense, code: code,
                               details: [(tr("Records"), "\(summary.count)")])
        let assets = HeroFigure(title: tr("Cash net assets"), value: net.assets - net.debts, code: code,
                                details: [(tr("Assets"), Fmt.money(net.assets, code)), (tr("Debts"), Fmt.money(net.debts, code))])
        return Group {
            if stacked {
                VStack(spacing: DS.gridGap) { expense; assets }
            } else {
                HStack(alignment: .top, spacing: DS.gridGap) { expense; daily; assets }
            }
        }
    }

    // MARK: Calendar + records

    private func dayColumn(period: CashPeriod, buckets: [CashBucket], code: String) -> some View {
        VStack(spacing: DS.gridGap) {
            if period.unit == .month {
                Panel {
                    MonthCalendar(period: period, buckets: buckets, code: code, selectedDay: $selectedDay)
                }
            }
            recordsPanel(period: period, code: code)
        }
    }

    private func recordsPanel(period: CashPeriod, code: String) -> some View {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        var title: String
        var shown: [Transaction]
        var showsDate = true
        if !query.isEmpty {
            // Search covers everything, not just the period on screen.
            title = trf("Results for “%@”", search)
            shown = transactions.filter { transaction in
                [transaction.category, transaction.subcategory, transaction.note, transaction.tags,
                 transaction.address, transaction.account?.name ?? "", transaction.transferAccount?.name ?? "",
                 "\(transaction.amount)"].contains { $0.lowercased().contains(query) }
            }
        } else if let selection = categorySelection {
            title = selection.name
            shown = transactions.filter { period.contains($0.date) && selection.matches($0) }
        } else if let day = selectedDay, period.unit == .month {
            title = day.formatted(.dateTime.month().day().weekday(.wide).locale(L10n.current.locale))
            shown = transactions.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
            showsDate = false
        } else {
            title = tr("Records")
            shown = transactions.filter { period.contains($0.date) }
        }
        let spent = shown.filter { $0.kind == .expense && !$0.excludeFromStats }
            .reduce(Decimal(0)) { $0 + $1.cashEntry(using: CurrencyConverter(rates: rates, base: code)).base }
        return Panel(title: title, accessory: {
            Text("\(tr("Expense")) \(Fmt.money(spent, code))")
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(DS.textSecondary)
        }) {
            RecordList(transactions: shown, showsDate: showsDate, editing: $editing)
        }
    }
}

// MARK: - Month calendar

struct MonthCalendar: View {
    let period: CashPeriod
    let buckets: [CashBucket]
    let code: String
    @Binding var selectedDay: Date?

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // Monday
        return calendar
    }

    /// Leading blanks, then one cell per day.
    private var cells: [CashBucket?] {
        guard let first = buckets.first else { return [] }
        let weekday = calendar.component(.weekday, from: first.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + buckets.map { Optional($0) }
    }

    private var weekdaySymbols: [String] {
        var formatterCalendar = calendar
        formatterCalendar.locale = L10n.current.locale
        let symbols = formatterCalendar.veryShortStandaloneWeekdaySymbols
        return Array(symbols[1...]) + [symbols[0]]
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(DS.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, bucket in
                    if let bucket {
                        dayCell(bucket)
                    } else {
                        Color.clear.frame(height: 50)
                    }
                }
            }
        }
    }

    private func dayCell(_ bucket: CashBucket) -> some View {
        let selected = selectedDay.map { calendar.isDate($0, inSameDayAs: bucket.start) } ?? false
        let isToday = calendar.isDateInToday(bucket.start)
        return Button { selectedDay = bucket.start } label: {
            VStack(spacing: 1) {
                Text("\(calendar.component(.day, from: bucket.start))")
                    .font(.system(size: 13, weight: isToday ? .bold : .medium))
                    .foregroundStyle(selected ? DS.ink : (isToday ? DS.accent : DS.textPrimary))
                Text(bucket.expense > 0 ? "-\(compact(bucket.expense))" : " ")
                    .foregroundStyle(selected ? DS.ink.opacity(0.75) : FlowPalette.expense)
                Text(bucket.income > 0 ? "+\(compact(bucket.income))" : " ")
                    .foregroundStyle(selected ? DS.ink.opacity(0.75) : FlowPalette.income)
            }
            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(selected ? DS.accent : DS.tile.opacity(bucket.expense > 0 || bucket.income > 0 ? 1 : 0.45))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func compact(_ amount: Decimal) -> String {
        let value = amount.doubleValue
        if value >= 10_000 { return String(format: "%.1fw", value / 10_000) }
        if value >= 1_000 { return String(format: "%.0f", value) }
        return String(format: value == value.rounded() ? "%.0f" : "%.1f", value)
    }
}
