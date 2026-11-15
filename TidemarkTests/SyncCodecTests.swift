import XCTest
import SwiftData
@testable import Tidemark

// What travels between devices must rebuild the same row, and the change
// detector must send exactly what differs — and never sweep the server
// because a store came up empty.

@MainActor
final class SyncCodecTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        ModelContext(try TidemarkSchema.makeContainer(inMemory: true))
    }

    func testKeyNamesRoundTrip() {
        let id = UUID()
        let key = SyncKey(.transaction, id)
        XCTAssertEqual(key.name, "T:\(id.uuidString)")
        XCTAssertEqual(SyncKey(name: key.name), key)
        XCTAssertEqual(SyncKey(name: SyncKey(.account, id).name)?.kind, .account)
        XCTAssertNil(SyncKey(name: "X:\(id.uuidString)"))
        XCTAssertNil(SyncKey(name: "T:not-a-uuid"))
    }

    func testAccountRoundTrip() throws {
        let context = try makeContext()
        let source = Account(name: "Bank", kind: .liability, currencyCode: "USD",
                             openingBalance: Decimal(string: "-1234.56")!, note: "card", includeInNetWorth: false)
        source.isArchived = true
        let copy = Account(name: "", kind: .cash)
        [source, copy].forEach(context.insert)
        SyncCodec.apply(SyncCodec.fields(of: source), to: copy)
        XCTAssertEqual(copy.name, "Bank")
        XCTAssertEqual(copy.kind, .liability)
        XCTAssertEqual(copy.currencyCode, "USD")
        XCTAssertEqual(copy.openingBalance, Decimal(string: "-1234.56"))
        XCTAssertFalse(copy.includeInNetWorth)
        XCTAssertTrue(copy.isArchived)
        XCTAssertEqual(copy.note, "card")
        XCTAssertEqual(SyncCodec.digest(SyncCodec.fields(of: copy)), SyncCodec.digest(SyncCodec.fields(of: source)))
    }

    func testRecordRoundTripKeepsEveryField() throws {
        let context = try makeContext()
        let bank = Account(name: "Bank", kind: .payment)
        let cash = Account(name: "Dollars", kind: .cash, currencyCode: "USD")
        [bank, cash].forEach(context.insert)
        let source = Transaction(date: Date(timeIntervalSince1970: 1_750_000_000.25), kind: .transfer,
                                 amount: Decimal(string: "700.10")!, category: "Transfer", note: "exchange",
                                 tags: "trip", account: bank, transferAccount: cash, source: .icost,
                                 fingerprint: "ledger:abc", rawPayload: "{\"a\":1}")
        source.transferAmount = Decimal(string: "98.5")
        source.address = "Somewhere"
        source.feeAmount = 2
        let copy = Transaction(date: Date(), kind: .expense, amount: 0)
        [source, copy].forEach(context.insert)

        let complete = SyncCodec.apply(SyncCodec.fields(of: source), to: copy,
                                       accounts: [bank.id: bank, cash.id: cash])
        XCTAssertTrue(complete)
        XCTAssertEqual(copy.kind, .transfer)
        XCTAssertEqual(copy.amount, Decimal(string: "700.10"))
        XCTAssertEqual(copy.date.timeIntervalSince1970, 1_750_000_000.25, accuracy: 0.001)
        XCTAssertEqual(copy.account?.id, bank.id)
        XCTAssertEqual(copy.transferAccount?.id, cash.id)
        XCTAssertEqual(copy.transferAmount, Decimal(string: "98.5"))
        XCTAssertEqual(copy.address, "Somewhere")
        XCTAssertEqual(copy.feeAmount, 2)
        XCTAssertEqual(copy.tags, "trip")
        XCTAssertEqual(copy.rawPayload, "{\"a\":1}")
        XCTAssertEqual(copy.source, .icost)
    }

    func testRecordWaitingForItsAccountIsReported() throws {
        let context = try makeContext()
        let bank = Account(name: "Bank", kind: .payment)
        let source = Transaction(date: Date(), kind: .expense, amount: 5, account: bank)
        let copy = Transaction(date: Date(), kind: .expense, amount: 0)
        [source, copy].forEach(context.insert)
        context.insert(bank)
        XCTAssertFalse(SyncCodec.apply(SyncCodec.fields(of: source), to: copy, accounts: [:]))
        XCTAssertEqual(copy.amount, 5, "the rest of the record is still applied")
        XCTAssertNil(copy.account)
    }

    func testDigestFollowsContentNotTheTimestamp() throws {
        let context = try makeContext()
        let record = Transaction(date: Date(timeIntervalSince1970: 1_750_000_000), kind: .expense, amount: 10)
        context.insert(record)
        let before = SyncCodec.digest(SyncCodec.fields(of: record))
        record.updatedAt = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertEqual(SyncCodec.digest(SyncCodec.fields(of: record)), before)
        record.amount = 11
        XCTAssertNotEqual(SyncCodec.digest(SyncCodec.fields(of: record)), before)
    }

    // MARK: Planner

    private func entry(_ digest: String) -> SyncEntry { SyncEntry(digest: digest, system: nil) }

    func testPlanSendsWhatDiffers() {
        let plan = SyncPlanner.plan(
            local: ["new": "1", "changed": "2", "same": "3", "queued": "4"],
            synced: ["changed": entry("old"), "same": entry("3"), "gone": entry("9")],
            queued: ["queued": "4"])
        XCTAssertEqual(plan.saves, ["changed", "new"])
        XCTAssertEqual(plan.deletes, ["gone"])
        XCTAssertFalse(plan.refusedDeletes)
    }

    func testQueuedRowEditedAgainIsSentAgain() {
        let plan = SyncPlanner.plan(local: ["a": "2"], synced: [:], queued: ["a": "1"])
        XCTAssertEqual(plan.saves, ["a"])
    }

    func testAnEmptyStoreNeverSweepsTheServer() {
        var synced: [String: SyncEntry] = [:]
        for index in 0..<100 { synced["r\(index)"] = entry("d") }
        let plan = SyncPlanner.plan(local: [:], synced: synced, queued: [:])
        XCTAssertTrue(plan.refusedDeletes)
        XCTAssertTrue(plan.deletes.isEmpty)
        // A real clean-up of a few rows still goes through.
        var local: [String: String] = [:]
        for index in 0..<90 { local["r\(index)"] = "d" }
        let cleanup = SyncPlanner.plan(local: local, synced: synced, queued: [:])
        XCTAssertEqual(cleanup.deletes.count, 10)
        XCTAssertFalse(cleanup.refusedDeletes)
    }

    func testBothDevicesPickTheSameSurvivor() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(SyncPlanner.survivor(a, b), SyncPlanner.survivor(b, a))
    }

    func testPortfolioRoundTrip() throws {
        let context = try makeContext()
        let fund = Account(name: "支付宝", kind: .investment)
        let asset = Asset(name: "易方达蓝筹", symbol: "005827", assetClass: .mixedFund, note: "n")
        asset.exposureRaw = Exposure.allCases.first?.rawValue
        asset.customName = "Blue chip"
        let holding = Holding(asset: asset, account: fund, quantity: Decimal(string: "12.5"), costBasis: 1000)
        holding.openedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = HoldingSnapshot(holding: holding, date: Date(timeIntervalSince1970: 1_772_352_000),
                                       marketValue: Decimal(string: "1234.56")!, quantity: Decimal(string: "12.5"),
                                       unitNAV: Decimal(string: "98.7648"), costBasis: 1000,
                                       unrealizedPL: Decimal(string: "234.56"), returnRate: Decimal(string: "0.2346"))
        [fund].forEach(context.insert)
        context.insert(asset)
        context.insert(holding)
        context.insert(snapshot)

        let assetCopy = Asset(name: "", symbol: "", assetClass: .other)
        context.insert(assetCopy)
        SyncCodec.apply(SyncCodec.fields(of: asset), to: assetCopy)
        XCTAssertEqual(SyncCodec.fields(of: assetCopy), SyncCodec.fields(of: asset))
        XCTAssertEqual(assetCopy.displayName, "Blue chip")

        var created: Account?
        let holdingCopy = Holding(asset: nil, account: nil)
        context.insert(holdingCopy)
        XCTAssertFalse(SyncCodec.apply(SyncCodec.fields(of: holding), to: holdingCopy, assets: [:]) { _ in nil },
                       "a holding whose asset has not arrived waits")
        let complete = SyncCodec.apply(SyncCodec.fields(of: holding), to: holdingCopy,
                                       assets: [asset.id: assetCopy]) { fields in
            let account = Account(name: fields["accountName"] ?? "", kind: AccountKind(rawValue: fields["accountKind"] ?? "") ?? .other)
            created = account
            return account
        }
        XCTAssertTrue(complete)
        XCTAssertEqual(created?.name, "支付宝")
        XCTAssertEqual(created?.kind, .investment)
        XCTAssertEqual(holdingCopy.quantity, Decimal(string: "12.5"))
        XCTAssertEqual(holdingCopy.costBasis, 1000)
        XCTAssertEqual(holdingCopy.openedAt, holding.openedAt)
        XCTAssertTrue(holdingCopy.asset === assetCopy)

        let snapshotCopy = HoldingSnapshot(holding: nil, date: Date(), marketValue: 0)
        context.insert(snapshotCopy)
        XCTAssertTrue(SyncCodec.apply(SyncCodec.fields(of: snapshot), to: snapshotCopy, holdings: [holding.id: holding]))
        XCTAssertEqual(SyncCodec.digest(SyncCodec.fields(of: snapshotCopy)), SyncCodec.digest(SyncCodec.fields(of: snapshot)))
        XCTAssertNil(HoldingSnapshot(holding: nil, date: Date(), marketValue: 0).unitNAV)

        let empty = HoldingSnapshot(holding: holding, date: Date(), marketValue: 5)
        context.insert(empty)
        let emptyCopy = HoldingSnapshot(holding: nil, date: Date(), marketValue: 0)
        context.insert(emptyCopy)
        SyncCodec.apply(SyncCodec.fields(of: empty), to: emptyCopy, holdings: [holding.id: holding])
        XCTAssertNil(emptyCopy.unitNAV, "absent optional values stay absent")
        XCTAssertNil(emptyCopy.returnRate)
    }

    func testPortfolioKeyNames() {
        let id = UUID()
        for kind in [SyncKind.asset, .holding, .valuation] {
            XCTAssertEqual(SyncKey(name: SyncKey(kind, id).name)?.kind, kind)
            XCTAssertTrue(kind.isPortfolio)
        }
        XCTAssertFalse(SyncKind.transaction.isPortfolio)
    }
}
