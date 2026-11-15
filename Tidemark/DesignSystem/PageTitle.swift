import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Title row at the top of a main page: large title on the left, round
/// actions on the right. The same on every tab.
struct PageTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    #if os(iOS)
    static var size: CGFloat { 34 }
    /// Space between a page's top and its content, so the title's letters
    /// start `DS.phoneTopMargin` below the safe area.
    static var pageTop: CGFloat { 0 }
    #else
    static var pageTop: CGFloat { 8 }
    #endif

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                #if os(iOS)
                .font(.system(size: Self.size, weight: .bold))
                .padding(.leading, -TextMetrics.leftBearing(of: title, size: Self.size, weight: .bold))
                #else
                .font(DS.title(30))
                #endif
                .foregroundStyle(DS.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            trailing
        }
        #if os(iOS)
        .frame(height: TextMetrics.lineHeight(size: Self.size, weight: .bold))
        .padding(.top, DS.phoneTopMargin - TextMetrics.capInset(size: Self.size, weight: .bold))
        #endif
    }
}

#if os(iOS)
/// Where a line of system text actually draws inside its frame, so edges of
/// letters (not of their boxes) can sit on the page margins.
enum TextMetrics {
    static func font(size: CGFloat, weight: UIFont.Weight) -> UIFont { .systemFont(ofSize: size, weight: weight) }

    static func lineHeight(size: CGFloat, weight: UIFont.Weight) -> CGFloat { font(size: size, weight: weight).lineHeight }

    /// From the top of the line box to the top of the capitals.
    static func capInset(size: CGFloat, weight: UIFont.Weight) -> CGFloat {
        let font = font(size: size, weight: weight)
        return font.lineHeight - (-font.descender) - font.capHeight
    }

    /// Blank space the first letter's glyph has on its left.
    static func leftBearing(of text: String, size: CGFloat, weight: UIFont.Weight) -> CGFloat {
        guard let first = text.first else { return 0 }
        let font = font(size: size, weight: weight) as CTFont
        var characters = Array(String(first).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count) else { return 0 }
        let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, nil, glyphs.count)
        return max(0, min(bounds.minX, 4))
    }
}
#endif

extension PageTitle where Trailing == EmptyView {
    init(title: String) {
        self.title = title
        self.trailing = EmptyView()
    }
}

/// Round icon button of the title row ("eye", search, import…).
struct RoundIconButton: View {
    let symbol: String
    var size: CGFloat = 40
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundIcon(symbol: symbol, size: size, active: active)
        }
        .buttonStyle(.plain)
    }
}

struct RoundIcon: View {
    let symbol: String
    var size: CGFloat = 40
    var active = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(active ? DS.ink : DS.textPrimary)
            .frame(width: size, height: size)
            .background(active ? DS.accent : DS.tile)
            .clipShape(Circle())
            .contentShape(Circle())
    }
}
