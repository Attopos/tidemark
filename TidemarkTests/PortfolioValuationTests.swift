import XCTest
import SwiftData
@testable import Tidemark

// A total is the whole portfolio at one moment: every holding carried
// forward from its last valuation, sold holdings at zero, converted with the
// rate of that moment.

final class PortfolioValuationTests: XCTestCase {
    private let calendar = Calendar.current

    private func day(_ offset: Int) -> Date {
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_750_000_000))!
        return calendar.date(byAdding: .day, value: offset, to: noon)!
    }

    private func converter(base: String = "CNY", usd: [(Int, Decimal)] = []) -> CurrencyConverter {
        CurrencyConverter(rates: usd.map { CurrencyRate(code: "USD", rate: $0.1, date: day($0.0)) }, base: base)
    }

    private func input(_ points: [(Int, Decimal)], currency: String = "CNY") -> ValuationInput {
        ValuationInput(id: UUID(), currency: currency,
                       points: points.map { ValuationPoint(date: day($0.0), value: $0.1) })
    }

    func testHistoryCarriesEachHoldingForward() {
        let a = input([(1, 100), (3, 120)])
        let b = input([(2, 50)])
        let history = PortfolioValuation.history(inputs: [a, b], converter: converter(), calendar: calendar)
        XCTAssertEqual(history.map(\.total), [100, 150, 170])
    }

    func testSoldHoldingStopsCountingButKeepsItsPast() {
        let kept = input([(1, 100)])
        let sold = input([(1, 40), (2, 0)])
        let history = PortfolioValuation.history(inputs: [kept, sold], converter: converter(), calendar: calendar)
        XCTAssertEqual(history.map(\.total), [140, 100])
    }

    func testValuationIgnoresLaterPoints() {
        let a = input([(1, 100), (5, 999)])
        let valuation = PortfolioValuation(inputs: [a], converter: converter(), asOf: day(3), calendar: calendar)
        XCTAssertEqual(valuation.total, 100)
        XCTAssertEqual(valuation.position(a.id)?.date, day(1))
    }

    func testCarriedValueUsesTheRateOfTheMoment() {
        // 10 USD recorded on day 1; the rate moves on day 3.
        let usd = input([(1, 10)], currency: "USD")
        let cny = input([(4, 1)])
        let history = PortfolioValuation.history(inputs: [usd, cny],
                                                 converter: converter(usd: [(0, 7), (3, 8)]),
                                                 calendar: calendar)
        XCTAssertEqual(history.map(\.total), [70, 81])
    }

    func testProfitUsesOnlyPositionsThatReportOne() {
        let withProfit = ValuationInput(id: UUID(), points: [ValuationPoint(date: day(1), value: 110, unrealizedPL: 10)])
        let without = input([(1, 90)])
        let profit = PortfolioValuation(inputs: [withProfit, without], converter: converter()).profit
        XCTAssertEqual(profit?.profit, 10)
        XCTAssertEqual(profit?.cost, 100)
        XCTAssertEqual(profit?.rate ?? 0, 0.10, accuracy: 1e-9)
        XCTAssertEqual(profit?.coverage ?? 0, 0.55, accuracy: 1e-9)
        XCTAssertNil(PortfolioValuation(inputs: [without], converter: converter()).profit)
    }

    func testFreshnessWeighsStaleValue() {
        let fresh = input([(10, 75)])
        let stale = input([(0, 25)])
        let valuation = PortfolioValuation(inputs: [fresh, stale], converter: converter(), asOf: day(10), calendar: calendar)
        let freshness = valuation.freshness(staleAfterDays: 7)
        XCTAssertEqual(freshness.staleShare, 0.25, accuracy: 1e-9)
        XCTAssertEqual(freshness.oldest, day(0))
    }

    func testDriftBandFollowsTheFiveTwentyFiveRule() {
        XCTAssertFalse(AllocationDrift(target: 0.40, actual: 0.44).outOfBand)
        XCTAssertTrue(AllocationDrift(target: 0.40, actual: 0.46).outOfBand)
        XCTAssertFalse(AllocationDrift(target: 0.10, actual: 0.12).outOfBand)
        XCTAssertTrue(AllocationDrift(target: 0.10, actual: 0.07).outOfBand)
    }
}

// Import review: nothing uncertain is applied silently, and a holding that
// left the account is closed with its history intact.

@MainActor
final class ImportReviewTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        ModelContext(try TidemarkSchema.makeContainer(inMemory: true))
    }

    private func editable(name: String, value: String,
                          matched: Holding? = nil) -> ScreenshotImportSession.EditableHolding {
        ScreenshotImportSession.EditableHolding(
            name: name, code: "", marketValue: value, profit: "", returnRatePercent: "",
            quantity: "", unitNAV: "", costBasis: "", flaggedFields: [], sourceBox: .zero,
            matchedHoldingID: matched?.id, matchedLabel: matched.map { $0.asset?.name ?? "" })
    }

    private func draft(_ name: String) -> HoldingDraft {
        HoldingDraft(name: name, code: nil, nameConfidence: 1, box: .zero)
    }

    /// Two funds imported three days ago.
    private func seed(_ context: ModelContext) throws -> [Holding] {
        let first = ScreenshotImportSession(images: [])
        first.valuationDate = Date(timeIntervalSinceNow: -3 * 86_400)
        first.holdings = [editable(name: "某某沪深300ETF联接", value: "1000"),
                          editable(name: "某某纯债债券A", value: "500")]
        first.commit(into: context)
        return try context.fetch(FetchDescriptor<Holding>())
    }

    func testSimilarNameIsSuggestedNeverMatched() throws {
        let context = try makeContext()
        let existing = try seed(context)
        let shareClassC = draft("某某沪深300ETF联接C")
        XCTAssertNil(ScreenshotImportSession.match(draft: shareClassC, in: existing),
                     "another share class is a different fund")
        XCTAssertEqual(ScreenshotImportSession.suggest(draft: shareClassC, in: existing)?.asset?.name,
                       "某某沪深300ETF联接")
        XCTAssertNil(ScreenshotImportSession.suggest(draft: draft("某某沪深300ETF联接"), in: existing),
                     "an exact name is a match, not a suggestion")
    }

    func testHoldingMissingFromScreenshotIsClosedWithHistory() throws {
        let context = try makeContext()
        let existing = try seed(context)
        let kept = try XCTUnwrap(existing.first { $0.asset?.name == "某某沪深300ETF联接" })
        let gone = try XCTUnwrap(existing.first { $0.asset?.name == "某某纯债债券A" })

        let second = ScreenshotImportSession(images: [])
        second.holdings = [editable(name: "某某沪深300ETF联接", value: "1100", matched: kept)]
        second.missing = ScreenshotImportSession.missingHoldings(existing: existing, imported: second.holdings,
                                                                 verifiedPlatform: .alipay)
        XCTAssertEqual(second.missing.map(\.id), [gone.id])
        XCTAssertEqual(second.missing.first?.close, true, "a verified total proves the fund left the account")
        second.commit(into: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Holding>()).count, 2, "sold holdings are kept")
        XCTAssertFalse(gone.isActive)
        XCTAssertEqual(gone.snapshots.count, 2)
        XCTAssertEqual(gone.snapshots.max(by: { $0.date < $1.date })?.marketValue, 0)
        XCTAssertTrue(kept.isActive)
    }

    func testUnverifiedImportLeavesMissingHoldingsAlone() throws {
        let context = try makeContext()
        let existing = try seed(context)
        let kept = try XCTUnwrap(existing.first { $0.asset?.name == "某某沪深300ETF联接" })

        let second = ScreenshotImportSession(images: [])
        second.holdings = [editable(name: "某某沪深300ETF联接", value: "1100", matched: kept)]
        second.missing = ScreenshotImportSession.missingHoldings(existing: existing, imported: second.holdings,
                                                                 verifiedPlatform: nil)
        XCTAssertEqual(second.missing.first?.close, false, "a partial screenshot must not sell anything")
        second.commit(into: context)
        XCTAssertTrue(existing.allSatisfy(\.isActive))
    }

    func testReimportReopensASoldHolding() throws {
        let context = try makeContext()
        let existing = try seed(context)
        let fund = try XCTUnwrap(existing.first { $0.asset?.name == "某某纯债债券A" })
        fund.close(on: Date(timeIntervalSinceNow: -86_400), source: .manual, in: context)
        try context.save()
        XCTAssertFalse(fund.isActive)

        let match = ScreenshotImportSession.match(draft: draft("某某纯债债券A"), in: existing)
        XCTAssertEqual(match?.id, fund.id)
        let again = ScreenshotImportSession(images: [])
        again.holdings = [editable(name: "某某纯债债券A", value: "800", matched: match)]
        again.commit(into: context)

        XCTAssertTrue(fund.isActive)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Holding>()).count, 2, "reopened, not duplicated")
        XCTAssertEqual(fund.snapshots.count, 3)
    }

    func testChecksumComparesRowsWithTheAccountTotal() {
        let session = ScreenshotImportSession(images: [])
        session.holdings = [editable(name: "某某沪深300ETF联接", value: "1,000.40"),
                            editable(name: "某某纯债债券A", value: "500")]
        XCTAssertNil(session.checksum, "no total on the screenshot, nothing to check")
        session.accountTotalPlatform = .alipay
        session.accountTotal = Decimal(string: "1500.40")
        XCTAssertEqual(session.checksum?.matches, true)
        session.accountTotal = 2300
        XCTAssertEqual(session.checksum?.matches, false)
        XCTAssertEqual(session.checksum?.rowsSum, Decimal(string: "1500.40"))
    }
}
