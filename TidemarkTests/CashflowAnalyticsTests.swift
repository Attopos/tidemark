import XCTest
@testable import Tidemark

// Every figure on the cash-flow pages, on hand-checkable numbers.

final class CashflowAnalyticsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func entry(_ date: Date, _ kind: TransactionKind, _ amount: Decimal,
                       _ category: String = "", _ subcategory: String = "",
                       refund: Decimal = 0, excluded: Bool = false) -> CashEntry {
        CashEntry(id: UUID(), date: date, kind: kind, category: category, subcategory: subcategory,
                  base: amount, refund: refund, excluded: excluded)
    }

    private var march: CashPeriod { CashPeriod(unit: .month, containing: day(2026, 3, 15), calendar: calendar) }

    private var entries: [CashEntry] {
        [
            entry(day(2026, 3, 1), .expense, 30, "Food", "Lunch"),
            entry(day(2026, 3, 1), .expense, 20, "Food", "Coffee"),
            entry(day(2026, 3, 2), .expense, 50, "Transport"),
            entry(day(2026, 3, 2), .income, 1000, "Salary"),
            entry(day(2026, 3, 3), .transfer, 500, "Transfer"),
            entry(day(2026, 3, 3), .liabilityPayment, 200, "Repayment"),
            entry(day(2026, 3, 4), .expense, 999, "Food", excluded: true),
            entry(day(2026, 2, 10), .expense, 80, "Food", "Lunch"),
            entry(day(2026, 2, 11), .expense, 70, "Transport"),
            entry(day(2026, 4, 1, hour: 0), .expense, 5, "Food"),
        ]
    }

    func testPeriodBounds() {
        XCTAssertEqual(march.start, day(2026, 3, 1, hour: 0))
        XCTAssertEqual(march.end(calendar), day(2026, 4, 1, hour: 0))
        XCTAssertEqual(march.bucketStarts(calendar).count, 31)
        XCTAssertEqual(march.shifted(by: -1, calendar: calendar).start, day(2026, 2, 1, hour: 0))
        let year = CashPeriod(unit: .year, containing: day(2026, 3, 15), calendar: calendar)
        XCTAssertEqual(year.bucketStarts(calendar).count, 12)
        XCTAssertFalse(march.contains(day(2026, 4, 1, hour: 0), calendar: calendar), "the end is exclusive")
    }

    func testSummaryCountsOnlyIncomeAndExpense() {
        let summary = CashflowAnalytics.summary(entries, in: march, now: day(2026, 3, 10), calendar: calendar)
        XCTAssertEqual(summary.expense, 100)
        XCTAssertEqual(summary.income, 1000)
        XCTAssertEqual(summary.balance, 900)
        XCTAssertEqual(summary.count, 4)
    }

    func testAverageDividesByDaysThatHaveStarted() {
        let midMonth = CashflowAnalytics.summary(entries, in: march, now: day(2026, 3, 10), calendar: calendar)
        XCTAssertEqual(midMonth.elapsedBuckets, 10)
        XCTAssertEqual(midMonth.averageExpense, 10)
        let later = CashflowAnalytics.summary(entries, in: march, now: day(2026, 6, 1), calendar: calendar)
        XCTAssertEqual(later.elapsedBuckets, 31)
        let before = CashflowAnalytics.summary(entries, in: march, now: day(2026, 1, 1), calendar: calendar)
        XCTAssertEqual(before.averageExpense, 0)
    }

    func testBucketsPerDayAndPerMonth() {
        let days = CashflowAnalytics.buckets(entries, in: march, calendar: calendar)
        XCTAssertEqual(days.count, 31)
        XCTAssertEqual(days[0].expense, 50)
        XCTAssertEqual(days[1].expense, 50)
        XCTAssertEqual(days[1].income, 1000)
        XCTAssertEqual(days[1].balance, 950)
        XCTAssertEqual(days[2].expense, 0, "transfers are not spending")
        XCTAssertEqual(days[3].expense, 0, "excluded records stay out")

        let year = CashPeriod(unit: .year, containing: day(2026, 3, 15), calendar: calendar)
        let months = CashflowAnalytics.buckets(entries, in: year, calendar: calendar)
        XCTAssertEqual(months.map(\.expense), [0, 150, 100, 5, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testCategoriesWithShareCountAndChange() {
        let first = CashflowAnalytics.categories(entries, kind: .expense, level: .first, in: march, calendar: calendar)
        XCTAssertEqual(first.map(\.name), ["Food", "Transport"], "ties break by name")
        XCTAssertEqual(first.map(\.amount), [50, 50])
        XCTAssertEqual(first.map(\.count), [2, 1])
        XCTAssertEqual(first[0].share, 0.5, accuracy: 0.0001)
        XCTAssertEqual(first[0].change, -30, "Food was 80 the month before")
        XCTAssertEqual(first[1].change, -20)

        let second = CashflowAnalytics.categories(entries, kind: .expense, level: .second, in: march, calendar: calendar)
        XCTAssertEqual(second.map(\.name), ["Transport", "Lunch", "Coffee"],
                       "a record without a second level keeps its first-level name")
        XCTAssertEqual(second.first { $0.name == "Lunch" }?.change, -50)

        let income = CashflowAnalytics.categories(entries, kind: .income, level: .first, in: march, calendar: calendar)
        XCTAssertEqual(income.map(\.name), ["Salary"])
    }

    func testTransfersByLabel() {
        let transfers = CashflowAnalytics.transfers(entries, in: march, calendar: calendar)
        XCTAssertEqual(transfers.map(\.label), ["Transfer", "Repayment"])
        XCTAssertEqual(transfers.map(\.amount), [500, 200])
    }

    // MARK: Account balances

    private var converter: CurrencyConverter {
        CurrencyConverter(rates: [CurrencyRate(code: "USD", rate: 7, date: day(2020, 1, 1)),
                                  CurrencyRate(code: "THB", rate: Decimal(string: "0.2")!, date: day(2020, 1, 1))],
                          base: "CNY")
    }

    func testMovementsPerKind() {
        let bank = UUID(), wallet = UUID()
        func moves(_ kind: TransactionKind, refund: Decimal = 0, to: UUID? = nil) -> [AccountMovement] {
            AccountLedger.movements(kind: kind, amount: 100, refund: refund, currency: "CNY", date: day(2026, 3, 1),
                                    source: (bank, "CNY"), destination: to.map { ($0, "CNY") }, arrival: nil,
                                    converter: converter)
        }
        XCTAssertEqual(moves(.expense).map(\.delta), [-100])
        XCTAssertEqual(moves(.expense, refund: 30).map(\.delta), [-70])
        XCTAssertEqual(moves(.income).map(\.delta), [100])
        XCTAssertEqual(moves(.transfer, to: wallet).map(\.delta), [-100, 100])
        XCTAssertEqual(moves(.transfer, to: wallet).map(\.account), [bank, wallet])
        XCTAssertTrue(moves(.transfer, to: bank).isEmpty, "a transfer to itself changes nothing")
    }

    func testCrossCurrencyMovements() {
        let card = UUID(), cash = UUID()
        // A THB purchase paid from a CNY card.
        let purchase = AccountLedger.movements(kind: .expense, amount: 500, refund: 0, currency: "THB",
                                               date: day(2026, 3, 1), source: (card, "CNY"), destination: nil,
                                               arrival: nil, converter: converter)
        XCTAssertEqual(purchase.map(\.delta), [-100])
        // CNY changed into USD cash at the dated rate…
        let exchange = AccountLedger.movements(kind: .transfer, amount: 700, refund: 0, currency: "CNY",
                                               date: day(2026, 3, 1), source: (card, "CNY"),
                                               destination: (cash, "USD"), arrival: nil, converter: converter)
        XCTAssertEqual(exchange.map(\.delta), [-700, 100])
        // …or at the amount that actually arrived.
        let actual = AccountLedger.movements(kind: .transfer, amount: 700, refund: 0, currency: "CNY",
                                             date: day(2026, 3, 1), source: (card, "CNY"),
                                             destination: (cash, "USD"), arrival: 98, converter: converter)
        XCTAssertEqual(actual.map(\.delta), [-700, 98])
    }

    func testBalancesNetAssetsAndTrend() {
        let bank = LedgerAccount(id: UUID(), currency: "CNY", opening: 1000, isLiability: false, countsInNetWorth: true)
        let dollars = LedgerAccount(id: UUID(), currency: "USD", opening: 10, isLiability: false, countsInNetWorth: true)
        let card = LedgerAccount(id: UUID(), currency: "CNY", opening: 0, isLiability: true, countsInNetWorth: true)
        let gift = LedgerAccount(id: UUID(), currency: "CNY", opening: 500, isLiability: false, countsInNetWorth: false)
        let accounts = [bank, dollars, card, gift]
        let movements = [
            AccountMovement(account: bank.id, date: day(2026, 3, 2), delta: -100),
            AccountMovement(account: card.id, date: day(2026, 3, 3), delta: -250),
            AccountMovement(account: bank.id, date: day(2026, 3, 5), delta: 400),
        ]
        let balances = AccountLedger.balances(accounts: accounts, movements: movements)
        XCTAssertEqual(balances[bank.id], 1300)
        XCTAssertEqual(balances[card.id], -250)
        XCTAssertEqual(AccountLedger.balances(accounts: accounts, movements: movements, at: day(2026, 3, 2))[bank.id], 900)

        let totals = AccountLedger.netAssets(accounts: accounts, balances: balances, converter: converter)
        XCTAssertEqual(totals.assets, 1370, "1300 CNY + 10 USD at 7; the uncounted account stays out")
        XCTAssertEqual(totals.debts, 250)

        let trend = AccountLedger.trend(accounts: accounts, movements: movements, period: march,
                                        converter: converter, now: day(2026, 3, 6), calendar: calendar)
        XCTAssertEqual(trend.count, 6, "only days that have started")
        XCTAssertEqual(trend.map(\.net), [1070, 970, 720, 720, 1120, 1120])
    }
}
