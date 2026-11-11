import XCTest
import SwiftData
@testable import Tidemark

// End-to-end on a REAL bookkeeping export: read the workbook, import it, and
// compare a month's totals with what the source app itself shows. The export
// and the expected figures are personal, so both are local, git-ignored
// fixtures (`ledger-fixture-export.xlsx`, `ledger-fixture-expected.json`):
// {"rows": 123, "month": "2026-01", "expense": "100.00", "income": "200.00",
//  "topCategories": [{"name": "…", "amount": "50.00"}]}

@MainActor
final class LedgerLiveExportTests: XCTestCase {
    private struct Expected: Decodable {
        struct Category: Decodable { let name: String; let amount: String }
        let rows: Int
        let month: String
        let expense: String
        let income: String
        let topCategories: [Category]
    }

    func testRealExportEndToEnd() throws {
        let bundle = Bundle(for: Self.self)
        guard let workbook = bundle.url(forResource: "ledger-fixture-export", withExtension: "xlsx"),
              let expectedURL = bundle.url(forResource: "ledger-fixture-expected", withExtension: "json") else {
            throw XCTSkip("ledger fixtures are not in the test bundle (local-only)")
        }
        let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: expectedURL))
        func decimal(_ text: String) -> Decimal { Decimal(string: text)! }

        let context = ModelContext(try TidemarkSchema.makeContainer(inMemory: true))
        CurrencyService.ensureSeeds(in: context)
        let stats = try LedgerExportImporter.importFile(at: workbook, into: context)
        XCTAssertEqual(stats.inserted, expected.rows, "every row of the export becomes a record")
        XCTAssertEqual(stats.rejected, 0)
        XCTAssertEqual(stats.skipped, 0)

        let again = try LedgerExportImporter.importFile(at: workbook, into: context)
        XCTAssertEqual(again.inserted, 0, "a second import adds nothing")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Transaction>()), expected.rows)

        let records = try context.fetch(FetchDescriptor<Transaction>())
        let converter = CurrencyConverter(rates: try context.fetch(FetchDescriptor<CurrencyRate>()), base: "CNY")
        let entries = records.map { $0.cashEntry(using: converter) }
        let parts = expected.month.split(separator: "-").compactMap { Int($0) }
        let anchor = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: 15))!
        let period = CashPeriod(unit: .month, containing: anchor)

        let summary = CashflowAnalytics.summary(entries, in: period)
        XCTAssertEqual(summary.expense, decimal(expected.expense))
        XCTAssertEqual(summary.income, decimal(expected.income))

        let categories = CashflowAnalytics.categories(entries, kind: .expense, level: .first, in: period)
        for (index, category) in expected.topCategories.enumerated() {
            XCTAssertEqual(categories[index].name, category.name)
            XCTAssertEqual(categories[index].amount, decimal(category.amount))
        }
    }
}
