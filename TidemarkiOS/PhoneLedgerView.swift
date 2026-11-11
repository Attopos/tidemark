import SwiftUI
import SwiftData

// MARK: - Ledger (iPhone)
//
// The phone is where records are entered, so this page is built around that:
// the month's totals on top, then every record of the month grouped by day,
// and one large button in the thumb's corner that opens a new record. The
// calendar and the search field are a tap away rather than always on screen.

struct PhoneLedgerView: View {
    @Environment(AppState.self) private var app
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var rates: [CurrencyRate]

    @State private var showsCalendar = false
    @State private var showsSearch = false
    @State private var selectedDay: Date?
    @State private var search = ""
    @State private var editing: Transaction?
    @State private var creating = false

    private struct DayGroup: Identifiable {
        let day: Date
        let records: [Transaction]
        let expense: Decimal
        let income: Decimal
        var id: Date { day }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = L10n.current.locale
        formatter.setLocalizedDateFormatFromTemplate(app.cashPeriod.unit == .month ? "yMMM" : "y")
        return formatter.string(from: app.cashPeriod.start)
    }

    private func matches(_ transaction: Transaction, _ query: String) -> Bool {
        [transaction.category, transaction.subcategory, transaction.note, transaction.tags, transaction.address,
         transaction.account?.name ?? "", transaction.transferAccount?.name ?? "", "\(transaction.amount)"]
            .contains { $0.lowercased().contains(query) }
    }

    var body: some View {
        let code = app.baseCurrency
        let converter = CurrencyConverter(rates: rates, base: code)
        let period = app.cashPeriod
        let entries = transactions.map { $0.cashEntry(using: converter) }
        let summary = CashflowAnalytics.summary(entries, in: period)
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let calendar = Calendar.current

        // Search looks through everything; otherwise the month, or one day of it.
        let shown: [Transaction] = {
            if !query.isEmpty { return transactions.filter { matches($0, query) } }
            if showsCalendar, let day = selectedDay {
                return transactions.filter { calendar.isDate($0.date, inSameDayAs: day) }
            }
            return transactions.filter { period.contains($0.date) }
        }()
        let groups: [DayGroup] = Dictionary(grouping: shown) { calendar.startOfDay(for: $0.date) }
            .map { day, records in
                var expense: Decimal = 0
                var income: Decimal = 0
                for record in records where !record.excludeFromStats {
                    let base = record.cashEntry(using: converter).base
                    if record.kind == .expense { expense += base }
                    if record.kind == .income { income += base }
                }
                return DayGroup(day: day, records: records, expense: expense, income: income)
            }
            .sorted { $0.day > $1.day }

        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    header
                    if showsSearch { searchField }
                    summaryCard(summary, code: code)
                    if showsCalendar && query.isEmpty && period.unit == .month {
                        Panel {
                            MonthCalendar(period: period,
                                          buckets: CashflowAnalytics.buckets(entries, in: period),
                                          code: code, selectedDay: $selectedDay)
                        }
                    }
                    if groups.isEmpty {
                        Text(transactions.isEmpty ? tr("No records yet") : tr("No records"))
                            .font(DS.body)
                            .foregroundStyle(DS.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                    ForEach(groups) { group in
                        dayBlock(group, code: code)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 110) // room for the add button
            }
            addButton
        }
        .background(DS.page)
        .sheet(item: $editing) { TransactionEditor(transaction: $0) }
        .sheet(isPresented: $creating) {
            TransactionEditor(transaction: nil, defaultDate: showsCalendar ? selectedDay : nil)
        }
        .onChange(of: app.cashPeriod) { _, _ in selectedDay = nil }
    }

    // MARK: Pieces

    private var header: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("Ledger"))
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(DS.textPrimary)
                Spacer()
                roundButton("magnifyingglass", active: showsSearch) {
                    showsSearch.toggle()
                    if !showsSearch { search = "" }
                }
            }
            HStack(spacing: 8) {
                Text(monthTitle)
                    .font(.system(size: 19, weight: .bold).monospacedDigit())
                    .foregroundStyle(DS.textPrimary)
                roundButton("chevron.left", size: 30) { app.cashPeriod = app.cashPeriod.shifted(by: -1) }
                roundButton("chevron.right", size: 30) { app.cashPeriod = app.cashPeriod.shifted(by: 1) }
                Spacer()
                Button {
                    showsCalendar.toggle()
                    if showsCalendar { app.cashPeriod = CashPeriod(unit: .month, containing: app.cashPeriod.start) }
                } label: {
                    Text(tr("Calendar"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(showsCalendar ? DS.ink : DS.textSecondary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(showsCalendar ? DS.accent : DS.tile)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func roundButton(_ symbol: String, size: CGFloat = 40, active: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(active ? DS.ink : DS.textPrimary)
                .frame(width: size, height: size)
                .background(active ? DS.accent : DS.tile)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(DS.textTertiary)
            TextField(tr("Search"), text: $search)
                .textFieldStyle(.plain)
                .foregroundStyle(DS.textPrimary)
                .autocorrectionDisabled()
        }
        .font(.system(size: 16))
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(DS.tile)
        .clipShape(Capsule())
    }

    private func summaryCard(_ summary: CashSummary, code: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Expense"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(FlowPalette.expense)
            Text(Fmt.money(summary.expense, code))
                .font(DS.money(34, weight: .bold))
                .foregroundStyle(DS.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            HStack(spacing: 18) {
                figure(tr("Income"), Fmt.money(summary.income, code))
                figure(tr("Balance"), Fmt.money(summary.balance, code, showSign: true))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.panel)
        .clipShape(RoundedRectangle(cornerRadius: DS.panelRadius, style: .continuous))
    }

    private func figure(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(DS.textTertiary)
            Text(value).foregroundStyle(DS.textSecondary)
        }
        .font(.system(size: 14).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private func dayBlock(_ group: DayGroup, code: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.day.formatted(.dateTime.month(.twoDigits).day(.twoDigits).weekday(.wide)
                    .locale(L10n.current.locale)))
                Spacer()
                if group.expense > 0 { Text("\(tr("Exp")) \(Fmt.money(group.expense, code))") }
                if group.income > 0 {
                    Text("\(tr("Inc")) \(Fmt.money(group.income, code))").foregroundStyle(FlowPalette.income)
                }
            }
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundStyle(DS.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(group.records.enumerated()), id: \.element.id) { index, record in
                    RecordRow(transaction: record)
                        .padding(.vertical, 4)
                        .onTapGesture { editing = record }
                        .contextMenu {
                            Button(tr("Edit…")) { editing = record }
                            Button(tr("Delete"), role: .destructive) { delete(record) }
                        }
                    if index < group.records.count - 1 {
                        Divider().overlay(DS.border.opacity(0.5)).padding(.leading, 42)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(DS.panel)
            .clipShape(RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous))
        }
    }

    @Environment(\.modelContext) private var context

    private func delete(_ record: Transaction) {
        context.delete(record)
        try? context.save()
    }

    /// The one thing this page is for.
    private var addButton: some View {
        Button { creating = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(DS.ink)
                .frame(width: 66, height: 66)
                .background(DS.accent)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 20)
        .padding(.bottom, 18)
        .accessibilityLabel(tr("Add record"))
    }
}
