import SwiftUI

extension DS {
    static let page = Color(light: 0xF6F5F7, dark: 0x0E0D10)
    static let panel = Color(light: 0xFFFFFF, dark: 0x18161B)
    static let tile = Color(light: 0xECEAEE, dark: 0x221F26)
    static let panelRadius: CGFloat = 22
    static let tileRadius: CGFloat = 18
    static let phoneMargin: CGFloat = 25
    static let phoneTopMargin: CGFloat = 25

    static let violet = Color(hex: 0x8E8A96)
    static let violetSoft = Color(hex: 0xC9C5CF)
    static let violetDeep = Color(hex: 0x5F5B66)
    static let violetDark = Color(hex: 0x3A3740)
    static let limeSoft = Color(hex: 0xFFB8D4)
    static let lime = Color(hex: 0xE04A82)
    static let limeDeep = Color(hex: 0xC4276A)
    static let ink = Color(hex: 0x141217)

    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .regular).monospacedDigit() }
}

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
                            .font(.system(size: 13, weight: .regular).monospacedDigit())
                            .foregroundStyle(DS.textPrimary)
                            .frame(width: 30, height: 30)
                            .background(DS.tile)
                            .clipShape(Circle())
                    }
                    Text(title)
                        .font(DS.title(18))
                        .foregroundStyle(DS.textPrimary)
                        .lineLimit(1)
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

struct TagChip: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .regular).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(color.opacity(0.16))
            .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
            .clipShape(Capsule())
    }
}

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

struct CapsuleSwitch<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var compact = false

    init(options: [Value], selection: Binding<Value>, compact: Bool = false, label: @escaping (Value) -> String) {
        self.options = options
        self._selection = selection
        self.compact = compact
        self.label = label
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(label(option))
                        .font(.system(size: compact ? 11.5 : 13, weight: .regular).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(selected ? DS.textPrimary : DS.textSecondary)
                        .padding(.horizontal, compact ? 9 : 11)
                        .padding(.vertical, compact ? 3.5 : 5)
                        .background(selected ? DS.selection : Color.clear)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(compact ? 2.5 : 3)
        .background(DS.tile)
        .clipShape(Capsule())
    }
}

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
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
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
