import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Color hex helpers

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

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

// MARK: - Design tokens
//
// The visual identity: almost-black surfaces, neon lime as the *interaction*
// color (never a universal "gain" color), warm-white figures, and a reserved
// semantic set for financial meaning. Categorical chart hues are a separate,
// CVD-validated ramp (validated in OKLab against the dark surfaces) assigned
// in fixed order and never cycled.

enum DS {
    // Surfaces
    static let bgPrimary    = Color(hex: 0x111111)
    static let bgSecondary  = Color(hex: 0x1D1D1F)
    static let bgElevated   = Color(hex: 0x27282A)

    // Brand / interaction
    static let accent       = Color(hex: 0xC7FF3D)
    static let accentDark   = Color(hex: 0x29351B)

    // Ink
    static let textPrimary  = Color(hex: 0xF5F3EE)
    static let textSecondary = Color(hex: 0x999A9F)
    static let textTertiary = Color(hex: 0x6B6C70)

    // Lines
    static let border       = Color(hex: 0x303134)

    // Financial semantics — polarity & status only, never series identity
    // Two-hue palette: only violet and lime exist in the UI.
    static let finBlue      = Color(hex: 0xA98BFA)   // neutral financial data (violet)
    static let positive     = Color(hex: 0xD5F56B)   // gains (lime)
    static let negative     = Color(hex: 0xCDBDFD)   // losses (soft violet)
    static let warning      = Color(hex: 0xCDBDFD)   // needs attention / stale (soft violet)

    /// Categorical identity ramp for charts (allocation, categories).
    /// Fixed assignment order; index ≥ count folds into `categoricalOther`.
    /// Validated: OKLCH L 0.48–0.67, C ≥ 0.10, CVD ΔE pass vs dark surface.
    static let categorical: [Color] = [
        Color(hex: 0xA98BFA), Color(hex: 0xD5F56B), Color(hex: 0x7E5FE6),
        Color(hex: 0x9CB84A), Color(hex: 0xCDBDFD), Color(hex: 0xE9FAB0), Color(hex: 0x5E43B8),
    ]
    static let categoricalOther = Color(hex: 0x6B6C70)

    static func categoryColor(_ index: Int) -> Color {
        index >= 0 && index < categorical.count ? categorical[index] : categoricalOther
    }

    // The signature lime hero card gradient (dark ink on top of it)
    static let heroGradient = LinearGradient(
        colors: [Color(hex: 0xDCFF7A), Color(hex: 0xC7FF3D), Color(hex: 0xA8E42E)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let heroInk = Color(hex: 0x15190A)
    static let heroInkSecondary = Color(hex: 0x15190A).opacity(0.62)

    // Geometry
    static let cardRadius: CGFloat = 16
    static let smallRadius: CGFloat = 10
    static let pagePadding: CGFloat = 28
    static let cardPadding: CGFloat = 18
    static let gridGap: CGFloat = 14

    // MARK: Typography

    /// Oversized editorial page heading ("Portfolio overview")
    static func editorial(_ size: CGFloat = 38) -> Font {
        .system(size: size, weight: .bold, design: .default)
    }
    static let sectionTitle = Font.system(size: 17, weight: .semibold)
    /// Small uppercase section label
    static let label = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 15)
    static let caption = Font.system(size: 13.5)

    /// Monetary figures — always tabular
    static func money(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
    static let moneyHero = money(40, weight: .bold)
    static let moneyLarge = money(28, weight: .bold)
    static let moneyMedium = money(19)
    static let moneySmall = money(15, weight: .medium)
    static let moneyTable = money(15, weight: .medium)
}

// MARK: - Shared style modifiers

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

// MARK: - Formatters
//
// All money is stored as Decimal. Formatting goes through one place so
// currency symbols, tabular layout and privacy masking stay consistent.

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

    /// "¥12,345.67", "-$1,200.00", "+€35.00"
    static func money(_ amount: Decimal, _ code: String, showSign: Bool = false, wholeDigits: Bool = false) -> String {
        let number = NSDecimalNumber(decimal: abs(amount))
        let formatter = wholeDigits ? wholeFormatter : groupedFormatter
        let digits = formatter.string(from: number) ?? "\(number)"
        let sign = amount < 0 ? "-" : (showSign && amount > 0 ? "+" : "")
        return "\(sign)\(symbol(for: code))\(digits)"
    }

    /// Compact axis/summary form: "¥12.5k", "¥1.24M"
    static func moneyCompact(_ amount: Decimal, _ code: String) -> String {
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

    /// "+12.4%" / "-3.2%"
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

    /// The mask used when privacy mode hides sensitive values.
    static let privacyMask = "•••••"
}

@inline(__always) func abs(_ d: Decimal) -> Decimal { d < 0 ? -d : d }

extension Decimal {
    var doubleValue: Double { (self as NSDecimalNumber).doubleValue }
    var isPositive: Bool { self > 0 }
    /// Rounded to `scale` decimal places, bankers-safe plain rounding.
    func rounded(_ scale: Int) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .plain)
        return result
    }
}
