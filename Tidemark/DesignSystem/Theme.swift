import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        #if canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
        #else
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }
}

#if canImport(UIKit) && !canImport(AppKit)
extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255.0, green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0, alpha: 1)
    }
}
#endif

#if canImport(AppKit)
extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1
        )
    }
}
#endif

enum DS {
    static let bgPrimary    = Color(light: 0xF4EDE6, dark: 0x142030)
    static let bgSecondary  = Color(light: 0xFFFBF7, dark: 0x1A2A38)
    static let bgElevated   = Color(light: 0xFFFBF7, dark: 0x1E3442)

    static let accent       = Color(hex: 0xFF5C8D)
    static let accentDark   = Color(light: 0xFBDDE6, dark: 0x3A1E33)
    static let accentText   = Color(light: 0xB8336A, dark: 0xFF5C8D)

    static let textPrimary  = Color(light: 0x142030, dark: 0xF4EDE6)
    static let textSecondary = Color(light: 0x4F5E6B, dark: 0x85A3B2)
    static let textTertiary = Color(light: 0x7A8C97, dark: 0x5E7584)

    static let border       = Color(light: 0xE5D9CD, dark: 0x263B4B)

    static let finBlue      = Color(light: 0x4F7183, dark: 0x85A3B2)
    static let positive     = Color(light: 0xB8336A, dark: 0xFF5C8D)
    static let negative     = Color(light: 0x4F7183, dark: 0xB9CCD6)
    static let warning      = Color(light: 0x4F7183, dark: 0xB9CCD6)

    static let categorical: [Color] = [
        Color(hex: 0x85A3B2), Color(hex: 0xFF5C8D), Color(hex: 0x4F7183),
        Color(hex: 0xC93D6E), Color(hex: 0xB9CCD6), Color(hex: 0xFFC2D4), Color(hex: 0x732553),
    ]
    static let categoricalOther = Color(hex: 0x7A8C97)

    static func categoryColor(_ index: Int) -> Color {
        index >= 0 && index < categorical.count ? categorical[index] : categoricalOther
    }

    static let heroGradient = LinearGradient(
        colors: [Color(hex: 0xFF8AAE), Color(hex: 0xFF5C8D), Color(hex: 0xE2477A)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let heroInk = Color(hex: 0x142030)
    static let heroInkSecondary = Color(hex: 0x142030).opacity(0.62)

    static let cardRadius: CGFloat = 16
    static let smallRadius: CGFloat = 10
    static let pagePadding: CGFloat = 28
    static let cardPadding: CGFloat = 18
    static let gridGap: CGFloat = 14

    static func editorial(_ size: CGFloat = 38) -> Font {
        .system(size: size, weight: .medium).monospacedDigit()
    }
    static let sectionTitle = Font.system(size: 17, weight: .regular).monospacedDigit()
    static let label = Font.system(size: 13, weight: .regular).monospacedDigit()
    static let body = Font.system(size: 15).monospacedDigit()
    static let caption = Font.system(size: 13.5).monospacedDigit()

    static func money(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular).monospacedDigit()
    }
    static let moneyHero = money(40)
    static let moneyLarge = money(28)
    static let moneyMedium = money(19)
    static let moneySmall = money(15)
    static let moneyTable = money(15)
}

struct CardBackground: ViewModifier {
    var elevated: Bool = false
    func body(content: Content) -> some View {
        content
            .background(elevated ? DS.bgElevated : DS.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                    .strokeBorder(DS.border, lineWidth: 1)
            )
    }
}

extension View {
    func cardSurface(elevated: Bool = false) -> some View {
        modifier(CardBackground(elevated: elevated))
    }
}

enum Fmt {
    static let currencySymbols: [String: String] = [
        "CNY": "¥", "USD": "$", "EUR": "€", "GBP": "£", "JPY": "JP¥",
        "HKD": "HK$", "THB": "฿", "KRW": "₩", "VND": "₫", "TWD": "NT$",
        "SGD": "S$", "AUD": "A$", "CAD": "C$", "CHF": "Fr", "GEL": "₾",
        "TRY": "₺", "EGP": "E£", "USDT": "USDT ", "USDC": "USDC ",
    ]

    static func symbol(for code: String) -> String {
        currencySymbols[code.uppercased()] ?? "\(code.uppercased()) "
    }

    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    private static let wholeFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 0
        return f
    }()

    private static let quantityFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 6
        return f
    }()

    nonisolated(unsafe) static var amountsHidden = false

    static func money(_ amount: Decimal, _ code: String, showSign: Bool = false, wholeDigits: Bool = false) -> String {
        if amountsHidden { return privacyMask }
        let number = NSDecimalNumber(decimal: abs(amount))
        let formatter = wholeDigits ? wholeFormatter : groupedFormatter
        let digits = formatter.string(from: number) ?? "\(number)"
        let sign = amount < 0 ? "-" : (showSign && amount > 0 ? "+" : "")
        return "\(sign)\(symbol(for: code))\(digits)"
    }

    static func moneyCompact(_ amount: Decimal, _ code: String) -> String {
        if amountsHidden { return privacyMask }
        let value = (amount as NSDecimalNumber).doubleValue
        let sign = value < 0 ? "-" : ""
        let magnitude = Swift.abs(value)
        let sym = symbol(for: code)
        switch magnitude {
        case 1_000_000...:
            return "\(sign)\(sym)\(String(format: "%.2fM", magnitude / 1_000_000))"
        case 10_000...:
            return "\(sign)\(sym)\(String(format: "%.1fk", magnitude / 1_000))"
        case 1_000...:
            return "\(sign)\(sym)\(String(format: "%.2fk", magnitude / 1_000))"
        default:
            return "\(sign)\(sym)\(String(format: magnitude == magnitude.rounded() ? "%.0f" : "%.2f", magnitude))"
        }
    }

    static func quantity(_ value: Decimal) -> String {
        quantityFormatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
    }

    static func percent(_ fraction: Double, decimals: Int = 1, showSign: Bool = true) -> String {
        let sign = fraction < 0 ? "-" : (showSign && fraction > 0 ? "+" : "")
        return "\(sign)\(String(format: "%.\(decimals)f", Swift.abs(fraction) * 100))%"
    }

    static let dateMedium: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()
    static let dateShort: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy HH:mm"
        return f
    }()
    static let monthShort: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM"
        return f
    }()
    static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f
    }()

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    static let privacyMask = "•••••"
}

@inline(__always) func abs(_ d: Decimal) -> Decimal { d < 0 ? -d : d }

extension Decimal {
    var doubleValue: Double { (self as NSDecimalNumber).doubleValue }
    var isPositive: Bool { self > 0 }
    func rounded(_ scale: Int) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .plain)
        return result
    }
}
