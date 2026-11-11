import XCTest
import SwiftData
@testable import Tidemark

// The bookkeeping export must come across completely and exactly once:
// every row a record, amounts in their own currency, transfers between the
// right accounts, and a second import of the same file adding nothing.

@MainActor
final class LedgerExportTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private let header = ["Date", "Type", "Amount", "First-Level Category", "Second-Level Category",
                          "Account 1", "Account 2", "Remark", "Currency", "Tag", "Ledger", "Address",
                          "Refund", "Discount", "Fee"]

    private func sheet(_ rows: [[String]]) -> [[String]] { [header] + rows }

    private var sample: [[String]] {
        sheet([
            ["2026/03/01 08:00:00", "Expense", "-18.8", "Food", "Breakfast", "Wallet", "", "bun", "CNY", "", "Main", "Street 1", "", "", ""],
            ["2026/03/01 09:00:00", "Income", "80", "Salary", "", "Bank", "", "", "CNY", "work", "Main", "", "", "", ""],
            ["2026/03/02 10:00:00", "Transfer", "300", "Transfer", "", "Bank", "Wallet", "", "CNY", "", "Main", "", "", "", ""],
            ["2026/03/03 11:00:00", "Repayment", "120", "Repayment", "", "Bank", "Visa Credit", "", "CNY", "", "Main", "", "", "", ""],
            ["2026/03/04 12:00:00", "Lend", "50", "Transfer", "", "Bank", "Friend", "", "CNY", "", "Main", "", "", "", ""],
            ["2026/03/05 13:00:00", "Expense", "-100", "Travel", "", "Baht Cash", "", "", "THB", "", "Main", "", "40", "", ""],
        ])
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try TidemarkSchema.makeContainer(inMemory: true))
    }

    func testParsesEveryColumn() throws {
        let parsed = try LedgerExportImporter.parse(rows: sample, timeZone: utc)
        XCTAssertEqual(parsed.rows.count, 6)
        XCTAssertTrue(parsed.rejected.isEmpty)
        let first = parsed.rows[0]
        XCTAssertEqual(first.type, .expense)
        XCTAssertEqual(first.amount, Decimal(string: "18.8"))
        XCTAssertEqual(first.category, "Food")
        XCTAssertEqual(first.subcategory, "Breakfast")
        XCTAssertEqual(first.account, "Wallet")
        XCTAssertEqual(first.remark, "bun")
        XCTAssertEqual(first.address, "Street 1")
        XCTAssertEqual(first.date, Date(timeIntervalSince1970: 1_772_352_000))
        XCTAssertEqual(parsed.rows[3].type, .repayment)
        XCTAssertEqual(parsed.rows[4].type, .transfer)
        XCTAssertEqual(parsed.rows[4].typeLabel, "Lend")
        XCTAssertEqual(parsed.rows[5].currency, "THB")
        XCTAssertEqual(parsed.rows[5].refund, 40)
    }

    func testColumnOrderAndChineseHeadersDoNotMatter() throws {
        let rows = [["金额", "类型", "日期", "账户1", "货币"],
                    ["-12.5", "支出", "2026-03-01 08:00:00", "钱包", "CNY"]]
        let parsed = try LedgerExportImporter.parse(rows: rows, timeZone: utc)
        XCTAssertEqual(parsed.rows.count, 1)
        XCTAssertEqual(parsed.rows[0].amount, Decimal(string: "12.5"))
        XCTAssertEqual(parsed.rows[0].account, "钱包")
    }

    func testUnreadableRowsAreReportedNotDropped() throws {
        let rows = sheet([
            ["not a date", "Expense", "-1", "", "", "", "", "", "CNY", "", "", "", "", "", ""],
            ["2026/03/01 08:00:00", "Mystery", "-1", "", "", "", "", "", "CNY", "", "", "", "", "", ""],
            ["2026/03/01 08:00:00", "Expense", "abc", "", "", "", "", "", "CNY", "", "", "", "", "", ""],
            ["2026/03/01 08:00:00", "Expense", "-1", "", "", "", "", "", "CNY", "", "", "", "", "", ""],
        ])
        let parsed = try LedgerExportImporter.parse(rows: rows, timeZone: utc)
        XCTAssertEqual(parsed.rows.count, 1)
        XCTAssertEqual(parsed.rejected.map(\.line), [2, 3, 4])
    }

    func testMissingRequiredColumnIsAnError() {
        XCTAssertThrowsError(try LedgerExportImporter.parse(rows: [["Date", "Amount"], ["2026/03/01", "1"]]))
    }

    func testIdenticalRowsKeepSeparateFingerprints() throws {
        let row = ["2026/03/01 08:00:00", "Expense", "-2", "Food", "", "Wallet", "", "", "CNY", "", "", "", "", "", ""]
        let parsed = try LedgerExportImporter.parse(rows: sheet([row, row]), timeZone: utc)
        let prints = LedgerExportImporter.fingerprints(for: parsed.rows)
        XCTAssertEqual(Set(prints).count, 2)
        XCTAssertEqual(prints, LedgerExportImporter.fingerprints(for: parsed.rows), "fingerprints are deterministic")
    }

    func testCommitWritesRecordsAndAccounts() throws {
        let context = try makeContext()
        let parsed = try LedgerExportImporter.parse(rows: sample, timeZone: utc)
        let stats = try LedgerExportImporter.commit(parsed, fileName: "export.xlsx", into: context)
        XCTAssertEqual(stats, .init(inserted: 6, skipped: 0, rejected: 0, accountsCreated: 5))

        let accounts = try context.fetch(FetchDescriptor<Account>())
        let byName = Dictionary(uniqueKeysWithValues: accounts.map { ($0.name, $0) })
        XCTAssertEqual(byName["Baht Cash"]?.currencyCode, "THB", "currency follows the account's own records")
        XCTAssertEqual(byName["Baht Cash"]?.kind, .cash)
        XCTAssertEqual(byName["Visa Credit"]?.kind, .liability)
        XCTAssertEqual(byName["Friend"]?.kind, .other, "money lent out is a receivable")

        let records = try context.fetch(FetchDescriptor<Transaction>(sortBy: [SortDescriptor(\.date)]))
        XCTAssertEqual(records.map(\.kind), [.expense, .income, .transfer, .liabilityPayment, .transfer, .expense])
        XCTAssertEqual(records[2].account?.name, "Bank")
        XCTAssertEqual(records[2].transferAccount?.name, "Wallet")
        XCTAssertEqual(records[4].category, "Lend", "the original type survives as the label")
        XCTAssertEqual(records[5].refundAmount, 40)
        XCTAssertEqual(records[0].address, "Street 1")
        XCTAssertEqual(records[1].tags, "work")
        XCTAssertNotNil(records[0].rawPayload)
        XCTAssertTrue(records.allSatisfy { $0.source == .icost })
    }

    func testImportingTwiceAddsNothing() throws {
        let context = try makeContext()
        let parsed = try LedgerExportImporter.parse(rows: sample, timeZone: utc)
        try LedgerExportImporter.commit(parsed, fileName: nil, into: context)
        let again = try LedgerExportImporter.commit(parsed, fileName: nil, into: context)
        XCTAssertEqual(again.inserted, 0)
        XCTAssertEqual(again.skipped, 6)
        XCTAssertEqual(again.accountsCreated, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Transaction>()), 6)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Account>()), 5)
    }

    func testLongerExportAddsOnlyTheNewRows() throws {
        let context = try makeContext()
        try LedgerExportImporter.commit(try LedgerExportImporter.parse(rows: sample, timeZone: utc),
                                        fileName: nil, into: context)
        let longer = sample + [["2026/03/06 08:00:00", "Expense", "-9", "Food", "", "Wallet", "", "", "CNY", "", "", "", "", "", ""]]
        let stats = try LedgerExportImporter.commit(try LedgerExportImporter.parse(rows: longer, timeZone: utc),
                                                    fileName: nil, into: context)
        XCTAssertEqual(stats.inserted, 1)
        XCTAssertEqual(stats.skipped, 6)
    }

    // MARK: Workbook reader

    /// Stored (uncompressed) zip; the reader does not verify checksums.
    private func zip(_ files: [(String, String)]) -> Data {
        func u16(_ value: Int) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]) }
        func u32(_ value: Int) -> Data { u16(value & 0xFFFF) + u16(value >> 16 & 0xFFFF) }
        var body = Data()
        var directory = Data()
        for (name, text) in files {
            let nameData = Data(name.utf8)
            let content = Data(text.utf8)
            let offset = body.count
            body += u32(0x0403_4b50) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0)
            body += u32(content.count) + u32(content.count) + u16(nameData.count) + u16(0)
            body += nameData + content
            directory += u32(0x0201_4b50) + u16(20) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0)
            directory += u32(content.count) + u32(content.count) + u16(nameData.count) + u16(0) + u16(0)
            directory += u16(0) + u16(0) + u32(0) + u32(offset) + nameData
        }
        let start = body.count
        return body + directory + u32(0x0605_4b50) + u16(0) + u16(0) + u16(files.count) + u16(files.count)
            + u32(directory.count) + u32(start) + u16(0)
    }

    func testReadsSharedInlineAndNumericCells() throws {
        let strings = """
        <sst><si><t>Date</t></si><si><r><t>Am</t></r><r><t>ount</t></r></si><si><t>A &amp; B</t></si></sst>
        """
        let sheet = """
        <worksheet><sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
        <row r="2"><c r="A2" t="s"><v>2</v></c><c r="C2"><v>12.5</v></c><c r="D2" t="inlineStr"><is><t>inline</t></is></c></row>
        </sheetData></worksheet>
        """
        let data = zip([("xl/sharedStrings.xml", strings), ("xl/worksheets/sheet1.xml", sheet)])
        let rows = try XLSXReader.firstSheetRows(of: data)
        XCTAssertEqual(rows, [["Date", "Amount"], ["A & B", "", "12.5", "inline"]])
    }

    func testColumnReferences() {
        XCTAssertEqual(XLSXReader.columnIndex(ofReference: "A1"), 0)
        XCTAssertEqual(XLSXReader.columnIndex(ofReference: "Z9"), 25)
        XCTAssertEqual(XLSXReader.columnIndex(ofReference: "AA10"), 26)
        XCTAssertEqual(XLSXReader.columnIndex(ofReference: "AB2"), 27)
    }

    func testGarbageIsNotAWorkbook() {
        XCTAssertThrowsError(try XLSXReader.firstSheetRows(of: Data("hello".utf8)))
    }
}
