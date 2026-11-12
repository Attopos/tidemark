import SwiftUI

// MARK: - Category icons
//
// Categories carry their own emoji at the front of the name ("🍔FOOD",
// "☕ Coffee"), so that emoji is the icon, set on a round tile whose tint
// says the direction: violet for spending, lime for income, gray for money
// moved between own accounts. Names without one get a glyph guessed from
// the words in them, else their first letter.

enum CategoryName {
    /// Leading emoji, if any, and the rest of the name.
    static func split(_ name: String) -> (emoji: String?, label: String) {
        guard let first = name.first, first.isEmojiIcon else {
            return (nil, name.trimmingCharacters(in: .whitespaces))
        }
        let rest = name.dropFirst().trimmingCharacters(in: .whitespaces)
        return (String(first), rest.isEmpty ? name : rest)
    }

    static func label(_ name: String) -> String { split(name).label }

    private static let glyphs: [(words: [String], symbol: String)] = [
        (["salary", "工资", "薪"], "banknote"),
        (["part time", "兼职", "freelance"], "clock"),
        (["resale", "二手", "转卖"], "arrow.triangle.2.circlepath"),
        (["favor", "gift", "红包", "礼"], "gift"),
        (["bonus", "奖金"], "star"),
        (["interest", "利息", "dividend", "分红"], "percent"),
        (["refund", "退款"], "arrow.uturn.backward"),
        (["repay", "还款"], "creditcard"),
        (["lend", "借出", "borrow", "借入"], "hand.raised"),
        (["transfer", "转账"], "arrow.left.arrow.right"),
        (["food", "meal", "餐", "饭"], "fork.knife"),
        (["drink", "coffee", "咖啡"], "cup.and.saucer"),
        (["transp", "交通", "taxi", "car"], "car"),
        (["travel", "旅"], "airplane"),
        (["accom", "rent", "住", "房"], "house"),
        (["health", "医", "med"], "cross.case"),
        (["study", "学", "book"], "book"),
        (["digital", "数码", "app"], "desktopcomputer"),
        (["sport", "运动", "fitness"], "figure.run"),
        (["invest", "投资"], "chart.line.uptrend.xyaxis"),
        (["work", "工作"], "briefcase"),
    ]

    static func glyph(for name: String) -> String? {
        let lower = name.lowercased()
        return glyphs.first { $0.words.contains(where: lower.contains) }?.symbol
    }
}

extension Character {
    /// A pictographic emoji (not a digit or symbol that merely can be one).
    var isEmojiIcon: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return scalar.properties.isEmojiPresentation
            || (scalar.properties.isEmoji && unicodeScalars.count > 1)
            || (scalar.properties.isEmoji && scalar.value > 0x238C)
    }
}

struct CategoryIcon: View {
    let name: String
    let kind: TransactionKind
    var size: CGFloat = 32

    private var tint: Color {
        switch kind {
        case .expense: return DS.violet
        case .income: return DS.lime
        default: return DS.textTertiary
        }
    }

    var body: some View {
        let parts = CategoryName.split(name)
        ZStack {
            Circle().fill(tint.opacity(0.28))
            if let emoji = parts.emoji {
                Text(emoji).font(.system(size: size * 0.5))
            } else if let symbol = CategoryName.glyph(for: name) ?? (kind.isConsumptionFlow ? nil : kind.icon) {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(DS.textPrimary)
            } else {
                Text(String(parts.label.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(DS.textPrimary)
            }
        }
        .frame(width: size, height: size)
    }
}
