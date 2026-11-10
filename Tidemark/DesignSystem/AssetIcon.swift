import SwiftUI
import AppKit
import CoreImage

// MARK: - Round asset icons
//
// Crypto: the CC0 "cryptocurrency-icons" set (spothq, v0.18.1, white glyph
// variant), bundled as Resources/CryptoIcons/crypto-<ticker>.png and tinted
// with the exposure color, so logos stay inside the two-hue palette instead
// of bringing brand oranges and yellows.
// Every icon is single-hue: logos are desaturated and tinted with the
// exposure color (the app shows only violet and lime).
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

    /// Coins the icon set doesn't cover, matched by name or ticker (incl. a
    /// common OCR misread), drawn duotone like every other icon.
    private static let customCoins: [(names: [String], file: String)] = [
        (["币安人生", "市安人生"], "coin-binancelife"),
    ]

    static func customCoin(name: String, symbol: String) -> NSImage? {
        guard let rule = customCoins.first(where: { rule in
            rule.names.contains { name.contains($0) || symbol.contains($0) }
        }) else { return nil }
        if let hit = cache[rule.file] { return hit }
        guard let url = Bundle.main.url(forResource: rule.file, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[rule.file] = image
        return image
    }

    /// Desaturate a logo and multiply it by `tint` (alpha kept), so any
    /// brand mark renders in the app's palette. Baked into a bitmap rather
    /// than SwiftUI filters so it's exact everywhere, and cached per tint.
    static func duotone(_ image: NSImage, key: String, tint: NSColor) -> NSImage {
        let rgb = tint.usingColorSpace(.sRGB) ?? tint
        let cacheKey = "\(key)|\(Int(rgb.redComponent * 255)),\(Int(rgb.greenComponent * 255)),\(Int(rgb.blueComponent * 255))"
        if let hit = cache[cacheKey] { return hit }
        guard let tiff = image.tiffRepresentation, let input = CIImage(data: tiff) else { return image }
        let gray = input.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0, kCIInputContrastKey: 1.15,
        ])
        let tinted = gray.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: rgb.redComponent, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: rgb.greenComponent, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: rgb.blueComponent, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let context = CIContext()
        guard let cg = context.createCGImage(tinted, from: input.extent) else { return image }
        let result = NSImage(cgImage: cg, size: image.size)
        cache[cacheKey] = result
        return result
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

    /// One tint per icon: the exposure color, lifted for the darkest
    /// violets so marks stay readable on the dark panel.
    private var tint: Color {
        color == DS.violetDark || color == DS.violetDeep ? DS.violetSoft : color
    }

    /// Any logo → luminance only → multiplied by the tint: brand colors are
    /// dropped, the mark's shape and light/dark structure stay.
    private func duotone(_ image: NSImage, key: String, fill: Bool) -> some View {
        Image(nsImage: AssetIconStore.duotone(image, key: key, tint: NSColor(tint)))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: fill ? .fill : .fit)
            .padding(fill ? 0 : size * 0.2)
            .frame(width: size, height: size)
            .background(fill ? Color.clear : tint.opacity(0.12))
            .clipShape(Circle())
    }

    var body: some View {
        if let coin = AssetIconStore.customCoin(name: name, symbol: symbol) {
            duotone(coin, key: "coin|" + name, fill: true)
        } else if let mark = AssetIconStore.indexMark(name: name, symbol: symbol) {
            if mark.fills {
                duotone(mark.image, key: "index|" + name + symbol, fill: true)
            } else {
                // Transparent marks: the shape alone, in the tint, full strength.
                Image(nsImage: mark.image)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(tint)
                    .padding(size * 0.22)
                    .frame(width: size, height: size)
                    .background(tint.opacity(0.12))
                    .clipShape(Circle())
            }
        } else if let image = AssetIconStore.cryptoImage(ticker: symbol) {
            // The white variant is a disc with the glyph knocked out; tinted,
            // the glyph shows the dark panel through it.
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        } else {
            Text(AssetIconStore.monogram(name: name, symbol: symbol))
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(color.opacity(0.16))
                .overlay(Circle().strokeBorder(color.opacity(0.35), lineWidth: 1))
                .clipShape(Circle())
        }
    }
}
