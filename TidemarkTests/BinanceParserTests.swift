import XCTest
import SwiftData
@testable import Tidemark

// Binance asset-list parsing on synthetic Vision output that mirrors the web
// "My Assets → Asset View" layout (positions as Vision reports them, values
// made up). Covers stablecoin exclusion, the dropped-decimal repair, signed
// PNL, platform detection, and saving into a USD account.

@MainActor
final class BinanceParserTests: XCTestCase {

    private func line(_ text: String, _ minX: CGFloat, _ maxX: CGFloat, _ midY: CGFloat,
                      height: CGFloat = 0.015, confidence: Double = 0.5) -> RecognizedLine {
        RecognizedLine(text: text,
                       box: CGRect(x: minX, y: midY - height / 2, width: maxX - minX, height: height),
                       confidence: confidence)
    }

    /// Header + four assets: a coin, a stablecoin, a tokenized ETF, and a coin
    /// whose quantity lost its decimal point in OCR.
    private var sampleLines: [RecognizedLine] {
        [
            line("Est. Total Value ©", 0.042, 0.153, 0.941, height: 0.022, confidence: 0.3),
            line("1,234.56789012", 0.042, 0.212, 0.897, height: 0.034),
            line("USDT<", 0.211, 0.251, 0.893),
            line("~ $1,234.56", 0.042, 0.096, 0.861),
            line("My Assets", 0.044, 0.102, 0.732),
            line("Asset ；", 0.042, 0.073, 0.636, height: 0.011),
            line("Amount =", 0.538, 0.576, 0.636, height: 0.011),
            line("Asset Price / Cost Price O", 0.663, 0.760, 0.635),
            line("Floating PNL ：", 0.869, 0.926, 0.636),

            // BTC: 0.01 × 50,000 = 500.00
            line("BTC", 0.065, 0.087, 0.595, height: 0.013, confidence: 1),
            line("0.0100000000", 0.503, 0.576, 0.594),
            line("$50,000.00", 0.695, 0.757, 0.592, height: 0.020),
            line("-$100.00", 0.875, 0.929, 0.582, height: 0.017, confidence: 0.3),
            line("$500.00", 0.539, 0.577, 0.571),
            line("Bitcoin", 0.065, 0.096, 0.570, height: 0.013),
            line("$60,000.00", 0.690, 0.744, 0.569, height: 0.020),

            // USDC: stablecoin, cost "--"; a stray icon glyph to the left.
            line("USDC", 0.065, 0.096, 0.531),
            line("$1.00", 0.725, 0.757, 0.528, height: 0.019),
            line("200.5000000000", 0.488, 0.576, 0.527, height: 0.017, confidence: 1),
            line("--<", 0.914, 0.953, 0.520, height: 0.013, confidence: 0.3),
            line("⑨", 0.042, 0.061, 0.519, height: 0.025, confidence: 0.3),
            line("USDC", 0.064, 0.093, 0.506, height: 0.014),
            line("$200.50", 0.536, 0.577, 0.504, height: 0.017),

            // QQQ tokenized ETF: 0.5 × 600 = 300.00; fullwidth dollar in PNL.
            line("QQQ", 0.061, 0.092, 0.465),
            line("0.500000000", 0.507, 0.576, 0.463, height: 0.020, confidence: 1),
            line("$600.00", 0.712, 0.757, 0.463, height: 0.019),
            line("- ＄10.00", 0.881, 0.929, 0.455, height: 0.016, confidence: 0.3),
            line("$620.00", 0.703, 0.743, 0.441, height: 0.018),
            line("$300.00", 0.539, 0.577, 0.441, height: 0.013, confidence: 1),
            line("Invesco QQQ Trust, Series 1", 0.064, 0.188, 0.440),

            // BNB: "0.0200000000" read as "00200000000"; 0.02 × 500 = 10.00.
            line("BNB", 0.065, 0.089, 0.141, height: 0.013, confidence: 1),
            line("00200000000", 0.501, 0.576, 0.139, height: 0.013),
            line("$500.00", 0.712, 0.756, 0.138, height: 0.019, confidence: 1),
            line("+$2.00 <", 0.887, 0.953, 0.130),
            line("$400.00", 0.703, 0.743, 0.116, height: 0.019),
            line("BNB", 0.065, 0.086, 0.116, height: 0.013, confidence: 1),
            line("$10.00", 0.544, 0.577, 0.116, height: 0.013, confidence: 0.3),
        ]
    }

    func testExtractNumberReadsDollarAmounts() {
        XCTAssertEqual(AlipayScreenshotParser.extractNumber("$12,345.67")?.value, Decimal(string: "12345.67"))
        XCTAssertEqual(AlipayScreenshotParser.extractNumber("- $ 123.45")?.value, Decimal(string: "-123.45"))
        XCTAssertEqual(AlipayScreenshotParser.extractNumber("-$1.23 <")?.value, Decimal(string: "-1.23"))
        XCTAssertEqual(AlipayScreenshotParser.extractNumber("+$4.56")?.value, Decimal(string: "4.56"))
        XCTAssertEqual(AlipayScreenshotParser.extractNumber("- ＄7.89")?.value, Decimal(string: "-7.89"))
    }

    func testParsesAssetRows() throws {
        let output = BinanceScreenshotParser.parse(lines: sampleLines)
        XCTAssertEqual(output.platform, .binance)
        XCTAssertEqual(output.drafts.map(\.code), ["BTC", "USDC", "QQQ", "BNB"])

        let btc = try XCTUnwrap(output.drafts.first { $0.code == "BTC" })
        XCTAssertEqual(btc.name, "Bitcoin")
        XCTAssertEqual(btc.quantity?.value, Decimal(string: "0.01"))
        XCTAssertEqual(btc.unitNAV?.value, 50000)
        XCTAssertEqual(btc.marketValue?.value, 500)
        XCTAssertEqual(btc.profit?.value, -100)
        XCTAssertEqual(btc.costBasis?.value, 600, "total cost = amount × cost price")
        XCTAssertFalse(btc.needsReview, "amount × price matches value, so the row is trusted")
        XCTAssertFalse(btc.excludedAsCash)

        let qqq = try XCTUnwrap(output.drafts.first { $0.code == "QQQ" })
        XCTAssertEqual(qqq.name, "Invesco QQQ Trust, Series 1")
        XCTAssertEqual(qqq.profit?.value, -10)
        XCTAssertEqual(BinanceScreenshotParser.assetClass(name: qqq.name, code: "QQQ"), .equity)
        XCTAssertEqual(BinanceScreenshotParser.assetClass(name: "Bitcoin", code: "BTC"), .crypto)
    }

    func testStablecoinsAreExcludedAsCash() throws {
        let output = BinanceScreenshotParser.parse(lines: sampleLines)
        let usdc = try XCTUnwrap(output.drafts.first { $0.code == "USDC" })
        XCTAssertTrue(usdc.excludedAsCash)
        XCTAssertEqual(usdc.name, "USDC", "icon glyph left of the name is ignored")
        XCTAssertNil(usdc.profit, "'--' is not a PNL")
        XCTAssertTrue(BinanceScreenshotParser.cashTickers.isSuperset(of: ["USDT", "USDC"]))
    }

    func testDroppedDecimalPointIsRepairedAndFlagged() throws {
        let output = BinanceScreenshotParser.parse(lines: sampleLines)
        let bnb = try XCTUnwrap(output.drafts.first { $0.code == "BNB" })
        XCTAssertEqual(bnb.quantity?.value, Decimal(string: "0.02"))
        XCTAssertEqual(bnb.quantity?.needsReview, true, "a repaired amount must be checked by the user")
        XCTAssertEqual(bnb.profit?.value, 2)
    }

    func testPlatformDetection() {
        XCTAssertEqual(ScreenshotParser.parse(lines: sampleLines).platform, .binance)
        let alipay = [
            line("易方达蓝筹精选混合", 0.05, 0.6, 0.80, height: 0.03, confidence: 1),
            line("持有金额", 0.05, 0.2, 0.75, height: 0.02, confidence: 1),
            line("12,345.67", 0.05, 0.25, 0.72, height: 0.02, confidence: 1),
        ]
        XCTAssertEqual(ScreenshotParser.parse(lines: alipay).platform, .alipay)
    }

    func testSessionUnchecksStablecoinsAndCommitsInUSD() async throws {
        let container = try TidemarkSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let session = ScreenshotImportSession(images: [])
        let drafts = BinanceScreenshotParser.parse(lines: sampleLines).drafts
        session.holdings = drafts.map { draft in
            ScreenshotImportSession.EditableHolding(
                include: !draft.excludedAsCash,
                name: draft.name, code: draft.code ?? "",
                marketValue: draft.marketValue.map { NSDecimalNumber(decimal: $0.value).stringValue } ?? "",
                profit: "", returnRatePercent: "",
                quantity: draft.quantity.map { NSDecimalNumber(decimal: $0.value).stringValue } ?? "",
                unitNAV: draft.unitNAV.map { NSDecimalNumber(decimal: $0.value).stringValue } ?? "",
                costBasis: "", flaggedFields: [], sourceBox: .zero,
                matchedHoldingID: nil, matchedLabel: nil,
                platform: .binance, excludedReason: draft.excludedAsCash ? "cash" : nil)
        }
        session.commit(into: context)

        let holdings = try context.fetch(FetchDescriptor<Holding>())
        XCTAssertEqual(Set(holdings.compactMap { $0.asset?.symbol }), ["BTC", "QQQ", "BNB"],
                       "USDC is cash and stays out")
        XCTAssertTrue(holdings.allSatisfy { $0.account?.name == "Binance" && $0.account?.currencyCode == "USD" })
        XCTAssertTrue(holdings.allSatisfy { $0.asset?.currencyCode == "USD" })
        let btc = try XCTUnwrap(holdings.first { $0.asset?.symbol == "BTC" })
        XCTAssertEqual(btc.snapshots.first?.marketValue, 500, "stored in USD as shown")

        // Totals convert to RMB through the dated USD rate.
        let converter = CurrencyConverter(rates: [CurrencyRate(code: "USD", rate: 7, date: .distantPast, source: .market)],
                                          base: "CNY")
        XCTAssertEqual(converter.toBase(500, "USD"), 3500)
    }
}
