import Foundation
import CoreGraphics

// MARK: - Screenshot platforms
//
// One OCR pipeline, several layouts. Each platform decides where its holdings
// land (standing account, currency, data source). Values are stored in the
// currency the screenshot shows; the app converts to the base currency (RMB)
// at display time with the dated rate for the valuation day, so history stays
// correct when the exchange rate moves.

enum ScreenshotPlatform: String, CaseIterable {
    case alipay
    case binance

    var displayName: String {
        switch self {
        case .alipay: return tr("Alipay")
        case .binance: return "Binance"
        }
    }

    var accountName: String {
        switch self {
        case .alipay: return "Alipay Funds"
        case .binance: return "Binance"
        }
    }

    var accountKind: AccountKind {
        switch self {
        case .alipay: return .investment
        case .binance: return .crypto
        }
    }

    /// Currency the screenshot's values are quoted in.
    var currencyCode: String {
        switch self {
        case .alipay: return "CNY"
        case .binance: return "USD"
        }
    }

    var source: DataSource {
        switch self {
        case .alipay: return .alipayOCR
        case .binance: return .binance
        }
    }
}

// MARK: - Platform detection

enum ScreenshotParser {
    /// Parse with every layout and keep the one that explains the screenshot.
    static func parse(lines: [RecognizedLine]) -> ScreenshotParseOutput {
        let binance = BinanceScreenshotParser.parse(lines: lines)
        let alipay = AlipayScreenshotParser.parse(lines: lines)
        if binance.drafts.count > alipay.drafts.count { return binance }
        if !binance.drafts.isEmpty, binance.drafts.count == alipay.drafts.count,
           BinanceScreenshotParser.hasBinanceMarkers(lines) {
            return binance
        }
        return alipay
    }
}

// MARK: - Binance asset list
//
// Layout (web "My Assets → Asset View", and the app's asset list):
//
//   [icon] BTC        0.0100000000     $50,000.00        - $100.00
//          Bitcoin    $500.00          $60,000.00 (cost)
//
// An asset starts at a row holding a short ticker on the left and a bare
// quantity (no currency sign) to its right. The rows below it, up to the next
// asset, carry the full name, the USD value under the quantity, the cost price
// under the price, and the floating PNL (signed) on the right.
//
// Quantity × price is cross-checked against the shown value; when they agree
// the row is trusted, when they don't the quantity's decimal point (often
// dropped by Vision on tiny amounts: "0.0200000000" → "00200000000") is
// repaired from the same digits if exactly that makes them agree, and the row
// is flagged for review. Stablecoins are cash, not positions: they are parsed
// but excluded by default.

enum BinanceScreenshotParser {

    /// Stablecoins held as cash; shown in review but not imported by default.
    static let cashTickers: Set<String> = ["USDT", "USDC"]

    static let markers = ["est. total value", "my assets", "asset view", "account view",
                          "floating pnl", "small amount exchange", "binance", "币安", "资产总估值"]

    static func hasBinanceMarkers(_ lines: [RecognizedLine]) -> Bool {
        lines.contains { line in
            let t = line.text.lowercased()
            return markers.contains { t.contains($0) }
        }
    }

    // MARK: Line classification

    private static func normalized(_ text: String) -> String {
        AlipayScreenshotParser.normalize(text)
    }

    /// Line carries a dollar amount ("$500.00", "- $100.00", "≈ $10.00").
    static func isDollar(_ text: String) -> Bool {
        normalized(text).contains("$")
    }

    /// Signed dollar amount: the floating PNL column.
    static func isSignedDollar(_ text: String) -> Bool {
        let t = normalized(text).replacingOccurrences(of: "−", with: "-")
        guard t.contains("$") else { return false }
        return t.range(of: #"^[-+]\s*\$"#, options: .regularExpression) != nil
    }

    /// A bare quantity: digits, separators, nothing else.
    static func isBareQuantity(_ text: String) -> Bool {
        let t = normalized(text).replacingOccurrences(of: " ", with: "")
        return t.range(of: #"^\d[\d,]*(\.\d+)?$"#, options: .regularExpression) != nil
    }

    /// Ticker/name text with icon glyphs and OCR punctuation removed.
    static func cleanLabel(_ text: String) -> String {
        let kept = normalized(text).unicodeScalars.filter { scalar in
            (scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || " &.-,'".unicodeScalars.contains(scalar)))
                || (0x4E00...0x9FFF).contains(scalar.value)
        }
        return String(String.UnicodeScalarView(kept))
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-,'&"))
    }

    private static func isLabel(_ text: String) -> Bool {
        let clean = cleanLabel(text)
        let meaningful = clean.unicodeScalars.filter {
            ($0.isASCII && CharacterSet.letters.contains($0)) || (0x4E00...0x9FFF).contains($0.value)
        }
        return meaningful.count >= 2 && !isDollar(text) && !isBareQuantity(text)
    }

    private static func ticker(from text: String) -> String {
        let clean = cleanLabel(text)
        let first = clean.split(separator: " ").first.map(String.init) ?? clean
        return first.allSatisfy(\.isASCII) ? first.uppercased() : first
    }

    private static func dollarValue(_ line: RecognizedLine) -> Decimal? {
        // "≈ $10.00" — drop the approx sign before reading the number.
        let t = normalized(line.text).replacingOccurrences(of: "≈", with: "").replacingOccurrences(of: "~", with: "")
        return AlipayScreenshotParser.extractNumber(t)?.value
    }

    // MARK: Parse

    struct Anchor {
        let rowIndex: Int
        let tickerLine: RecognizedLine
        let quantityLine: RecognizedLine
    }

    static func anchors(in rows: [[RecognizedLine]]) -> [Anchor] {
        rows.enumerated().compactMap { index, row in
            guard let quantity = row.first(where: { isBareQuantity($0.text) && $0.box.minX > 0.25 }) else { return nil }
            let left = row.filter { $0.box.maxX < quantity.box.minX && $0.box.minX < 0.35 && isLabel($0.text) }
            guard let tickerLine = left.min(by: { $0.box.minX < $1.box.minX }),
                  !ticker(from: tickerLine.text).isEmpty else { return nil }
            return Anchor(rowIndex: index, tickerLine: tickerLine, quantityLine: quantity)
        }
    }

    static func parse(lines: [RecognizedLine]) -> ScreenshotParseOutput {
        let rows = AlipayScreenshotParser.groupRows(lines)
        let found = anchors(in: rows)
        var drafts: [HoldingDraft] = []

        for (n, anchor) in found.enumerated() {
            let end = n + 1 < found.count ? found[n + 1].rowIndex : min(rows.count, anchor.rowIndex + 4)
            let anchorRow = rows[anchor.rowIndex]
            let below = rows[(anchor.rowIndex + 1)..<max(anchor.rowIndex + 1, end)].flatMap { $0 }
            let block = anchorRow + below
            let qtyLine = anchor.quantityLine

            // A real asset row always shows a dollar figure somewhere.
            guard block.contains(where: { isDollar($0.text) }) else { continue }

            let price = anchorRow
                .filter { isDollar($0.text) && !isSignedDollar($0.text) && $0.box.minX > qtyLine.box.maxX - 0.01 }
                .min { $0.box.minX < $1.box.minX }
            let pnl = block
                .filter { isSignedDollar($0.text) && $0.box.minX > qtyLine.box.maxX }
                .max { $0.box.maxX < $1.box.maxX }
            let value = below
                .filter { isDollar($0.text) && !isSignedDollar($0.text)
                          && Swift.abs($0.box.maxX - qtyLine.box.maxX) < 0.06 }
                .max { $0.box.midY < $1.box.midY }   // nearest under the quantity
            let cost = below
                .filter { line in
                    isDollar(line.text) && !isSignedDollar(line.text) && line.id != value?.id
                        && line.box.minX > (value?.box.maxX ?? qtyLine.box.maxX)
                }
                .min { $0.box.minX < $1.box.minX }
            let nameLine = below
                .filter { $0.box.minX >= anchor.tickerLine.box.minX - 0.012
                          && $0.box.maxX < qtyLine.box.minX && isLabel($0.text) }
                .max { $0.box.midY < $1.box.midY }

            let code = ticker(from: anchor.tickerLine.text)
            let fullName = nameLine.map { cleanLabel($0.text) } ?? ""
            let priceValue = price.flatMap(dollarValue)
            let marketValue = value.flatMap(dollarValue)

            // Quantity, with the decimal-point repair cross-checked against value.
            var quantity = AlipayScreenshotParser.extractNumber(qtyLine.text)?.value
            var consistent = false
            var repaired = false
            if let q = quantity, let p = priceValue, let v = marketValue {
                if agrees(q * p, v) {
                    consistent = true
                } else if let fixed = repairDecimal(qtyLine.text, price: p, value: v) {
                    quantity = fixed
                    repaired = true
                }
            }
            let crossChecked = consistent
            func field(_ v: Decimal?, _ line: RecognizedLine?, review: Bool) -> OCRField? {
                guard let v, let line else { return nil }
                return OCRField(value: v, confidence: crossChecked ? 1 : line.confidence,
                                needsReview: review, sourceText: line.text)
            }

            var costTotal: OCRField?
            if let cost, let costPrice = dollarValue(cost), let q = quantity {
                costTotal = OCRField(value: (q * costPrice).rounded(2), confidence: cost.confidence,
                                     needsReview: !crossChecked, sourceText: cost.text)
            }

            var box = anchor.tickerLine.box.union(qtyLine.box)
            for line in [price, pnl, value, cost, nameLine].compactMap({ $0 }) { box = box.union(line.box) }

            var draft = HoldingDraft(
                name: fullName.isEmpty ? code : fullName,
                code: code,
                nameConfidence: crossChecked ? 1 : anchor.tickerLine.confidence,
                marketValue: field(marketValue, value, review: !crossChecked),
                profit: field(pnl.flatMap(dollarValue), pnl, review: !crossChecked),
                returnRatePercent: nil,
                dayProfit: nil,
                quantity: field(quantity, qtyLine, review: !crossChecked || repaired),
                unitNAV: field(priceValue, price, review: !crossChecked && !repaired),
                costBasis: costTotal,
                box: box)
            draft.platform = .binance
            draft.excludedAsCash = cashTickers.contains(code)
            if draft.hasAnyValue { drafts.append(draft) }
        }
        return ScreenshotParseOutput(drafts: drafts, accountTotal: nil, lines: lines, platform: .binance)
    }

    /// q × p reproduces the displayed (cent-rounded) value.
    static func agrees(_ computed: Decimal, _ shown: Decimal) -> Bool {
        let diff = Swift.abs(NSDecimalNumber(decimal: computed - shown).doubleValue)
        let tolerance = max(0.011, Swift.abs(NSDecimalNumber(decimal: shown).doubleValue) * 0.01)
        return diff <= tolerance
    }

    /// Re-place the decimal point in the recognized digits so that
    /// quantity × price matches the shown value. Only a unique fit is accepted.
    static func repairDecimal(_ text: String, price: Decimal, value: Decimal) -> Decimal? {
        let digits = normalized(text).filter(\.isNumber)
        guard digits.count >= 2, price > 0 else { return nil }
        var fits: [Decimal] = []
        for split in 1..<digits.count {
            let candidate = String(digits.prefix(split)) + "." + String(digits.dropFirst(split))
            if let q = Decimal(string: candidate, locale: Locale(identifier: "en_US_POSIX")), agrees(q * price, value) {
                fits.append(q)
            }
        }
        return fits.count == 1 ? fits[0] : nil
    }

    /// Tokenized stocks/ETFs (QQQ, SPY…) are equity; everything else is crypto.
    static func assetClass(name: String, code: String) -> AssetClass {
        if cashTickers.contains(code.uppercased()) { return .cash }
        let n = name.lowercased()
        let equityHints = ["etf", "trust", "fund", "index", "s&p", "spdr", "invesco", "ishares",
                           "vanguard", " inc", "corp", "holdings", "class a", "class b", "nasdaq"]
        return equityHints.contains(where: n.contains) ? .equity : .crypto
    }
}
