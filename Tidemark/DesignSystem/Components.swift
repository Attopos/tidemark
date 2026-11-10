import SwiftUI

// MARK: - Shared design-system components

/// Small uppercase section label.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(DS.label)
            .tracking(1.4)
            .foregroundStyle(DS.textSecondary)
    }
}

/// Monetary text with tabular figures.
struct MoneyText: View {
    let amount: Decimal
    let code: String
    var font: Font = DS.moneyMedium
    var color: Color = DS.textPrimary
    var showSign = false
    var compact = false
    var wholeDigits = false

    init(_ amount: Decimal, _ code: String, font: Font = DS.moneyMedium,
         color: Color = DS.textPrimary, showSign: Bool = false,
         compact: Bool = false, wholeDigits: Bool = false) {
        self.amount = amount
        self.code = code
        self.font = font
        self.color = color
        self.showSign = showSign
        self.compact = compact
        self.wholeDigits = wholeDigits
    }

    var body: some View {
        Text(compact ? Fmt.moneyCompact(amount, code) : Fmt.money(amount, code, showSign: showSign, wholeDigits: wholeDigits))
            .font(font)
            .foregroundStyle(color)
    }
}

/// Card container with optional header.
struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    var minHeight: CGFloat?
    /// Stretch to the row's height (cards placed side by side).
    var fillHeight = false
    @ViewBuilder var content: Content

    init(title: String? = nil, subtitle: String? = nil, minHeight: CGFloat? = nil,
         fillHeight: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.minHeight = minHeight
        self.fillHeight = fillHeight
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if let title { SectionLabel(title) }
                    if let subtitle {
                        Text(subtitle)
                            .font(DS.caption)
                            .foregroundStyle(DS.textTertiary)
                    }
                }
            }
            content
        }
        .padding(DS.cardPadding)
        .frame(maxWidth: .infinity, minHeight: minHeight,
               maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .cardSurface()
    }
}

struct AccentButtonStyle: ButtonStyle {
    var prominent = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(prominent ? DS.heroInk : DS.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(prominent ? DS.accent : DS.accentDark)
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(DS.textPrimary)
            .padding(.horizontal, 13)
            .padding(.vertical, 6.5)
            .background(DS.bgElevated)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(DS.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// "Updated 2 hr. ago", amber when stale.
struct FreshnessLabel: View {
    let date: Date?
    var staleAfterDays: Double = 7
    var body: some View {
        if let date {
            let stale = Date().timeIntervalSince(date) > staleAfterDays * 86_400
            HStack(spacing: 4) {
                Image(systemName: stale ? "clock.badge.exclamationmark" : "clock")
                    .font(.system(size: 11.5))
                Text("\(tr("Updated")) \(Fmt.relative(date))")
                    .font(DS.caption)
            }
            .foregroundStyle(stale ? DS.warning : DS.textTertiary)
        } else {
            Text(tr("Never updated"))
                .font(DS.caption)
                .foregroundStyle(DS.warning)
        }
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actions: [(label: String, prominent: Bool, action: () -> Void)] = []

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(DS.textTertiary)
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(DS.textPrimary)
            Text(message)
                .font(DS.body)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if !actions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, item in
                        Button(item.label, action: item.action)
                            .buttonStyle(item.prominent ? AnyButtonStyle(AccentButtonStyle()) : AnyButtonStyle(GhostButtonStyle()))
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(32)
    }
}

/// Type-erased button style so empty states can mix styles.
struct AnyButtonStyle: ButtonStyle {
    private let _makeBody: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) {
        _makeBody = { AnyView(style.makeBody(configuration: $0)) }
    }
    func makeBody(configuration: Configuration) -> some View {
        _makeBody(configuration)
    }
}

/// Legend row used beside charts (identity is never color-alone).
struct LegendRow: View {
    let color: Color
    let label: String
    var value: String?
    var share: String?
    var dimmed = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(color)
                .frame(width: 9, height: 9)
            Text(label)
                .font(DS.body)
                .foregroundStyle(DS.textPrimary)
                .lineLimit(1)
            Spacer()
            if let share {
                Text(share)
                    .font(DS.moneySmall)
                    .foregroundStyle(DS.textTertiary)
            }
            if let value {
                Text(value)
                    .font(DS.moneySmall)
                    .foregroundStyle(DS.textSecondary)
            }
        }
        .opacity(dimmed ? 0.4 : 1)
    }
}

/// Notice strip (storage problems, low-confidence OCR fields).
struct DataQualityIssue: Identifiable {
    enum Severity { case info, warning }
    let id = UUID()
    let severity: Severity
    let icon: String
    let message: String

    init(severity: Severity, icon: String, message: String) {
        self.severity = severity
        self.icon = icon
        self.message = message
    }
}

struct IssueBanner: View {
    let issue: DataQualityIssue
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: issue.icon)
                .font(.system(size: 14.5))
                .foregroundStyle(issue.severity == .warning ? DS.warning : DS.finBlue)
            Text(issue.message)
                .font(DS.caption)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background((issue.severity == .warning ? DS.warning : DS.finBlue).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous)
                .strokeBorder((issue.severity == .warning ? DS.warning : DS.finBlue).opacity(0.25), lineWidth: 1)
        )
    }
}
