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

    enum MarkStyle {
        /// Opaque square logo: fills the circle.
        case fill
        /// Wordmark on a light background: fitted, the background becomes
        /// the disc.
        case wordmark
        /// Too wide to read as a fitted image at icon size: drawn as heavy
        /// black text on the tint instead.
        case text(String)
    }

    struct IndexMark {
        let image: NSImage
        let style: MarkStyle
    }

    private static let indexRules: [(key: String, words: [String], tickers: Set<String>, style: MarkStyle)] = [
        ("nasdaq", ["纳斯达克", "nasdaq", "纳指"], ["QQQ", "QQQM", "ONEQ", "TQQQ"], .fill),
        ("sp500", ["标普", "s&p", "spdr s&p", "standard & poor"], ["SPY", "VOO", "IVV", "SPLG", "RSP"], .fill),
        ("dax", ["dax", "德国"], ["EWG", "DAX"], .wordmark),
        ("cac", ["cac", "法国"], ["EWQ"], .wordmark),
        ("nikkei", ["日经", "nikkei", "日本"], ["EWJ", "DXJ"], .text("NIKKEI")),
        ("gold", ["黄金", "上海金", "gold"], ["GLD", "IAU", "PAXG", "XAUT"], .fill),
    ]

    static func indexKey(name: String, symbol: String) -> (key: String, style: MarkStyle)? {
        let n = name.lowercased()
        let t = symbol.uppercased()
        for rule in indexRules where rule.tickers.contains(t) || rule.words.contains(where: n.contains) {
            return (rule.key, rule.style)
        }
        return nil
    }

    static func indexMark(name: String, symbol: String) -> IndexMark? {
        guard let (key, style) = indexKey(name: name, symbol: symbol) else { return nil }
        if case .text = style { return IndexMark(image: NSImage(), style: style) }
        let cacheKey = "index-" + key
        if let hit = cache[cacheKey] { return IndexMark(image: hit, style: style) }
        guard let url = Bundle.main.url(forResource: cacheKey, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[cacheKey] = image
        return IndexMark(image: image, style: style)
    }

    /// Coins the icon set doesn't cover, matched by name or ticker (incl. a
    /// common OCR misread): drawn as black text on the tint, line-broken to
    /// stay legible at icon size.
    private static let customCoins: [(names: [String], label: String)] = [
        (["币安人生", "市安人生"], "币安\n人生"),
    ]

    static func customCoinLabel(name: String, symbol: String) -> String? {
        customCoins.first(where: { rule in
            rule.names.contains { name.contains($0) || symbol.contains($0) }
        })?.label
    }

    /// Re-color a logo in the palette. Grayscale, then (if `inverted`) flip
    /// luminance and stretch so the logo's own background lands on full
    /// tint and its mark goes dark: a light disc with a dark mark, never a
    /// black disc. Baked into a bitmap (exact everywhere), cached per tint.
    static func duotone(_ image: NSImage, key: String, tint: NSColor, inverted: Bool = false) -> NSImage {
        let rgb = tint.usingColorSpace(.sRGB) ?? tint
        let cacheKey = "\(key)|\(inverted)|\(Int(rgb.redComponent * 255)),\(Int(rgb.greenComponent * 255)),\(Int(rgb.blueComponent * 255))"
        if let hit = cache[cacheKey] { return hit }
        guard let tiff = image.tiffRepresentation, let input = CIImage(data: tiff) else { return image }
        let context = CIContext()
        var gray = input.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0, kCIInputContrastKey: 1.15,
        ])
        var scale: CGFloat = 1
        if inverted {
            gray = gray.applyingFilter("CIColorInvert")
            // Background sample: a small patch near the left edge, mid-height.
            let e = gray.extent
            let patch = CGRect(x: e.minX + e.width * 0.04, y: e.midY - e.height * 0.03,
                               width: max(1, e.width * 0.03), height: max(1, e.height * 0.06))
            let avg = gray.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: patch)])
            var px = [UInt8](repeating: 0, count: 4)
            context.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            let alpha = max(CGFloat(px[3]) / 255, 0.01)
            let level = CGFloat(px[0]) / 255 / alpha
            scale = min(6, 1 / max(level, 0.15))
        }
        let tinted = gray.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: rgb.redComponent * scale, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: rgb.greenComponent * scale, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: rgb.blueComponent * scale, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).applyingFilter("CIColorClamp")
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
        Image(nsImage: AssetIconStore.duotone(image, key: key, tint: NSColor(tint), inverted: fill))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: fill ? .fill : .fit)
            .padding(fill ? 0 : size * 0.2)
            .frame(width: size, height: size)
            .background(fill ? Color.clear : tint.opacity(0.12))
            .clipShape(Circle())
    }

    /// Black text on a solid tint disc: the look for anything without a logo.
    private func textBadge(_ text: String, scale: CGFloat) -> some View {
        Text(text)
            .font(.system(size: size * scale, weight: .heavy))
            .foregroundStyle(Color.black)
            .multilineTextAlignment(.center)
            .lineSpacing(-size * 0.06)
            .minimumScaleFactor(0.6)
            .frame(width: size, height: size)
            .background(tint)
            .clipShape(Circle())
    }

    var body: some View {
        if let label = AssetIconStore.customCoinLabel(name: name, symbol: symbol) {
            textBadge(label, scale: 0.27)
        } else if let mark = AssetIconStore.indexMark(name: name, symbol: symbol) {
            switch mark.style {
            case .fill:
                duotone(mark.image, key: "index|" + name + symbol, fill: true)
            case .text(let label):
                Text(label)
                    .font(.system(size: size * 0.25, weight: .black))
                    .italic()
                    .kerning(-0.3)
                    .foregroundStyle(Color.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, size * 0.08)
                    .frame(width: size, height: size)
                    .background(tint)
                    .clipShape(Circle())
            case .wordmark:
                Image(nsImage: AssetIconStore.duotone(mark.image, key: "index|" + name + symbol, tint: NSColor(tint)))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(.horizontal, size * 0.1)
                    .frame(width: size, height: size)
                    .background(tint)
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
            textBadge(AssetIconStore.monogram(name: name, symbol: symbol), scale: 0.45)
        }
    }
}
