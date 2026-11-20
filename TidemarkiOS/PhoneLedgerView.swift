import SwiftUI
import SwiftData

// MARK: - Ledger (iPhone)
//
// The phone is where records are entered, so this page is built around that:
// the month's totals on top, then every record of the month grouped by day,
// and one large button in the thumb's corner that opens a new record. The
// month switcher sits in the title row; the calendar is a tap away.

/// Reads only the shown period's records: refetching and reading all of them
/// after every save cost ~150 ms on the phone.
struct PhoneLedgerView: View {
    @Environment(AppState.self) private var app

    var body: some View { PhoneLedgerPage(period: app.cashPeriod) }
}

private struct PhoneLedgerPage: View {
    @Environment(AppState.self) private var app
    @Query private var transactions: [Transaction]

    init(period: CashPeriod) {
        let start = period.start, limit = period.limit
        _transactions = Query(filter: #Predicate<Transaction> { $0.date >= start && $0.date < limit },
                              sort: \.date, order: .reverse, animation: .snappy)
    }
    @Query private var rates: [CurrencyRate]

    @State private var showsCalendar = false
    @State private var selectedDay: Date?
    @State private var editing: Transaction?

    private struct DayGroup: Identifiable {
        let day: Date
        let records: [Transaction]
        let expense: Decimal
        let income: Decimal
        var id: Date { day }
    }

    private var monthTitle: String { app.cashPeriod.title }

    var body: some View {
        let code = app.baseCurrency
        let converter = CurrencyConverter(rates: rates, base: code)
        let period = app.cashPeriod
        let inPeriod = transactions.filter { period.contains($0.date) }
        let entries = inPeriod.map { $0.cashEntry(using: converter) }
        let baseByID = Dictionary(zip(inPeriod.map(\.id), entries.map(\.base)), uniquingKeysWith: { a, _ in a })
        let summary = CashflowAnalytics.summary(entries, in: period)
        let calendar = Calendar.current

        let shown: [Transaction] = {
            if showsCalendar, let day = selectedDay {
                return transactions.filter { calendar.isDate($0.date, inSameDayAs: day) }
            }
            return inPeriod
        }()
        let groups: [DayGroup] = Dictionary(grouping: shown) { calendar.startOfDay(for: $0.date) }
            .map { day, records in
                var expense: Decimal = 0
                var income: Decimal = 0
                for record in records where !record.excludeFromStats {
                    let base = baseByID[record.id] ?? record.cashEntry(using: converter).base
                    if record.kind == .expense { expense += base }
                    if record.kind == .income { income += base }
                }
                return DayGroup(day: day, records: records, expense: expense, income: income)
            }
            .sorted { $0.day > $1.day }

        @Bindable var app = app
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    header
                    summaryCard(summary, code: code)
                    if showsCalendar && period.unit == .month {
                        Panel {
                            MonthCalendar(period: $app.cashPeriod, entries: entries,
                                          code: code, selectedDay: $selectedDay)
                        }
                    }
                    if groups.isEmpty {
                        Text(((try? context.fetchCount(FetchDescriptor<Transaction>())) ?? 0) == 0
                             ? tr("No records yet") : tr("No records"))
                            .font(DS.body)
                            .foregroundStyle(DS.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                    ForEach(groups) { group in
                        dayBlock(group, code: code)
                    }
                }
                .padding(.horizontal, DS.phoneMargin)
                .padding(.top, PageTitle<EmptyView>.pageTop)
                .padding(.bottom, 110) // room for the add button
            }
            AddRecordButton()
        }
        .background(DS.page)
        .sheet(item: $editing) { RecordDetailView(transaction: $0) }
        .onChange(of: app.cashPeriod) { _, _ in selectedDay = nil }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: PerfProbe.openDetail)) { _ in
            editing = transactions.first { !$0.address.isEmpty } ?? transactions.first
        }
        #endif
    }

    // MARK: Pieces

    private var header: some View {
        @Bindable var app = app
        return PageTitle(title: tr("Ledger")) {
            HStack(spacing: 6) {
                RoundIconButton(symbol: "chevron.left", size: 30) { app.cashPeriod = app.cashPeriod.shifted(by: -1) }
                Text(monthTitle)
                    .font(.system(size: 16, weight: .medium).monospacedDigit())
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                RoundIconButton(symbol: "chevron.right", size: 30) { app.cashPeriod = app.cashPeriod.shifted(by: 1) }
                RoundIconButton(symbol: "calendar", size: 30, active: showsCalendar) {
                    showsCalendar.toggle()
                    if showsCalendar { app.cashPeriod = CashPeriod(unit: .month, containing: app.cashPeriod.start) }
                }
                .padding(.leading, 4)
            }
        }
    }

    private func summaryCard(_ summary: CashSummary, code: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AmountsLabel(title: tr("Expense"), color: FlowPalette.expense, size: 15)
            Text(Fmt.money(summary.expense, code))
                .font(DS.money(34))
                .foregroundStyle(DS.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            HStack(spacing: 18) {
                figure(tr("Income"), Fmt.money(summary.income, code))
                figure(tr("Balance"), Fmt.money(summary.balance, code, showSign: true))
                if summary.claimPending > 0 {
                    figure(tr("Pending"), Fmt.money(summary.claimPending, code))
                }
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
            .font(.system(size: 13, weight: .regular).monospacedDigit())
            .foregroundStyle(DS.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)

            VStack(spacing: 0) {
                ForEach(Array(group.records.enumerated()), id: \.element.id) { index, record in
                    RecordRow(transaction: record)
                        .padding(.vertical, 4)
                        .onTapGesture { editing = record }
                        .contextMenu {
                            Button(tr("Details…")) { editing = record }
                            if record.claimStatus == .pending {
                                Button(tr("Mark as claimed")) {
                                    record.claimAmount = record.amount - record.refundAmount
                                    record.claimStatus = .claimed
                                    record.updatedAt = Date()
                                    try? context.save()
                                }
                            } else if record.kind == .expense && record.claimStatus == .none {
                                Button(tr("Mark as reimbursable")) {
                                    record.claimStatus = .pending
                                    record.updatedAt = Date()
                                    try? context.save()
                                }
                            }
                            if record.canBeExcluded {
                                Button(record.excludeActionTitle) { record.toggleExcluded(in: context) }
                            }
                            Button(tr("Delete"), role: .destructive) { delete(record) }
                        }
                    if index < group.records.count - 1 {
                        Divider().overlay(DS.border.opacity(0.5))
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
}

/// The add button owns the entry sheet, so opening and closing it does not
/// redraw the whole ledger (that cost a ~100 ms frame mid-dismiss).
private struct AddRecordButton: View {
    @State private var creating = false

    var body: some View {
        Button { creating = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .medium).monospacedDigit())
                .foregroundStyle(DS.ink)
                .frame(width: 66, height: 66)
                .background(DS.accent)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, DS.phoneMargin)
        .padding(.bottom, 18)
        .accessibilityLabel(tr("Add record"))
        .sheet(isPresented: $creating) {
            QuickEntryView()
                .presentationDetents([.large])
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: PerfProbe.openEntry)) { _ in creating = true }
        #endif
    }
}
