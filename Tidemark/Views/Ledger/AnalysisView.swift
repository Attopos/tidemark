import SwiftUI
import SwiftData

// MARK: - Analysis — the period in numbers
//
// The same period as the Ledger page, laid out for reading rather than
// entering: income and expense figures, the trend of cash net assets, money
// moved between own accounts, a per-day (or per-month) summary table, the
// bar statistics and the category breakdown.

struct AnalysisView: View {
    @Environment(AppState.self) private var app
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var accounts: [Account]
    @Query private var rates: [CurrencyRate]

    @State private var categorySelection: CategorySelection?
    @State private var editing: Transaction?

    var body: some View {
        @Bindable var app = app
        let snapshot = LedgerSnapshot(transactions: transactions, accounts: accounts, rates: rates,
                                      code: app.baseCurrency)
        let period = app.cashPeriod
        let summary = CashflowAnalytics.summary(snapshot.entries, in: period)
        let buckets = CashflowAnalytics.buckets(snapshot.entries, in: period)
        let trend = AccountLedger.trend(accounts: snapshot.ledgerAccounts, movements: snapshot.movements,
                                        period: period, converter: snapshot.converter)
        let transfers = CashflowAnalytics.transfers(snapshot.entries, in: period)

        GeometryReader { geometry in
            let columns = geometry.size.width >= 1180 ? 3 : (geometry.size.width >= 780 ? 2 : 1)
            ScrollView {
                VStack(alignment: .leading, spacing: DS.gridGap) {
                    let title = Text(tr("Analysis"))
                        .font(DS.title(30))
                        .foregroundStyle(DS.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            title
                            Spacer(minLength: 12)
                            PeriodBar(period: $app.cashPeriod)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            title
                            PeriodBar(period: $app.cashPeriod)
                        }
                    }
                    .padding(.bottom, 6)

                    let figures = figuresPanel(summary, code: snapshot.code)
                    let trendPanel = NetTrendPanel(points: trend, period: period, code: snapshot.code)
                    let transferPanel = transfersPanel(transfers, code: snapshot.code)
                    let statistics = FlowBarsPanel(buckets: buckets, summary: summary, period: period,
                                                   code: snapshot.code)
                    let table = SummaryTable(buckets: buckets, summary: summary, period: period, code: snapshot.code)
                    let categories = VStack(spacing: DS.gridGap) {
                        CategoryPanel(entries: snapshot.entries, period: period, code: snapshot.code,
                                      selection: $categorySelection)
                        if let selection = categorySelection {
                            Panel(title: selection.name) {
                                RecordList(transactions: transactions.filter {
                                    period.contains($0.date) && selection.matches($0)
                                }, showsDate: true, editing: $editing)
                            }
                        }
                    }
                    switch columns {
                    case 3:
                        HStack(alignment: .top, spacing: DS.gridGap) {
                            VStack(spacing: DS.gridGap) { figures; trendPanel; transferPanel }
                            VStack(spacing: DS.gridGap) { statistics; table }
                            categories
                        }
                    case 2:
                        HStack(alignment: .top, spacing: DS.gridGap) {
                            VStack(spacing: DS.gridGap) { figures; statistics; trendPanel; transferPanel }
                            VStack(spacing: DS.gridGap) { categories; table }
                        }
                    default:
                        figures; statistics; categories; table; trendPanel; transferPanel
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
        .onChange(of: app.cashPeriod) { _, _ in categorySelection = nil }
    }

    private func figuresPanel(_ summary: CashSummary, code: String) -> some View {
        let average = app.cashPeriod.unit == .month ? tr("Daily expense") : tr("Monthly expense")
        return Panel(title: tr("Expense & income")) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                StatTile(title: tr("Expense"), value: summary.expense, code: code)
                StatTile(title: tr("Income"), value: summary.income, code: code, color: FlowPalette.income)
                StatTile(title: tr("Balance"), value: summary.balance, code: code,
                         color: summary.balance >= 0 ? FlowPalette.income : FlowPalette.expense, signed: true)
                StatTile(title: average, value: summary.averageExpense, code: code)
                StatTile(title: tr("Refund"), value: summary.refund, code: code)
                StatTile(title: tr("Discount"), value: summary.discount, code: code)
                StatTile(title: tr("Fee"), value: summary.fee, code: code)
                StatTile(title: tr("Records"), value: Decimal(summary.count), code: "", isCount: true)
            }
        }
    }

    private func transfersPanel(_ transfers: [(label: String, amount: Decimal)], code: String) -> some View {
        Panel(title: tr("Between accounts")) {
            if transfers.isEmpty {
                Text(tr("No transfers in this period"))
                    .font(DS.caption)
                    .foregroundStyle(DS.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 50)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                          spacing: 8) {
                    ForEach(transfers, id: \.label) { item in
                        StatTile(title: tr(item.label), value: item.amount, code: code)
                    }
                }
            }
        }
    }
}

// MARK: - Summary table

struct SummaryTable: View {
    let buckets: [CashBucket]
    let summary: CashSummary
    let period: CashPeriod
    let code: String

    private var rows: [CashBucket] {
        buckets.filter { $0.expense != 0 || $0.income != 0 }.reversed()
    }

    private func label(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.current.locale
        formatter.setLocalizedDateFormatFromTemplate(period.unit == .month ? "Md" : "yMMM")
        return formatter.string(from: date)
    }

    var body: some View {
        Panel(title: period.unit == .month ? tr("Daily summary") : tr("Monthly summary")) {
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 9) {
                GridRow {
                    Text(tr("Date")).gridColumnAlignment(.leading)
                    Text(tr("Expense"))
                    Text(tr("Income"))
                    Text(tr("Balance"))
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(DS.textSecondary)
                Divider().overlay(DS.border)
                line(tr("Total"), summary.expense, summary.income, summary.balance, strong: true)
                line(tr("Average"), summary.averageExpense, summary.averageIncome, summary.averageBalance,
                     strong: true)
                Divider().overlay(DS.border.opacity(0.6))
                ForEach(rows) { bucket in
                    line(label(bucket.start), bucket.expense, bucket.income, bucket.balance, strong: false)
                }
            }
        }
    }

    private func line(_ title: String, _ expense: Decimal, _ income: Decimal, _ balance: Decimal,
                      strong: Bool) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(strong ? DS.textPrimary : DS.textSecondary)
                .gridColumnAlignment(.leading)
            Text(Fmt.money(expense, code)).foregroundStyle(DS.textPrimary)
            Text(Fmt.money(income, code)).foregroundStyle(income > 0 ? FlowPalette.income : DS.textTertiary)
            Text(Fmt.money(balance, code, showSign: true))
                .foregroundStyle(balance >= 0 ? FlowPalette.income : FlowPalette.expense)
        }
        .font(.system(size: 13, weight: strong ? .semibold : .regular).monospacedDigit())
        .lineLimit(1)
    }
}
