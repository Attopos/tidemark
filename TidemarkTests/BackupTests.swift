import XCTest
import SwiftData
@testable import Tidemark

// A backup must bring everything the board is built from to an empty store,
// exactly, and restoring must never duplicate or delete.

@MainActor
final class BackupTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        ModelContext(try TidemarkSchema.makeContainer(inMemory: true))
    }

    private func seed(_ context: ModelContext) throws {
        let account = Account(name: "Alipay Funds", kind: .investment)
        let exchange = Account(name: "Binance", kind: .crypto, currencyCode: "USD")
        let empty = Account(name: "Wallet", kind: .cash)
        [account, exchange, empty].forEach(context.insert)

        let fund = Asset(name: "某某标普500指数(QDII)A", symbol: "", assetClass: .equity)
        fund.customName = "标普 500"
        fund.exposure = .usEquity
        let coin = Asset(name: "Bitcoin", symbol: "BTC", assetClass: .crypto, currencyCode: "USD")
        [fund, coin].forEach(context.insert)

        let fundHolding = Holding(asset: fund, account: account, quantity: Decimal(string: "1234.5678"), source: .alipayOCR)
        let coinHolding = Holding(asset: coin, account: exchange, quantity: Decimal(string: "0.0123456789"), source: .binance)
        coinHolding.isActive = false
        [fundHolding, coinHolding].forEach(context.insert)

        let day = Date(timeIntervalSince1970: 1_750_000_000)
        context.insert(HoldingSnapshot(holding: fundHolding, date: day, marketValue: Decimal(string: "20000.12")!,
                                       unrealizedPL: Decimal(string: "-321.09"), returnRate: Decimal(string: "-0.0158"),
                                       source: .alipayOCR))
        context.insert(HoldingSnapshot(holding: fundHolding, date: day.addingTimeInterval(86_400), marketValue: 20500))
        context.insert(HoldingSnapshot(holding: coinHolding, date: day, marketValue: Decimal(string: "900.5")!,
                                       quantity: Decimal(string: "0.0123456789"), source: .binance))
        context.insert(PricePoint(asset: coin, date: day, price: Decimal(string: "72943.21")!, currencyCode: "USD"))
        context.insert(CurrencyRate(code: "USD", rate: Decimal(string: "7.1234")!, date: day, source: .market))
        context.insert(CurrencyRate(code: "EUR", rate: 7, date: day, source: .market, isSeeded: true))
        try context.save()
    }

    private func roundTrip(_ context: ModelContext) throws -> BackupFile {
        let settings = BackupFile.Settings(baseCurrency: "USD", language: "zh")
        let backup = try BackupService.makeBackup(from: context, settings: settings)
        return try BackupService.decode(try BackupService.encode(backup))
    }

    func testLedgerRecordsRoundTrip() throws {
        let source = try makeContext()
        let bank = Account(name: "Bank", kind: .payment, openingBalance: Decimal(string: "1234.56")!)
        let cash = Account(name: "Dollars", kind: .cash, currencyCode: "USD")
        [bank, cash].forEach(source.insert)
        let day = Date(timeIntervalSince1970: 1_750_000_000)
        let lunch = Transaction(date: day, kind: .expense, amount: Decimal(string: "36.78")!, category: "Food",
                                subcategory: "Lunch", note: "noodles", tags: "trip", account: bank,
                                source: .icost, fingerprint: "ledger:abc")
        lunch.address = "Somewhere 1"
        lunch.refundAmount = 5
        let exchange = Transaction(date: day.addingTimeInterval(60), kind: .transfer, amount: 700,
                                   category: "Transfer", account: bank, transferAccount: cash)
        exchange.transferAmount = Decimal(string: "98.5")
        [lunch, exchange].forEach(source.insert)
        try source.save()

        let backup = try roundTrip(source)
        let target = try makeContext()
        try BackupService.restore(backup, into: target)
        let stats = try BackupService.restore(backup, into: target)
        XCTAssertEqual(stats.added, 0, "restoring twice adds nothing")

        let records = try target.fetch(FetchDescriptor<Transaction>(sortBy: [SortDescriptor(\.date)]))
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].amount, Decimal(string: "36.78"))
        XCTAssertEqual(records[0].subcategory, "Lunch")
        XCTAssertEqual(records[0].address, "Somewhere 1")
        XCTAssertEqual(records[0].refundAmount, 5)
        XCTAssertEqual(records[0].fingerprint, "ledger:abc")
        XCTAssertEqual(records[0].account?.name, "Bank")
        XCTAssertEqual(records[0].account?.openingBalance, Decimal(string: "1234.56"))
        XCTAssertEqual(records[1].kind, .transfer)
        XCTAssertEqual(records[1].transferAccount?.name, "Dollars")
        XCTAssertEqual(records[1].transferAmount, Decimal(string: "98.5"))
    }

    func testRestoreMatchesAnImportedRecordByFingerprint() throws {
        // The same export imported on two Macs: ids differ, fingerprints agree.
        let source = try makeContext()
        source.insert(Transaction(date: Date(timeIntervalSince1970: 1_750_000_000), kind: .expense, amount: 10,
                                  source: .icost, fingerprint: "ledger:same"))
        try source.save()
        let target = try makeContext()
        target.insert(Transaction(date: Date(timeIntervalSince1970: 1_750_000_000), kind: .expense, amount: 10,
                                  source: .icost, fingerprint: "ledger:same"))
        try target.save()
        try BackupService.restore(try roundTrip(source), into: target)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<Transaction>()), 1)
    }

    func testRestoreIntoEmptyStoreBringsEverythingBack() throws {
        let source = try makeContext()
        try seed(source)
        let backup = try roundTrip(source)

        let target = try makeContext()
        try BackupService.restore(backup, into: target)

        let holdings = try target.fetch(FetchDescriptor<Holding>())
        XCTAssertEqual(holdings.count, 2)
        XCTAssertEqual(try target.fetch(FetchDescriptor<Account>()).count, 3, "cash accounts travel too, for the ledger")
        XCTAssertEqual(try target.fetch(FetchDescriptor<HoldingSnapshot>()).count, 3)
        XCTAssertEqual(try target.fetch(FetchDescriptor<PricePoint>()).count, 1)
        XCTAssertEqual(try target.fetch(FetchDescriptor<CurrencyRate>()).map(\.code), ["USD"], "seed rates are not history")

        let fund = try XCTUnwrap(holdings.first { $0.asset?.symbol == "" })
        XCTAssertEqual(fund.asset?.displayName, "标普 500")
        XCTAssertEqual(fund.asset?.exposure, .usEquity)
        XCTAssertEqual(fund.account?.name, "Alipay Funds")
        XCTAssertEqual(fund.quantity, Decimal(string: "1234.5678"))
        XCTAssertEqual(fund.snapshots.count, 2)
        let first = try XCTUnwrap(fund.snapshots.min(by: { $0.date < $1.date }))
        XCTAssertEqual(first.marketValue, Decimal(string: "20000.12"))
        XCTAssertEqual(first.unrealizedPL, Decimal(string: "-321.09"))
        XCTAssertEqual(first.returnRate, Decimal(string: "-0.0158"))

        let coin = try XCTUnwrap(holdings.first { $0.asset?.symbol == "BTC" })
        XCTAssertFalse(coin.isActive, "a sold holding stays sold")
        XCTAssertEqual(coin.quantity, Decimal(string: "0.0123456789"), "amounts survive exactly")
        XCTAssertEqual(coin.asset?.currencyCode, "USD")

        XCTAssertEqual(backup.settings.baseCurrency, "USD")
    }

    func testRestoringTwiceAddsNothing() throws {
        let source = try makeContext()
        try seed(source)
        let backup = try roundTrip(source)

        let target = try makeContext()
        let first = try BackupService.restore(backup, into: target)
        let second = try BackupService.restore(backup, into: target)
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.updated, first.added)
        XCTAssertEqual(try target.fetch(FetchDescriptor<HoldingSnapshot>()).count, 3)
    }

    func testRestoreNeverDeletesWhatIsAlreadyThere() throws {
        let source = try makeContext()
        try seed(source)
        let backup = try roundTrip(source)

        let target = try makeContext()
        let local = Asset(name: "某某纯债债券A", symbol: "", assetClass: .bond)
        target.insert(local)
        let localHolding = Holding(asset: local, account: nil)
        target.insert(localHolding)
        target.insert(HoldingSnapshot(holding: localHolding, date: Date(), marketValue: 500))
        try target.save()

        try BackupService.restore(backup, into: target)
        XCTAssertEqual(try target.fetch(FetchDescriptor<Holding>()).count, 3)
        XCTAssertEqual(try target.fetch(FetchDescriptor<HoldingSnapshot>()).count, 4)
    }

    func testDecodeRejectsOtherFiles() throws {
        XCTAssertThrowsError(try BackupService.decode(Data("{\"hello\": 1}".utf8)))
        XCTAssertThrowsError(try BackupService.decode(Data("not json".utf8)))
        let source = try makeContext()
        try seed(source)
        var future = try roundTrip(source)
        future.version = BackupFile.currentVersion + 1
        XCTAssertThrowsError(try BackupService.decode(try BackupService.encode(future)))
    }

    func testOneFilePerDayAndOldFilesArePruned() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tidemark-backup-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try makeContext()
        try seed(source)
        var backup = try roundTrip(source)

        let start = Date(timeIntervalSince1970: 1_750_000_000)
        for offset in 0..<(BackupService.keepFiles + 3) {
            backup.createdAt = start.addingTimeInterval(Double(offset) * 86_400)
            try BackupService.writeBackup(backup, to: folder)
        }
        try BackupService.writeBackup(backup, to: folder)   // same day again

        let files = BackupService.backupFiles(in: folder)
        XCTAssertEqual(files.count, BackupService.keepFiles)
        XCTAssertEqual(files.first?.lastPathComponent, BackupService.fileName(for: backup.createdAt))
    }
}
