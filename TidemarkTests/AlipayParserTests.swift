import XCTest
import AppKit
@testable import Tidemark

// MARK: - Alipay screenshot parser (deterministic layout tests + Vision smoke)

final class AlipayParserTests: XCTestCase {

    private func line(_ text: String, x: CGFloat, y: CGFloat,
                      w: CGFloat = 0.25, h: CGFloat = 0.03, confidence: Double = 0.95) -> RecognizedLine {
        RecognizedLine(text: text, box: CGRect(x: x, y: y, width: w, height: h), confidence: confidence)
    }

    // MARK: Token extraction

    func testNumberExtraction() {
        XCTAssertEqual(AlipayScreenshotParser.extractNumber("¥12,345.67")?.value, Decimal(string: "12345.67"))
        XCTAssertEqual(AlipayScreenshotParser.extractNumber("+23.45")?.value, Decimal(string: "23.45"))
        let percent = AlipayScreenshotParser.extractNumber("-0.52%")
        XCTAssertEqual(percent?.value, Decimal(string: "-0.52"))
        XCTAssertEqual(percent?.isPercent, true)
        // Full-width digits and Chinese comma
        XCTAssertEqual(AlipayScreenshotParser.extractNumber("１，２３４.５")?.value, Decimal(string: "1234.5"))
        // Unicode minus
        XCTAssertEqual(AlipayScreenshotParser.extractNumber("−88.00")?.value, Decimal(string: "-88"))
        // Ungrouped thousands must not be truncated to the first 3 digits
        XCTAssertEqual(AlipayScreenshotParser.extractNumber("5200")?.value, Decimal(string: "5200"))
        XCTAssertEqual(AlipayScreenshotParser.extractNumber("5200.00")?.value, Decimal(string: "5200"))
        XCTAssertEqual(AlipayScreenshotParser.extractNumber("¥12345.67")?.value, Decimal(string: "12345.67"))
        // Vision misreading thousands commas as periods
        XCTAssertEqual(AlipayScreenshotParser.extractNumber("18.432.75")?.value, Decimal(string: "18432.75"))
        XCTAssertEqual(AlipayScreenshotParser.extractNumber("1.234.567.89")?.value, Decimal(string: "1234567.89"))
        // …while a genuine 3-4 decimal NAV stays a decimal
        XCTAssertEqual(AlipayScreenshotParser.extractNumber("1.2345")?.value, Decimal(string: "1.2345"))
        XCTAssertEqual(AlipayScreenshotParser.extractNumber("18.432")?.value, Decimal(string: "18.432"))
        XCTAssertNil(AlipayScreenshotParser.extractNumber("持有金额"))
    }

    func testBadgeSuffixStripping() {
        // Category pills merged into the name observation by Vision
        XCTAssertEqual(AlipayScreenshotParser.stripBadgeSuffixes("广发纳斯达克100ETF联接(QDII)A 基金 定投"),
                       "广发纳斯达克100ETF联接(QDII)A")
        XCTAssertEqual(AlipayScreenshotParser.stripBadgeSuffixes("易方达黄金ETF联接C黄金"),
                       "易方达黄金ETF联接C")
        XCTAssertEqual(AlipayScreenshotParser.stripBadgeSuffixes("易方达日兴资管日经225ETF联接(QDII)A 基金"),
                       "易方达日兴资管日经225ETF联接(QDII)A")
        // Names that genuinely END in a badge-like word keep it
        XCTAssertEqual(AlipayScreenshotParser.stripBadgeSuffixes("天弘余额宝货币"), "天弘余额宝货币")
        XCTAssertEqual(AlipayScreenshotParser.stripBadgeSuffixes("易方达中债新综合债券"), "易方达中债新综合债券")
    }

    func testFundCodeExtraction() {
        XCTAssertEqual(AlipayScreenshotParser.extractFundCode("005827"), "005827")
        XCTAssertEqual(AlipayScreenshotParser.extractFundCode("易方达蓝筹 (005827)"), "005827")
        XCTAssertNil(AlipayScreenshotParser.extractFundCode("20260105"))   // 8 digits — not a code
        XCTAssertNil(AlipayScreenshotParser.extractFundCode("混合基金"))
    }

    func testLabelPrecedence() {
        XCTAssertEqual(AlipayScreenshotParser.matchLabel("持有收益率"), .returnRate)
        XCTAssertEqual(AlipayScreenshotParser.matchLabel("持有收益"), .profit)
        XCTAssertEqual(AlipayScreenshotParser.matchLabel("持有金额"), .marketValue)
        XCTAssertEqual(AlipayScreenshotParser.matchLabel("昨日收益"), .dayProfit)
        XCTAssertEqual(AlipayScreenshotParser.matchLabel("总资产"), .accountTotal)
        XCTAssertNil(AlipayScreenshotParser.matchLabel("易方达蓝筹精选混合"))
    }

    func testFundNameDetection() {
        XCTAssertTrue(AlipayScreenshotParser.looksLikeFundName("易方达蓝筹精选混合"))
        XCTAssertTrue(AlipayScreenshotParser.looksLikeFundName("华夏沪深300ETF联接A"))
        XCTAssertTrue(AlipayScreenshotParser.looksLikeFundName("博时信用债纯债A"))
        XCTAssertFalse(AlipayScreenshotParser.looksLikeFundName("持有金额"))
        XCTAssertFalse(AlipayScreenshotParser.looksLikeFundName("总资产"))
        XCTAssertFalse(AlipayScreenshotParser.looksLikeFundName("12,345.67"))
        XCTAssertFalse(AlipayScreenshotParser.looksLikeFundName("搜索"))
    }

    // MARK: Layout parsing — the Alipay holdings-list shape

    /// Labels on one visual row, values on the row underneath (the common
    /// Alipay 持有 card layout).
    func testParseLabelAboveValueLayout() {
        let lines: [RecognizedLine] = [
            line("总资产", x: 0.05, y: 0.97, w: 0.12),
            line("68,420.50", x: 0.05, y: 0.93, w: 0.2),

            line("易方达蓝筹精选混合", x: 0.05, y: 0.84, w: 0.45),
            line("005827", x: 0.52, y: 0.84, w: 0.1),
            line("持有金额", x: 0.05, y: 0.79, w: 0.13),
            line("昨日收益", x: 0.38, y: 0.79, w: 0.13),
            line("持有收益", x: 0.70, y: 0.79, w: 0.13),
            line("12,345.67", x: 0.05, y: 0.75, w: 0.15),
            line("+23.45", x: 0.38, y: 0.75, w: 0.1),
            line("+1,234.56", x: 0.70, y: 0.75, w: 0.13),

            line("华夏沪深300ETF联接A", x: 0.05, y: 0.62, w: 0.45),
            line("持有金额", x: 0.05, y: 0.57, w: 0.13),
            line("持有收益率", x: 0.60, y: 0.57, w: 0.15),
            line("8,000.00", x: 0.05, y: 0.53, w: 0.13),
            line("+12.34%", x: 0.60, y: 0.53, w: 0.1),
        ]
        let output = AlipayScreenshotParser.parse(lines: lines)

        XCTAssertEqual(output.accountTotal?.value, Decimal(string: "68420.50"))
        XCTAssertEqual(output.drafts.count, 2)

        let first = output.drafts[0]
        XCTAssertTrue(first.name.contains("易方达"))
        XCTAssertEqual(first.code, "005827")
        XCTAssertEqual(first.marketValue?.value, Decimal(string: "12345.67"))
        XCTAssertEqual(first.profit?.value, Decimal(string: "1234.56"))
        XCTAssertEqual(first.dayProfit?.value, Decimal(string: "23.45"))

        let second = output.drafts[1]
        XCTAssertTrue(second.name.contains("华夏"))
        XCTAssertEqual(second.marketValue?.value, Decimal(string: "8000"))
        XCTAssertEqual(second.returnRatePercent?.value, Decimal(string: "12.34"))
    }

    /// Label and value inside one recognized string ("持有金额 1,234.56").
    func testParseInlineLabelValue() {
        let lines: [RecognizedLine] = [
            line("博时信用债纯债A 050027", x: 0.05, y: 0.8, w: 0.5),
            line("持有金额 9,876.54", x: 0.05, y: 0.75, w: 0.35),
            line("持有收益 -56.78", x: 0.05, y: 0.71, w: 0.3),
            line("持有份额 8,210.45", x: 0.05, y: 0.67, w: 0.3),
            line("单位净值 1.2030", x: 0.05, y: 0.63, w: 0.3),
        ]
        let output = AlipayScreenshotParser.parse(lines: lines)
        XCTAssertEqual(output.drafts.count, 1)
        let draft = output.drafts[0]
        XCTAssertEqual(draft.code, "050027")
        XCTAssertEqual(draft.marketValue?.value, Decimal(string: "9876.54"))
        XCTAssertEqual(draft.profit?.value, Decimal(string: "-56.78"))
        XCTAssertEqual(draft.quantity?.value, Decimal(string: "8210.45"))
        XCTAssertEqual(draft.unitNAV?.value, Decimal(string: "1.2030"))
    }

    /// Value-only screenshot: stored as a valuation, nothing invented.
    func testValueOnlyScreenshotYieldsValueOnlyDraft() {
        let lines: [RecognizedLine] = [
            line("易方达蓝筹精选混合", x: 0.05, y: 0.8, w: 0.45),
            line("12,345.67", x: 0.6, y: 0.8, w: 0.2),
        ]
        let output = AlipayScreenshotParser.parse(lines: lines)
        XCTAssertEqual(output.drafts.count, 1)
        let draft = output.drafts[0]
        XCTAssertEqual(draft.marketValue?.value, Decimal(string: "12345.67"))
        XCTAssertNil(draft.quantity)
        XCTAssertNil(draft.costBasis)
        XCTAssertNil(draft.unitNAV)
        // Heuristic association without a label is flagged for review.
        XCTAssertEqual(draft.marketValue?.needsReview, true)
    }

    func testLowConfidenceFlagsReview() {
        let lines: [RecognizedLine] = [
            line("易方达蓝筹精选混合", x: 0.05, y: 0.8, w: 0.45),
            line("持有金额", x: 0.05, y: 0.75, w: 0.13),
            line("12,345.67", x: 0.05, y: 0.71, w: 0.15, confidence: 0.3),
        ]
        let output = AlipayScreenshotParser.parse(lines: lines)
        XCTAssertEqual(output.drafts.first?.marketValue?.needsReview, true)
        XCTAssertEqual(output.drafts.first?.needsReview, true)
    }

    // MARK: Vision integration smoke test
    //
    // Renders a synthetic "screenshot" and runs the full OCR pipeline. If the
    // Vision runtime is unavailable in the test environment the test is
    // skipped — the parser logic itself is covered deterministically above.

    func testVisionRecognizesRenderedHoldingCard() async throws {
        let size = CGSize(width: 900, height: 500)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        CGRect(origin: .zero, size: size).fill()
        func draw(_ text: String, _ point: CGPoint, bold: Bool = false, pt: CGFloat = 34) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: bold ? NSFont.boldSystemFont(ofSize: pt) : NSFont.systemFont(ofSize: pt),
                .foregroundColor: NSColor.black,
            ]
            (text as NSString).draw(at: point, withAttributes: attrs)
        }
        draw("易方达蓝筹精选混合", CGPoint(x: 40, y: 400), bold: true)
        draw("005827", CGPoint(x: 560, y: 400))
        draw("持有金额", CGPoint(x: 40, y: 300), pt: 28)
        draw("12,345.67", CGPoint(x: 40, y: 240), bold: true)
        draw("持有收益", CGPoint(x: 460, y: 300), pt: 28)
        draw("+1,234.56", CGPoint(x: 460, y: 240), bold: true)
        image.unlockFocus()

        let lines: [RecognizedLine]
        do {
            lines = try await ScreenshotOCRService.recognize(image: image)
        } catch {
            throw XCTSkip("Vision unavailable in this environment: \(error)")
        }
        let allText = lines.map(\.text).joined(separator: " ")
        XCTAssertTrue(allText.contains("12,345.67") || allText.contains("12345.67"),
                      "OCR text was: \(allText)")

        let output = AlipayScreenshotParser.parse(lines: lines)
        let draft = try XCTUnwrap(output.drafts.first, "no fund card parsed from OCR output: \(allText)")
        XCTAssertEqual(draft.marketValue?.value, Decimal(string: "12345.67"))
        XCTAssertEqual(draft.profit?.value, Decimal(string: "1234.56"))
        XCTAssertEqual(draft.code, "005827")
    }
}
