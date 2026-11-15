import XCTest
import SwiftData
@testable import Tidemark

@MainActor
final class LedgerExportWriterTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private let icostExport: [[String]] = [
        ["Date", "Type", "Amount", "First-Level Category", "Second-Level Category", "Account 1", "Account 2", "Remark",
         "Currency", "Tag", "Ledger", "Address", "Refund", "Discount", "Fee", "Image 1", "Image 2", "Image 3",
         "Attachment 1", "Attachment 2", "Attachment 3"],
        ["2026/03/01 08:00:00", "Expense", "-18.8", "Food", "Breakfast", "Wallet", "", "bun & <tea>", "CNY", "", "AC.", "Street 1", "", "", "", "", "", "", "", "", ""],
        ["2026/03/01 09:00:00", "Income", "80", "Salary", "", "Bank", "", "", "CNY", "", "AC.", "", "", "", "", "", "", "", "", "", ""],
        ["2026/03/02 10:00:00", "Transfer", "300", "Transfer", "", "Bank", "Wallet", "", "CNY", "", "AC.", "", "", "", "", "", "", "", "", "", ""],
        ["2026/03/03 11:00:00", "Repayment", "120", "Repayment", "", "Bank", "Visa Credit", "", "CNY", "", "AC.", "", "", "", "", "", "", "", "", "", ""],
        ["2026/03/04 12:00:00", "Lend", "50", "Transfer", "", "Bank", "Friend", "", "CNY", "", "AC.", "", "", "", "", "", "", "", "", "", ""],
        ["2026/03/05 13:00:00", "Expense", "-100", "Travel", "", "Baht Cash", "", "", "THB", "", "AC.", "", "", "", "", "", "", "", "", "", ""],
        ["2026/03/05 13:00:00", "Expense", "-100", "Travel", "", "Baht Cash", "", "", "THB", "", "AC.", "", "", "", "", "", "", "", "", "", ""],
    ]

    private let template: [[String]] = [
        ["日期", "类型", "金额", "一级分类", "二级分类", "账户1", "账户2", "备注", "货币", "标签"],
        ["2026年03月01日 08:00:00", "支出", "18.8", "Food", "Breakfast", "Wallet", "", "bun & <tea>", "CNY", ""],
        ["2026年03月01日 09:00:00", "收入", "80", "Salary", "", "Bank", "", "", "CNY", ""],
        ["2026年03月02日 10:00:00", "转账", "300", "Transfer", "", "Bank", "Wallet", "", "CNY", ""],
        ["2026年03月03日 11:00:00", "转账", "120", "Repayment", "", "Bank", "Visa Credit", "", "CNY", ""],
        ["2026年03月04日 12:00:00", "转账", "50", "Lend", "", "Bank", "Friend", "", "CNY", ""],
        ["2026年03月05日 13:00:00", "支出", "100", "Travel", "", "Baht Cash", "", "", "THB", ""],
        ["2026年03月05日 13:00:00", "支出", "100", "Travel", "", "Baht Cash", "", "", "THB", ""],
    ]

    private func store() throws -> ModelContext {
        ModelContext(try TidemarkSchema.makeContainer(inMemory: true))
    }

    private func imported(_ sheet: [[String]], into context: ModelContext) throws -> [Transaction] {
        try LedgerExportImporter.commit(try LedgerExportImporter.parse(rows: sheet, timeZone: utc),
                                        fileName: nil, into: context)
        return try context.fetch(FetchDescriptor<Transaction>())
    }

    func testWritesTheICostImportTemplate() throws {
        let records = try imported(icostExport, into: try store())
        XCTAssertEqual(LedgerExportWriter.rows(for: records, timeZone: utc), template)
    }

    func testWorkbookIsOneTemplateSheetWithNumericAmounts() throws {
        let records = try imported(icostExport, into: try store())
        let data = LedgerExportWriter.workbook(for: records, timeZone: utc)
        XCTAssertEqual(try XLSXReader.firstSheetRows(of: data), template)
        let zip = try ZipArchive(data: data)
        let workbook = String(decoding: try zip.contents(of: "xl/workbook.xml"), as: UTF8.self)
        XCTAssertTrue(workbook.contains("name=\"icost_template\""))
        let sheet = String(decoding: try zip.contents(of: "xl/worksheets/sheet1.xml"), as: UTF8.self)
        XCTAssertTrue(sheet.contains("<c r=\"C2\" s=\"2\"><v>18.8</v></c>"), "amounts are number cells, as in the template")
    }

    func testTemplateReadsBackAsTheSameRecords() throws {
        let original = try LedgerExportImporter.parse(rows: icostExport, timeZone: utc).rows
        let again = try LedgerExportImporter.parse(rows: template, timeZone: utc).rows
        XCTAssertEqual(again.map(\.type), original.map(\.type))
        XCTAssertEqual(again.map(\.typeLabel), original.map(\.typeLabel))
        XCTAssertEqual(again.map(\.category), original.map(\.category))
        XCTAssertEqual(LedgerExportImporter.fingerprints(for: again), LedgerExportImporter.fingerprints(for: original),
                       "the same record from either file is recognized as the same")
    }

    func testReimportingTheExportAddsNothing() throws {
        let context = try store()
        let records = try imported(icostExport, into: context)
        let sheet = try XLSXReader.firstSheetRows(of: LedgerExportWriter.workbook(for: records, timeZone: utc))
        let stats = try LedgerExportImporter.commit(try LedgerExportImporter.parse(rows: sheet, timeZone: utc),
                                                    fileName: nil, into: context)
        XCTAssertEqual(stats.inserted, 0)
        XCTAssertEqual(stats.updated, 0)
        XCTAssertEqual(stats.skipped, icostExport.count - 1)
    }

    func testEditedRecordIsUpdatedNotDuplicated() throws {
        let context = try store()
        _ = try imported(icostExport, into: context)
        var edited = icostExport
        edited[2][2] = "95"
        edited[2][7] = "bonus"
        edited.append(["2026/03/06 09:00:00", "Expense", "-5", "Food", "", "Wallet", "", "", "CNY", "", "AC.", "", "", "", "", "", "", "", "", "", ""])
        edited.remove(at: 3)
        let parsed = try LedgerExportImporter.parse(rows: edited, timeZone: utc)
        let preview = try LedgerExportImporter.preview(parsed, in: context)
        let stats = try LedgerExportImporter.commit(parsed, fileName: nil, into: context)
        XCTAssertEqual(preview, stats, "the confirmation shows what the import does")
        XCTAssertEqual(stats.inserted, 1)
        XCTAssertEqual(stats.updated, 1)
        XCTAssertEqual(stats.notInFile, 1, "a record deleted in iCost is reported, not deleted")
        let records = try context.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(records.count, icostExport.count - 1 + 1)
        let income = records.filter { $0.kind == .income }
        XCTAssertEqual(income.count, 1)
        XCTAssertEqual(income.first?.amount, 95)
        XCTAssertEqual(income.first?.note, "bonus")
    }

    func testRealExportRoundTrip() throws {
        guard let url = Bundle(for: Self.self).url(forResource: "ledger-fixture-export", withExtension: "xlsx") else {
            throw XCTSkip("ledger fixture is not in the test bundle (local-only)")
        }
        let context = try store()
        try LedgerExportImporter.importFile(at: url, into: context)
        let records = try context.fetch(FetchDescriptor<Transaction>())
        let sheet = try XLSXReader.firstSheetRows(of: LedgerExportWriter.workbook(for: records))
        XCTAssertEqual(sheet.first, LedgerExportWriter.header)
        XCTAssertEqual(sheet.count - 1, records.count)
        let original = Set(records.map(\.fingerprint))
        let again = Set(LedgerExportImporter.fingerprints(for: try LedgerExportImporter.parse(rows: sheet).rows))
        XCTAssertEqual(again, original, "every record survives Tidemark → template → Tidemark unchanged")
        let stats = try LedgerExportImporter.commit(try LedgerExportImporter.parse(rows: sheet), fileName: nil, into: context)
        XCTAssertEqual(stats.inserted + stats.updated, 0)
    }

    func testNewerRealExportOverTheOlderOne() throws {
        let bundle = Bundle(for: Self.self)
        guard let older = bundle.url(forResource: "ledger-fixture-export", withExtension: "xlsx"),
              let newer = bundle.url(forResource: "ledger-fixture-latest", withExtension: "xlsx") else {
            throw XCTSkip("ledger fixtures are not in the test bundle (local-only)")
        }
        let context = try store()
        let first = try LedgerExportImporter.importFile(at: older, into: context)
        let rows = try XLSXReader.firstSheetRows(at: newer).count - 1
        let second = try LedgerExportImporter.importFile(at: newer, into: context)
        XCTAssertEqual(second.rejected, 0)
        XCTAssertEqual(second.notInFile, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Transaction>()), rows,
                       "one record per row of the newest export: edits updated, nothing doubled")
        XCTAssertEqual(second.inserted + second.updated + second.skipped, rows)
        XCTAssertEqual(first.inserted, second.skipped + second.updated)
    }
}
