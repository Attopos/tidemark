import XCTest
import SwiftData
@testable import Tidemark

@MainActor
final class LedgerExportWriterTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private let sample: [[String]] = [
        LedgerExportWriter.header,
        ["2026/03/01 08:00:00", "Expense", "-18.8", "Food", "Breakfast", "Wallet", "", "bun & <tea>", "CNY", "", "AC.", "Street 1", "", "", "", "", "", "", "", "", ""],
        ["2026/03/01 09:00:00", "Income", "80", "Salary", "", "Bank", "", "", "CNY", "", "AC.", "", "", "", "", "", "", "", "", "", ""],
        ["2026/03/02 10:00:00", "Transfer", "300", "Transfer", "", "Bank", "Wallet", "", "CNY", "", "AC.", "", "", "", "", "", "", "", "", "", ""],
        ["2026/03/03 11:00:00", "Repayment", "120", "Repayment", "", "Bank", "Visa Credit", "", "CNY", "", "AC.", "", "", "", "", "", "", "", "", "", ""],
        ["2026/03/04 12:00:00", "Lend", "50", "Transfer", "", "Bank", "Friend", "", "CNY", "", "AC.", "", "", "", "", "", "", "", "", "", ""],
        ["2026/03/05 13:00:00", "Expense", "-100", "Travel", "", "Baht Cash", "", "", "THB", "", "AC.", "", "40", "", "1.5", "", "", "", "", "", ""],
        ["2026/03/05 13:00:00", "Expense", "-100", "Travel", "", "Baht Cash", "", "", "THB", "", "AC.", "", "40", "", "1.5", "", "", "", "", "", ""],
    ]

    private func imported(_ sheet: [[String]]) throws -> (ModelContext, [Transaction]) {
        let context = ModelContext(try TidemarkSchema.makeContainer(inMemory: true))
        let parsed = try LedgerExportImporter.parse(rows: sheet, timeZone: utc)
        try LedgerExportImporter.commit(parsed, fileName: nil, into: context)
        return (context, try context.fetch(FetchDescriptor<Transaction>()))
    }

    func testWritesICostLayout() throws {
        let (_, records) = try imported(sample)
        let rows = LedgerExportWriter.rows(for: records, timeZone: utc)
        XCTAssertEqual(rows, sample)
    }

    func testWorkbookReadsBackAsTheSameRecords() throws {
        let (_, records) = try imported(sample)
        let data = LedgerExportWriter.workbook(for: records, timeZone: utc)
        let sheet = try XLSXReader.firstSheetRows(of: data)
        XCTAssertEqual(sheet, sample)

        let original = try LedgerExportImporter.parse(rows: sample, timeZone: utc).rows
        let again = try LedgerExportImporter.parse(rows: sheet, timeZone: utc).rows
        XCTAssertEqual(again.map(\.date), original.map(\.date))
        XCTAssertEqual(LedgerExportImporter.fingerprints(for: again), LedgerExportImporter.fingerprints(for: original))

        let zip = try ZipArchive(data: data)
        let workbook = String(decoding: try zip.contents(of: "xl/workbook.xml"), as: UTF8.self)
        XCTAssertTrue(workbook.contains("name=\"收支账单\""))
    }

    func testReimportAddsNothing() throws {
        let (context, records) = try imported(sample)
        let sheet = try XLSXReader.firstSheetRows(of: LedgerExportWriter.workbook(for: records, timeZone: utc))
        let stats = try LedgerExportImporter.commit(try LedgerExportImporter.parse(rows: sheet, timeZone: utc),
                                                    fileName: nil, into: context)
        XCTAssertEqual(stats.inserted, 0)
        XCTAssertEqual(stats.skipped, sample.count - 1)
    }

    func testRealExportRoundTrip() throws {
        guard let url = Bundle(for: Self.self).url(forResource: "ledger-fixture-export", withExtension: "xlsx") else {
            throw XCTSkip("ledger fixture is not in the test bundle (local-only)")
        }
        let source = try XLSXReader.firstSheetRows(at: url)
        let context = ModelContext(try TidemarkSchema.makeContainer(inMemory: true))
        try LedgerExportImporter.importFile(at: url, into: context)
        let records = try context.fetch(FetchDescriptor<Transaction>())
        let written = try XLSXReader.firstSheetRows(of: LedgerExportWriter.workbook(for: records))

        XCTAssertEqual(written.first, source.first)
        let amounts = Set([12, 13, 14])
        func normalized(_ rows: [[String]]) -> [String] {
            rows.dropFirst().map { row in
                row.enumerated().map { index, cell in
                    let text = cell.trimmingCharacters(in: .whitespaces)
                    guard index == 2 || amounts.contains(index), let value = Decimal(string: text) else { return text }
                    return amounts.contains(index) && value == 0 ? "" : "\(value)"
                }.joined(separator: "\u{1F}")
            }.sorted()
        }
        let out = normalized(written), expected = normalized(source)
        XCTAssertEqual(out.count, expected.count)
        let missing = Set(expected).subtracting(out), extra = Set(out).subtracting(expected)
        XCTAssertTrue(missing.isEmpty && extra.isEmpty,
                      "missing: \(missing.sorted().prefix(3)) extra: \(extra.sorted().prefix(3))")
    }
}
