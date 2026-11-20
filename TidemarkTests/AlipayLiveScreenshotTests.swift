import XCTest
import AppKit
import SwiftData
@testable import Tidemark

@MainActor
final class AlipayLiveScreenshotTests: XCTestCase {
    private struct Expected: Decodable {
        let name: String
        let value: Decimal
        let profit: Decimal

        private enum CodingKeys: String, CodingKey { case name, value, profit }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            value = try Self.decimal(c, .value)
            profit = try Self.decimal(c, .profit)
        }
        fileprivate static func decimal<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Decimal {
            let text = try c.decode(String.self, forKey: key)
            guard let value = Decimal(string: text) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "not a decimal: \(text)")
            }
            return value
        }
    }

    private struct ExpectedFixture: Decodable {
        let total: Decimal
        let funds: [Expected]

        private enum CodingKeys: String, CodingKey { case total, funds }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            total = try Expected.decimal(c, .total)
            funds = try c.decode([Expected].self, forKey: .funds)
        }
    }

    private func loadExpected() throws -> ExpectedFixture {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "alipay-fixture-expected", withExtension: "json") else {
            throw XCTSkip("alipay-fixture-expected.json is not in the test bundle (local-only fixture)")
        }
        return try JSONDecoder().decode(ExpectedFixture.self, from: Data(contentsOf: url))
    }

    private func fixtureImage(_ name: String) throws -> NSImage {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "webp") else {
            throw XCTSkip("\(name).webp is not in the test bundle (local-only fixture)")
        }
        return try XCTUnwrap(NSImage(contentsOf: url), "\(name).webp could not be decoded")
    }

    private func dec(_ text: String) -> Decimal? {
        AlipayScreenshotParser.extractNumber(text)?.value
    }

    func testRealScreenshotsEndToEnd() async throws {
        let fixture = try loadExpected()
        let expected = fixture.funds
        let expectedTotal = fixture.total
        let images = [try fixtureImage("alipay-fixture-1"), try fixtureImage("alipay-fixture-2")]
        let container = try TidemarkSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let first = ScreenshotImportSession(images: images)
        await first.run(existingHoldings: [])
        guard case .review = first.phase else {
            return XCTFail("OCR did not reach review: \(first.phase)")
        }

        print("TIDEMARK-REPORT ── pass 1 drafts (\(first.holdings.count)):")
        for h in first.holdings {
            print("TIDEMARK-REPORT name=[\(h.name)] code=[\(h.code)] 金额=[\(h.marketValue)] 收益=[\(h.profit)] flags=\(h.flaggedFields.sorted()) matched=\(h.matchedHoldingID != nil)")
        }
        print("TIDEMARK-REPORT accountTotal=[\(first.accountTotalText)]")

        XCTAssertEqual(first.holdings.count, expected.count,
                       "expected \(expected.count) unique funds after merging both screenshots")

        for want in expected {
            let matches = first.holdings.filter { $0.name == want.name }
            XCTAssertEqual(matches.count, 1, "fund \(want.name): expected exactly one exact-name draft, got \(matches.count)")
            guard let draft = matches.first else { continue }
            XCTAssertEqual(dec(draft.marketValue), want.value, "\(want.name) 金额")
            XCTAssertEqual(dec(draft.profit), want.profit, "\(want.name) 持有收益")
            XCTAssertNil(draft.matchedHoldingID, "\(want.name) must be new on an empty store")
        }

        first.commit(into: context)
        guard case .done = first.phase else {
            return XCTFail("commit 1 failed: \(first.phase)")
        }
        print("TIDEMARK-REPORT commit1: \(first.savedSummary)")

        let holdingsAfter1 = try context.fetch(FetchDescriptor<Holding>())
        let snapshotsAfter1 = try context.fetch(FetchDescriptor<HoldingSnapshot>())
        XCTAssertEqual(holdingsAfter1.count, expected.count)
        XCTAssertEqual(snapshotsAfter1.count, expected.count)
        let total1 = snapshotsAfter1.reduce(Decimal(0)) { $0 + $1.marketValue }
        XCTAssertEqual(total1, expectedTotal, "sum of saved balances")

        let second = ScreenshotImportSession(images: images)
        await second.run(existingHoldings: holdingsAfter1)
        guard case .review = second.phase else {
            return XCTFail("OCR pass 2 did not reach review: \(second.phase)")
        }
        for h in second.holdings {
            XCTAssertNotNil(h.matchedHoldingID, "re-import must match existing holding: \(h.name)")
        }
        second.commit(into: context)
        guard case .done = second.phase else {
            return XCTFail("commit 2 failed: \(second.phase)")
        }
        print("TIDEMARK-REPORT commit2: \(second.savedSummary)")
        XCTAssertTrue(second.savedSummary.hasPrefix("0 new"), "no new holdings on re-import: \(second.savedSummary)")

        let holdingsAfter2 = try context.fetch(FetchDescriptor<Holding>())
        let snapshotsAfter2 = try context.fetch(FetchDescriptor<HoldingSnapshot>())
        XCTAssertEqual(holdingsAfter2.count, expected.count, "re-import must not create holdings")
        XCTAssertEqual(snapshotsAfter2.count, expected.count, "same-day re-import updates snapshots in place")
        let total2 = snapshotsAfter2.reduce(Decimal(0)) { $0 + $1.marketValue }
        XCTAssertEqual(total2, expectedTotal)
    }
}
