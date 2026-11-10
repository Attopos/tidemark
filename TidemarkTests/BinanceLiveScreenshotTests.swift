import XCTest
import AppKit
@testable import Tidemark

// Live Vision OCR on a REAL Binance asset-list screenshot. The image and its
// expected values are real holdings, so both stay local and git-ignored
// (`binance-fixture-1.png`, `binance-fixture-expected.json`); the test skips
// when they are absent. Expected format:
// {"cash": ["USDC", "USDT"],
//  "assets": [{"code": "BTC", "quantity": "0.01", "value": "500.00", "pnl": "-1.23"}, …]}

@MainActor
final class BinanceLiveScreenshotTests: XCTestCase {

    private struct ExpectedAsset: Decodable {
        let code: String
        let quantity: String
        let value: String
        let pnl: String
    }

    private struct Expected: Decodable {
        let cash: [String]
        let assets: [ExpectedAsset]
    }

    func testRealScreenshot() async throws {
        let bundle = Bundle(for: Self.self)
        guard let jsonURL = bundle.url(forResource: "binance-fixture-expected", withExtension: "json"),
              let imageURL = bundle.url(forResource: "binance-fixture-1", withExtension: "png") else {
            throw XCTSkip("Binance fixtures are not in the test bundle (local-only)")
        }
        let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: jsonURL))
        let image = try XCTUnwrap(NSImage(contentsOf: imageURL))

        let lines = try await ScreenshotOCRService.recognize(image: image)
        let output = ScreenshotParser.parse(lines: lines)
        XCTAssertEqual(output.platform, .binance)

        for code in expected.cash {
            let draft = try XCTUnwrap(output.drafts.first { $0.code == code }, "\(code) missing")
            XCTAssertTrue(draft.excludedAsCash, "\(code) must be excluded as cash")
        }
        for asset in expected.assets {
            let draft = try XCTUnwrap(output.drafts.first { $0.code == asset.code }, "\(asset.code) missing")
            XCTAssertFalse(draft.excludedAsCash)
            XCTAssertEqual(draft.quantity?.value, Decimal(string: asset.quantity), "\(asset.code) amount")
            XCTAssertEqual(draft.marketValue?.value, Decimal(string: asset.value), "\(asset.code) value")
            XCTAssertEqual(draft.profit?.value, Decimal(string: asset.pnl), "\(asset.code) PNL")
        }
    }
}
