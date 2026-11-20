import SwiftUI

/// One type and spacing scale for every page's cards, so Ledger, Assets,
/// Portfolio and Analysis read the same. The phone is compact; the Mac a
/// little larger.
enum TS {
    #if os(iOS)
    private static let k: CGFloat = 1
    #else
    private static let k: CGFloat = 1.08
    #endif

    static let cardTitle = Font.system(size: 16.5 * k).monospacedDigit()
    static let title = Font.system(size: 15 * k).monospacedDigit()
    static let body = Font.system(size: 14 * k).monospacedDigit()
    static let label = Font.system(size: 13 * k).monospacedDigit()
    static let caption = Font.system(size: 12 * k).monospacedDigit()
    static let micro = Font.system(size: 10.5 * k).monospacedDigit()

    static let hero = DS.money(30 * k)
    static let figure = DS.money(18.5 * k)
    static let rowFigure = DS.money(15.5 * k)

    static let cardPadding: CGFloat = 12.5 * k
    static let cardRadius: CGFloat = 24
    static let cardSpacing: CGFloat = 10
    static let gridGap: CGFloat = 7.5
    static let rowInsetH: CGFloat = 14
    static let rowInsetV: CGFloat = 11
    static let rowIcon: CGFloat = 34 * k
}
