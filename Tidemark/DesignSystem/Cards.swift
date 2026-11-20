import SwiftUI

// MARK: - Card

struct PhoneCard<Accessory: View, Content: View>: View {
    static var twoColumns: [GridItem] { [GridItem(.flexible(), spacing: TS.gridGap), GridItem(.flexible(), spacing: TS.gridGap)] }

    let title: String
    let icon: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10.5) {
            HStack(spacing: 7.5) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(DS.ink)
                    .frame(width: 20, height: 20)
                    .background(DS.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(title)
                    .font(TS.cardTitle)
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
                accessory
            }
            .frame(minHeight: 27)
            content
        }
        .padding(TS.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.panel)
        .clipShape(RoundedRectangle(cornerRadius: TS.cardRadius, style: .continuous))
    }
}

extension PhoneCard where Accessory == EmptyView {
    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.accessory = EmptyView()
        self.content = content()
    }
}

/// Small toggle chip in a card's title row ("Level 1 ⇄").
struct PhoneChip: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(text)
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 9.5, weight: .medium).monospacedDigit())
            }
            .font(.system(size: 11, weight: .regular).monospacedDigit())
            .foregroundStyle(DS.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 4.5)
            .background(DS.tile)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The figure above a chart: the picked day and its value.

/// The big number at the top of a page: its label (with the eye), the
/// amount, and a line of smaller figures. Ledger and Assets share it.
struct HeroCard<Figures: View>: View {
    let label: String
    var labelColor: Color = DS.textSecondary
    let value: String
    @ViewBuilder var figures: Figures

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AmountsLabel(title: label, color: labelColor)
            Text(value)
                .font(TS.hero)
                .foregroundStyle(DS.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            HStack(spacing: 16) { figures }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.panel)
        .clipShape(RoundedRectangle(cornerRadius: TS.cardRadius, style: .continuous))
    }
}

/// "Income ¥1,234" on one line, label dimmer than the figure.
struct InlineFigure: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(DS.textTertiary)
            Text(value).foregroundStyle(DS.textSecondary)
        }
        .font(TS.label)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}
