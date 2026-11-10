import XCTest
import SwiftData
@testable import Tidemark

// The one invariant the app now lives on: saving an OCR result creates a
// holding when the asset is new, and updates the balance in place when it
// already exists — never a duplicate.

@MainActor
final class AlipayCommitTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try TidemarkSchema.makeContainer(inMemory: true)
        return ModelContext(container)
    }

    private func editable(name: String, code: String = "", value: String,
                          matched: Holding? = nil) -> ScreenshotImportSession.EditableHolding {
        ScreenshotImportSession.EditableHolding(
            name: name, code: code, marketValue: value, profit: "", returnRatePercent: "",
            quantity: "", unitNAV: "", costBasis: "", flaggedFields: [], sourceBox: .zero,
            matchedHoldingID: matched?.id, matchedLabel: matched.map { $0.asset?.name ?? "" })
    }

    func testCommitCreatesHoldingAndBalance() throws {
        let context = try makeContext()
        let session = ScreenshotImportSession(images: [])
        session.holdings = [editable(name: "易方达蓝筹精选混合", code: "005827", value: "12,345.67")]
        session.commit(into: context)

        let holdings = try context.fetch(FetchDescriptor<Holding>())
        XCTAssertEqual(holdings.count, 1)
        XCTAssertEqual(holdings.first?.asset?.name, "易方达蓝筹精选混合")
        XCTAssertEqual(holdings.first?.asset?.symbol, "005827")
        XCTAssertEqual(holdings.first?.account?.name, ScreenshotImportSession.defaultAccountName)
        let snapshots = try context.fetch(FetchDescriptor<HoldingSnapshot>())
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.marketValue, Decimal(string: "12345.67"))
    }

    func testCommitUpdatesMatchedHoldingInsteadOfDuplicating() throws {
        let context = try makeContext()

        // First screenshot: creates the entry.
        let first = ScreenshotImportSession(images: [])
        first.valuationDate = Date(timeIntervalSinceNow: -3 * 86_400)
        first.holdings = [editable(name: "易方达蓝筹精选混合", code: "005827", value: "10000")]
        first.commit(into: context)

        // Second screenshot days later: same fund recognized again.
        let existing = try context.fetch(FetchDescriptor<Holding>())
        XCTAssertEqual(existing.count, 1)
        let draft = HoldingDraft(name: "易方达蓝筹精选混合", code: "005827", nameConfidence: 1,
                                 marketValue: OCRField(value: 11000, confidence: 1, needsReview: false, sourceText: ""),
                                 box: .zero)
        let match = ScreenshotImportSession.match(draft: draft, in: existing)
        XCTAssertNotNil(match, "re-scan of the same fund must match the existing holding")

        let second = ScreenshotImportSession(images: [])
        second.holdings = [editable(name: "易方达蓝筹精选混合", code: "005827", value: "11,000.00", matched: match)]
        second.commit(into: context)

        let holdings = try context.fetch(FetchDescriptor<Holding>())
        XCTAssertEqual(holdings.count, 1, "matched fund must update, not duplicate")
        let snapshots = try context.fetch(FetchDescriptor<HoldingSnapshot>())
        XCTAssertEqual(snapshots.count, 2, "each valuation day keeps its own snapshot")
        let latest = holdings.first?.snapshots.max(by: { $0.date < $1.date })
        XCTAssertEqual(latest?.marketValue, 11000)
    }

    func testSameDayRecommitUpdatesSnapshotInPlace() throws {
        let context = try makeContext()
        let day = Date()

        let first = ScreenshotImportSession(images: [])
        first.valuationDate = day
        first.holdings = [editable(name: "博时信用债纯债A", code: "050027", value: "5000")]
        first.commit(into: context)

        let existing = try context.fetch(FetchDescriptor<Holding>())
        let second = ScreenshotImportSession(images: [])
        second.valuationDate = day
        second.holdings = [editable(name: "博时信用债纯债A", code: "050027", value: "5200", matched: existing.first)]
        second.commit(into: context)

        let snapshots = try context.fetch(FetchDescriptor<HoldingSnapshot>())
        XCTAssertEqual(snapshots.count, 1, "same holding + same day → snapshot updated in place")
        XCTAssertEqual(snapshots.first?.marketValue, 5200)
    }

    func testNameMatchWithoutCodeStillUpdates() throws {
        let context = try makeContext()

        let first = ScreenshotImportSession(images: [])
        first.valuationDate = Date(timeIntervalSinceNow: -86_400)
        first.holdings = [editable(name: "天弘余额宝货币", value: "888.88")]
        first.commit(into: context)

        let existing = try context.fetch(FetchDescriptor<Holding>())
        let draft = HoldingDraft(name: "天弘余额宝货币", code: nil, nameConfidence: 1,
                                 marketValue: OCRField(value: 900, confidence: 1, needsReview: false, sourceText: ""),
                                 box: .zero)
        let match = ScreenshotImportSession.match(draft: draft, in: existing)
        XCTAssertNotNil(match)

        let second = ScreenshotImportSession(images: [])
        second.holdings = [editable(name: "天弘余额宝货币", value: "900", matched: match)]
        second.commit(into: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Holding>()).count, 1)
    }
}

@MainActor
final class RenameTests: XCTestCase {
    func testCustomNameDoesNotBreakImportMatching() throws {
        let container = try TidemarkSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let asset = Asset(name: "某某标普500指数(QDII)A", symbol: "", assetClass: .equity)
        context.insert(asset)
        let holding = Holding(asset: asset, account: nil, source: .manual)
        context.insert(holding)
        asset.customName = "标普 500"
        try context.save()

        XCTAssertEqual(asset.displayName, "标普 500")
        let draft = HoldingDraft(name: "某某标普500指数(QDII)A", code: nil, nameConfidence: 1, box: .zero)
        XCTAssertEqual(ScreenshotImportSession.match(draft: draft, in: [holding])?.id, holding.id,
                       "re-import matches on the recognized name, not the custom one")
        asset.customName = "  "
        XCTAssertEqual(asset.displayName, "某某标普500指数(QDII)A")
    }
}
