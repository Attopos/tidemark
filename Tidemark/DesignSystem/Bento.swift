import SwiftUI

// MARK: - Bento cards
//
// Large rounded panels holding smaller rounded tiles, thin oversized display
// type, and outlined pill chips. Black surfaces; neon lime marks the one thing
// that matters most in a group (the total, the largest exposure).

extension DS {
    static let bentoRadius: CGFloat = 28
    static let tileRadius: CGFloat = 20
    static let panel = Color(hex: 0x171717)
    static let tile = Color(hex: 0x262626)

    /// Thin oversized display type ("Total value", "Holdings").
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .light)
    }

    /// Lime shades by rank: the largest is full neon, the rest step down
    /// toward the dark surface, so identity follows size without a rainbow.
    static func limeShade(_ rank: Int) -> Color {
        let steps: [Double] = [1, 0.74, 0.54, 0.40, 0.30, 0.23, 0.18, 0.14]
        return accent.opacity(steps[min(max(rank, 0), steps.count - 1)])
    }
}

/// Outer panel of a bento section.
struct BentoPanel<Content: View>: View {
    var fill: AnyShapeStyle = AnyShapeStyle(DS.panel)
    var padding: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: DS.bentoRadius, style: .continuous))
    }
}

/// Outlined pill chip ("2025", "by year").
struct Pill: View {
    let text: String
    var ink: Color = DS.textPrimary
    var size: CGFloat = 14

    init(_ text: String, ink: Color = DS.textPrimary, size: CGFloat = 14) {
        self.text = text
        self.ink = ink
        self.size = size
    }

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .regular).monospacedDigit())
            .foregroundStyle(ink)
            .padding(.horizontal, size * 0.75)
            .padding(.vertical, size * 0.28)
            .overlay(Capsule().strokeBorder(ink.opacity(0.7), lineWidth: 1.2))
    }
}
