import SwiftUI

// MARK: - Dashboard kit
//
// Dark rounded cards on near-black, solid pastel category cards with dark
// ink, capsule allocation bars with a hatched
// remainder. Only two hues exist, each with one meaning (see RiskFamily):
//   violet = risk assets (equities, crypto); shade = which market
//   lime   = hedges & cash (gold, bonds, cash); shade = which kind
// Gray is "other". Lime is also the interaction color (buttons, selection).

extension DS {
    static let page = Color(light: 0xF2F2EE, dark: 0x141414)
    static let panel = Color(light: 0xFFFFFF, dark: 0x1F1F1F)
    static let tile = Color(light: 0xEBEBE6, dark: 0x2A2A2A)
    static let panelRadius: CGFloat = 22
    static let tileRadius: CGFloat = 18

    static let violet = Color(hex: 0xA98BFA)
    static let violetSoft = Color(hex: 0xCDBDFD)
    static let violetDeep = Color(hex: 0x7E5FE6)
    static let violetDark = Color(hex: 0x5E43B8)
    static let limeSoft = Color(hex: 0xE9FAB0)
    static let lime = Color(hex: 0xD5F56B)
    static let limeDeep = Color(hex: 0x9CB84A)
    static let ink = Color(hex: 0x141414)

    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
}

/// Dark rounded card with an optional title row.
struct Panel<Content: View, Accessory: View>: View {
    var title: String?
    var icon: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                HStack(spacing: 10) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.textPrimary)
                            .frame(width: 30, height: 30)
                            .background(DS.tile)
                            .clipShape(Circle())
                    }
                    Text(title)
                        .font(DS.title(18))
                        .foregroundStyle(DS.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    accessory
                }
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(DS.panel)
        .clipShape(RoundedRectangle(cornerRadius: DS.panelRadius, style: .continuous))
    }
}

extension Panel where Accessory == EmptyView {
    init(title: String? = nil, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.accessory = EmptyView()
        self.content = content()
    }
}

/// Small tinted chip ("US equity" tag).
struct TagChip: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(color.opacity(0.16))
            .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
            .clipShape(Capsule())
    }
}

/// Diagonal hatch, used for "the rest" / empty capacity.
struct Hatch: View {
    var color: Color = .white.opacity(0.10)
    var spacing: CGFloat = 6
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            ctx.stroke(path, with: .color(color), lineWidth: 1.5)
        }
    }
}

/// Horizontal capsule bar split by segments, with gaps; the remainder (if
/// the segments don't sum to 1) is hatched.
struct SegmentBar: View {
    struct Segment: Identifiable {
        let id: String
        let fraction: Double
        let color: Color
    }
    let segments: [Segment]
    var height: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 4
            let visible = segments.filter { $0.fraction > 0 }
            let usable = max(0, geo.size.width - gap * CGFloat(max(visible.count - 1, 0)))
            HStack(spacing: gap) {
                ForEach(visible) { segment in
                    Capsule()
                        .fill(segment.color)
                        .frame(width: max(2, usable * segment.fraction))
                }
                let used = visible.reduce(0) { $0 + $1.fraction }
                if used < 0.999 {
                    Hatch().clipShape(Capsule())
                }
            }
        }
        .frame(height: height)
    }
}

/// Two-option capsule switch in palette colors (replaces the system
/// segmented control, which follows the macOS accent color).
struct CapsuleSwitch<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(label(option))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(selected ? DS.ink : DS.textSecondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(selected ? DS.accent : Color.clear)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(DS.tile)
        .clipShape(Capsule())
    }
}

/// Checkbox in palette colors (the system one follows the macOS accent).
struct LimeCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(configuration.isOn ? DS.accent : DS.tile)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(configuration.isOn ? Color.clear : DS.border, lineWidth: 1)
                    )
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(DS.ink)
                            .opacity(configuration.isOn ? 1 : 0)
                    )
                    .frame(width: 17, height: 17)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
