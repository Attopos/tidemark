import SwiftUI
import UIKit

struct PhoneHeader<Leading: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 17, weight: .regular).monospacedDigit())
                .foregroundStyle(DS.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 72)
            HStack(spacing: 16) {
                leading
                Spacer(minLength: 0)
                trailing
            }
        }
        .font(.system(size: 17).monospacedDigit())
        .tint(DS.textPrimary)
        .frame(height: Self.rowHeight)
        .padding(.horizontal, DS.phoneMargin)
        .padding(.top, DS.phoneTopMargin - (Self.rowHeight - TextMetrics.lineHeight(size: 17, weight: .regular)) / 2
                 - TextMetrics.capInset(size: 17, weight: .regular))
        .padding(.bottom, 10)
    }

    static var rowHeight: CGFloat { 32 }
}

extension PhoneHeader where Leading == EmptyView {
    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.leading = EmptyView()
        self.trailing = trailing()
    }
}

extension PhoneHeader where Leading == EmptyView, Trailing == EmptyView {
    init(title: String) {
        self.title = title
        self.leading = EmptyView()
        self.trailing = EmptyView()
    }
}

struct PhoneBackButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .regular).monospacedDigit())
                .frame(width: 32, height: 32, alignment: .leading)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(tr("Back"))
    }
}

extension View {
    func phoneHeader<Header: View>(background: Color = DS.page, @ViewBuilder _ header: () -> Header) -> some View {
        let header = header()
        return self
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                header.background(background)
            }
    }
}

extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
