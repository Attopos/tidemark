import SwiftUI
import AppKit

// MARK: - Round asset icons
//
// Crypto: the CC0 "cryptocurrency-icons" set (spothq, v0.18.1, white glyph
// variant), bundled as Resources/CryptoIcons/crypto-<ticker>.png and tinted
// with the exposure color, so logos stay inside the two-hue palette instead
// of bringing brand oranges and yellows.
// Index funds/ETFs: the icon of the index they track, detected from the name
// or ticker (标普/S&P/SPY → S&P 500, 纳斯达克/QQQ → Nasdaq, DAX, CAC 40,
// 日经/Nikkei, 黄金/上海金 → gold); see Resources/IndexIcons/SOURCES.md.
// Anything else gets a monogram in the exposure's color: the fund house for
// Chinese funds ("南方…" → 南), the ticker's first letter otherwise.

enum AssetIconStore {
    private static var cache: [String: NSImage] = [:]
    private static var misses: Set<String> = []

    static func cryptoImage(ticker: String) -> NSImage? {
        let key = ticker.lowercased()
        guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        if let hit = cache[key] { return hit }
        if misses.contains(key) { return nil }
        guard let url = Bundle.main.url(forResource: "crypto-\(key)", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            misses.insert(key)
            return nil
        }
        cache[key] = image
        return image
    }

    struct IndexMark {
        let image: NSImage
        /// Opaque square logos fill the circle; transparent marks sit inset.
        let fills: Bool
    }

    private static let indexRules: [(key: String, words: [String], tickers: Set<String>, fills: Bool)] = [
        ("nasdaq", ["纳斯达克", "nasdaq", "纳指"], ["QQQ", "QQQM", "ONEQ", "TQQQ"], false),
        ("sp500", ["标普", "s&p", "spdr s&p", "standard & poor"], ["SPY", "VOO", "IVV", "SPLG", "RSP"], true),
        ("dax", ["dax", "德国"], ["EWG", "DAX"], true),
        ("cac", ["cac", "法国"], ["EWQ"], false),
        ("nikkei", ["日经", "nikkei", "日本"], ["EWJ", "DXJ"], true),
        ("gold", ["黄金", "上海金", "gold"], ["GLD", "IAU", "PAXG", "XAUT"], false),
    ]

    static func indexKey(name: String, symbol: String) -> (key: String, fills: Bool)? {
        let n = name.lowercased()
        let t = symbol.uppercased()
        for rule in indexRules where rule.tickers.contains(t) || rule.words.contains(where: n.contains) {
            return (rule.key, rule.fills)
        }
        return nil
    }

    static func indexMark(name: String, symbol: String) -> IndexMark? {
        guard let (key, fills) = indexKey(name: name, symbol: symbol) else { return nil }
        let cacheKey = "index-" + key
        if let hit = cache[cacheKey] { return IndexMark(image: hit, fills: fills) }
        guard let url = Bundle.main.url(forResource: cacheKey, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[cacheKey] = image
        return IndexMark(image: image, fills: fills)
    }

    static func monogram(name: String, symbol: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, first.unicodeScalars.first.map({ (0x4E00...0x9FFF).contains($0.value) }) == true {
            return String(first)
        }
        let source = symbol.isEmpty ? trimmed : symbol
        return source.first.map { String($0).uppercased() } ?? "·"
    }
}

struct AssetIcon: View {
    let name: String
    let symbol: String
    let color: Color
    var size: CGFloat = 30
    /// Discs need a light tint for the knocked-out glyph to read.
    var glyphTint: Color = DS.violetSoft

    var body: some View {
        if let mark = AssetIconStore.indexMark(name: name, symbol: symbol) {
            if mark.fills {
                Image(nsImage: mark.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Image(nsImage: mark.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.2)
                    .frame(width: size, height: size)
                    .background(Color(hex: 0x0E0E0E))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                    .clipShape(Circle())
            }
        } else if let image = AssetIconStore.cryptoImage(ticker: symbol) {
            // The white variant is a disc with the glyph knocked out; tinted,
            // the glyph shows the dark panel through it.
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .foregroundStyle(glyphTint)
                .frame(width: size, height: size)
        } else {
            Text(AssetIconStore.monogram(name: name, symbol: symbol))
                .font(.system(size: size * 0.45, weight: .semibold))
                // The darkest violet doesn't read as text on the dark panel.
                .foregroundStyle(color == DS.violetDark || color == DS.violetDeep ? DS.violetSoft : color)
                .frame(width: size, height: size)
                .background(color.opacity(0.16))
                .overlay(Circle().strokeBorder(color.opacity(0.35), lineWidth: 1))
                .clipShape(Circle())
        }
    }
}
