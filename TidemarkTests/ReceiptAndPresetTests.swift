import XCTest
import SwiftData
@testable import Tidemark

// Receipts become drafts, presets become records exactly once, and a
// reimbursement nets out of spending only when it has been paid back.

@MainActor
final class ReceiptAndPresetTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func makeContext() throws -> ModelContext {
        ModelContext(try TidemarkSchema.makeContainer(inMemory: true))
    }

    private func line(_ text: String, y: CGFloat, height: CGFloat = 0.02, x: CGFloat = 0.1) -> ReceiptLine {
        ReceiptLine(text: text, box: CGRect(x: x, y: y, width: 0.5, height: height))
    }

    // MARK: Receipts

    func testAlipayStyleBillDetail() {
        let bank = UUID(), wallet = UUID()
        let lines = [
            line("账单详情", y: 0.95),
            line("瑞幸咖啡", y: 0.85),
            line("-12.90", y: 0.78, height: 0.05),
            line("交易成功", y: 0.72),
            line("付款方式", y: 0.6), line("余额宝", y: 0.6, x: 0.6),
            line("创建时间", y: 0.5), line("2026-11-11 08:12:45", y: 0.5, x: 0.6),
        ]
        let draft = ReceiptReader.parse(lines, history: ["瑞幸咖啡": ("☕️DRINKS", "☕ Coffee")],
                                        accounts: [(bank, "BOC"), (wallet, "YEB")], timeZone: utc)
        XCTAssertEqual(draft.amount, Decimal(string: "12.90"))
        XCTAssertEqual(draft.kind, .expense)
        XCTAssertEqual(draft.note, "瑞幸咖啡")
        XCTAssertEqual(draft.paymentMethod, "余额宝")
        XCTAssertEqual(draft.accountID, wallet)
        XCTAssertEqual(draft.category, "☕️DRINKS")
        XCTAssertEqual(draft.subcategory, "☕ Coffee")
        XCTAssertEqual(draft.date, Date(timeIntervalSince1970: 1_794_384_765))
    }

    func testIncomeAndInlineMethod() {
        let lines = [
            line("某某公司", y: 0.8),
            line("+12,858.49", y: 0.7, height: 0.05),
            line("¥3.00", y: 0.4),
            line("支付方式：中国银行储蓄卡(4989)", y: 0.3),
            line("2026年11月10日 15:01", y: 0.2),
        ]
        let boc = UUID()
        let draft = ReceiptReader.parse(lines, accounts: [(boc, "BOC")], timeZone: utc)
        XCTAssertEqual(draft.amount, Decimal(string: "12858.49"), "the largest figure is the amount")
        XCTAssertEqual(draft.kind, .income)
        XCTAssertEqual(draft.accountID, boc)
        XCTAssertNotNil(draft.date)
    }

    func testNothingRecognizedGivesAnEmptyDraft() {
        let draft = ReceiptReader.parse([line("hello", y: 0.5)])
        XCTAssertNil(draft.amount)
        XCTAssertNil(draft.date)
        XCTAssertNil(draft.accountID)
    }

    // MARK: Schedules

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 9))!
    }

    func testMonthlyFromThe31stDoesNotDrift() {
        let start = day(2026, 1, 31)
        let dates = (0..<4).compactMap {
            PresetScheduler.occurrence($0, start: start, frequency: .monthly, endDate: nil, limit: nil, calendar: calendar)
        }
        XCTAssertEqual(dates.map { calendar.component(.day, from: $0) }, [31, 28, 31, 30])
    }

    func testDueRespectsLimitEndAndWhatIsDone() {
        let start = day(2026, 1, 15)
        let due = PresetScheduler.due(start: start, frequency: .monthly, endDate: nil, limit: 3,
                                      generatedThrough: -1, now: day(2026, 12, 1), calendar: calendar)
        XCTAssertEqual(due.map(\.index), [0, 1, 2])
        let later = PresetScheduler.due(start: start, frequency: .monthly, endDate: day(2026, 4, 1), limit: nil,
                                        generatedThrough: 0, now: day(2026, 12, 1), calendar: calendar)
        XCTAssertEqual(later.map(\.index), [1, 2], "Feb and Mar; April 15 is past the end")
    }

    func testRunWritesEachOccurrenceOnce() throws {
        let context = try makeContext()
        let bank = Account(name: "Bank", kind: .payment)
        context.insert(bank)
        let rent = RecordPreset(name: "Rent", kind: .expense, amount: 3000)
        rent.category = "🏡ACCOM."
        rent.accountID = bank.id
        rent.schedule = .monthly
        rent.startDate = Calendar.current.date(byAdding: .month, value: -2, to: Date())!
        context.insert(rent)
        let plan = RecordPreset(name: "Phone", kind: .liabilityPayment, amount: 500)
        plan.schedule = .monthly
        plan.occurrenceLimit = 2
        plan.startDate = Calendar.current.date(byAdding: .month, value: -5, to: Date())!
        context.insert(plan)
        let template = RecordPreset(name: "Coffee", kind: .expense, amount: 12)
        context.insert(template)
        try context.save()

        XCTAssertEqual(PresetScheduler.run(in: context), 5, "3 rent (two months ago, last month, this month) + 2 instalments")
        XCTAssertEqual(PresetScheduler.run(in: context), 0, "running again adds nothing")
        let records = try context.fetch(FetchDescriptor<Tidemark.Transaction>())
        XCTAssertEqual(records.filter { $0.presetID == rent.id }.count, 3)
        XCTAssertTrue(records.filter { $0.presetID == rent.id }.allSatisfy { $0.account?.id == bank.id })
        XCTAssertEqual(records.filter { $0.presetID == plan.id }.map(\.note).sorted(), ["1/2", "2/2"])
        XCTAssertFalse(plan.isActive, "a finished instalment plan stops")
        XCTAssertTrue(records.allSatisfy { $0.presetID != template.id }, "templates never write records")

        // A deleted occurrence is not written again.
        context.delete(records.first { $0.presetID == rent.id }!)
        try context.save()
        XCTAssertEqual(PresetScheduler.run(in: context), 0)
    }

    func testPresetFieldsRoundTrip() throws {
        let context = try makeContext()
        let source = RecordPreset(name: "Loan", kind: .liabilityPayment, amount: Decimal(string: "833.33")!)
        source.schedule = .monthly
        source.occurrenceLimit = 12
        source.generatedThrough = 4
        source.accountID = UUID()
        source.endDate = Date(timeIntervalSince1970: 1_800_000_000)
        let copy = RecordPreset(name: "", kind: .expense, amount: 0)
        [source, copy].forEach(context.insert)
        SyncCodec.apply(SyncCodec.fields(of: source), to: copy)
        XCTAssertEqual(SyncCodec.fields(of: copy), SyncCodec.fields(of: source))
        // generatedThrough never goes backwards.
        var older = SyncCodec.fields(of: source)
        older["through"] = "1"
        SyncCodec.apply(older, to: copy)
        XCTAssertEqual(copy.generatedThrough, 4)
    }

    // MARK: Reimbursement

    func testReimbursementCountsOnlyOncePaidBack() throws {
        let context = try makeContext()
        let bank = Account(name: "Bank", kind: .payment, openingBalance: 1000)
        context.insert(bank)
        let taxi = Tidemark.Transaction(date: Date(), kind: .expense, amount: 100, account: bank)
        taxi.claimStatus = .pending
        context.insert(taxi)
        let converter = CurrencyConverter(rates: [], base: "CNY")
        XCTAssertEqual(taxi.netAmount, 100)
        XCTAssertEqual(taxi.cashEntry(using: converter).claimPending, 100)
        taxi.claimStatus = .claimed
        taxi.claimAmount = 80
        XCTAssertEqual(taxi.netAmount, 20)
        XCTAssertEqual(taxi.cashEntry(using: converter).base, 20)
        XCTAssertEqual(taxi.cashEntry(using: converter).claimed, 80)
        XCTAssertEqual(taxi.movements(using: converter).map(\.delta), [-20], "the money came back to the account")
    }
}
