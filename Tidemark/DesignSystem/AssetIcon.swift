import SwiftUI
import AppKit

// MARK: - Round asset icons
//
// Crypto: the CC0 "cryptocurrency-icons" set (spothq, v0.18.1, white glyph
// variant), bundled as Resources/CryptoIcons/crypto-<ticker>.png and tinted
// with the exposure color, so logos stay inside the two-hue palette instead
// of bringing brand oranges and yellows. Funds and stocks have no open
// standard logo set, so they get a monogram in the exposure's color: the
// fund house for Chinese funds ("南方…" → 南), the ticker's first letter
// otherwise.

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
        if let image = AssetIconStore.cryptoImage(ticker: symbol) {
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
