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
        let settings = BackupFile.Settings(baseCurrency: "USD", language: "zh", targets: ["usEquity": 0.6])
        let backup = try BackupService.makeBackup(from: context, settings: settings)
        return try BackupService.decode(try BackupService.encode(backup))
    }

    func testRestoreIntoEmptyStoreBringsEverythingBack() throws {
        let source = try makeContext()
        try seed(source)
        let backup = try roundTrip(source)

        let target = try makeContext()
        try BackupService.restore(backup, into: target)

        let holdings = try target.fetch(FetchDescriptor<Holding>())
        XCTAssertEqual(holdings.count, 2)
        XCTAssertEqual(try target.fetch(FetchDescriptor<Account>()).count, 2, "accounts without holdings are not part of the board")
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
        XCTAssertEqual(backup.settings.targets?["usEquity"], 0.6)
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
