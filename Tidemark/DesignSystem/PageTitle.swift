import SwiftUI

/// Title row at the top of a main page: large title on the left, round
/// actions on the right. The same on every tab.
struct PageTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                #if os(iOS)
                .font(.system(size: 34, weight: .bold))
                #else
                .font(DS.title(30))
                #endif
                .foregroundStyle(DS.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            trailing
        }
    }
}

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
