import SwiftUI

enum CategoryName {
    static let symbolOpen: Character = "\u{E000}"
    static let symbolClose: Character = "\u{E001}"

    static func symbol(_ name: String) -> String? {
        guard name.first == symbolOpen, let close = name.firstIndex(of: symbolClose) else { return nil }
        let value = String(name[name.index(after: name.startIndex)..<close])
        return value.isEmpty ? nil : value
    }

    static func withoutSymbol(_ name: String) -> String {
        guard name.first == symbolOpen, let close = name.firstIndex(of: symbolClose) else { return name }
        return String(name[name.index(after: close)...])
    }

    static func compose(symbol: String?, rest: String) -> String {
        let plain = withoutSymbol(rest).trimmingCharacters(in: .whitespaces)
        guard let symbol, !symbol.isEmpty else { return plain }
        return "\(symbolOpen)\(symbol)\(symbolClose)\(plain)"
    }

    static func split(_ name: String) -> (emoji: String?, label: String) {
        let plain = withoutSymbol(name)
        guard let first = plain.first, first.isEmojiIcon else {
            return (nil, plain.trimmingCharacters(in: .whitespaces))
        }
        let rest = plain.dropFirst().trimmingCharacters(in: .whitespaces)
        return (String(first), rest.isEmpty ? plain : rest)
    }

    static func label(_ name: String) -> String { split(name).label }

    static func resolve(_ typed: String, among names: [String]) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, symbol(trimmed) == nil else { return trimmed }
        return names.first { $0 == trimmed } ?? names.first { label($0) == label(trimmed) } ?? trimmed
    }

    static func automaticSymbol(for name: String) -> String? {
        EntryGlyph.symbol(for: name) ?? glyph(for: name)
    }

    static func displaySymbol(for name: String) -> String? {
        symbol(name) ?? automaticSymbol(for: name)
    }

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
        let lower = label(name).lowercased()
        return glyphs.first { $0.words.contains(where: lower.contains) }?.symbol
    }
}

extension Character {
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

    var body: some View {
        let parts = CategoryName.split(name)
        ZStack {
            Circle().fill(DS.bgElevated)
            if let symbol = CategoryName.displaySymbol(for: name) ?? (kind.isConsumptionFlow ? nil : kind.icon) {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.4, weight: .regular).monospacedDigit())
                    .foregroundStyle(DS.textPrimary)
            } else {
                Text(String(parts.label.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .medium).monospacedDigit())
                    .foregroundStyle(DS.textPrimary)
            }
        }
        .frame(width: size, height: size)
    }
}
