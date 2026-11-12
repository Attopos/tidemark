import Foundation
import SwiftUI

// MARK: - Account kinds

enum AccountKind: String, Codable, CaseIterable, Identifiable {
    case cash
    case payment       // wallets, bank cards, e-pay balances
    case investment
    case crypto
    case other         // receivables, deposits, misc assets
    case liability     // credit cards, loans, BNPL

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cash: return tr("Cash")
        case .payment: return tr("Payment")
        case .investment: return tr("Investment")
        case .crypto: return tr("Crypto")
        case .other: return tr("Other assets")
        case .liability: return tr("Liabilities")
        }
    }

    var icon: String {
        switch self {
        case .cash: return "banknote"
        case .payment: return "creditcard"
        case .investment: return "chart.line.uptrend.xyaxis"
        case .crypto: return "bitcoinsign.circle"
        case .other: return "shippingbox"
        case .liability: return "minus.circle"
        }
    }

    var isAsset: Bool { self != .liability }
    /// Counts toward liquid runway
    var isLiquid: Bool { self == .cash || self == .payment }

    var sortRank: Int {
        switch self {
        case .cash: return 0
        case .payment: return 1
        case .investment: return 2
        case .crypto: return 3
        case .other: return 4
        case .liability: return 5
        }
    }

    /// Guess an account kind from an imported account name (iCost has no kind column).
    static func guess(fromName name: String) -> AccountKind {
        let n = name.lowercased()
        if n.isEmpty { return .cash }
        let liabilityHints = ["visa", "master", "credit", "信用", "花呗", "白条", "amex", "贷", "loan"]
        if liabilityHints.contains(where: n.contains) { return .liability }
        let cashHints = ["cash", "现金"]
        if cashHints.contains(where: n.contains) { return .cash }
        let cryptoHints = ["binance", "okx", "coinbase", "crypto", "btc", "eth", "币安"]
        if cryptoHints.contains(where: n.contains) { return .crypto }
        let investHints = ["fund", "基金", "证券", "股票", "broker", "ths", "同花顺", "雪球", "华泰", "中信建投"]
        if investHints.contains(where: n.contains) { return .investment }
        let paymentHints = ["yeb", "余额", "alipay", "支付宝", "wechat", "微信", "boc", "icbc", "abc", "cmb", "ccb",
                            "citic", "cgb", "spdb", "bank", "银行", "balance", "pay", "card"]
        if paymentHints.contains(where: n.contains) { return .payment }
        return .payment
    }
}

// MARK: - Asset classes

enum AssetClass: String, Codable, CaseIterable, Identifiable {
    case cash
    case moneyMarket
    case bond
    case equity
    case mixedFund
    case crypto
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cash: return tr("Cash")
        case .moneyMarket: return tr("Money market")
        case .bond: return tr("Bonds")
        case .equity: return tr("Equity")
        case .mixedFund: return tr("Mixed funds")
        case .crypto: return tr("Crypto")
        case .other: return tr("Other")
        }
    }

    /// Fixed categorical color assignment (never cycled)
    var colorIndex: Int {
        switch self {
        case .cash: return 0
        case .moneyMarket: return 5
        case .bond: return 2
        case .equity: return 3
        case .mixedFund: return 4
        case .crypto: return 1
        case .other: return 7 // folds to "other" gray
        }
    }
    var color: Color { DS.categoryColor(colorIndex) }

    var isLiquid: Bool { self == .cash || self == .moneyMarket }

    /// Guess the class of a Chinese mutual fund from its name.
    static func guessFund(name: String) -> AssetClass {
        if name.contains("货币") || name.contains("现金") { return .moneyMarket }
        if name.contains("债") { return .bond }
        if name.contains("混合") { return .mixedFund }
        if name.contains("股票") || name.contains("指数") || name.contains("ETF")
            || name.contains("联接") || name.contains("QDII") { return .equity }
        return .mixedFund
    }
}

// MARK: - Transaction kinds

enum TransactionKind: String, Codable, CaseIterable, Identifiable {
    case income
    case expense
    case transfer
    case investBuy
    case investSell
    case liabilityPayment
    case adjustment

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .income: return tr("Income")
        case .expense: return tr("Expense")
        case .transfer: return tr("Transfer")
        case .investBuy: return tr("Invest · buy")
        case .investSell: return tr("Invest · sell")
        case .liabilityPayment: return tr("Repayment")
        case .adjustment: return tr("Adjustment")
        }
    }

    var icon: String {
        switch self {
        case .income: return "arrow.down.left"
        case .expense: return "arrow.up.right"
        case .transfer: return "arrow.left.arrow.right"
        case .investBuy: return "chart.line.uptrend.xyaxis"
        case .investSell: return "chart.line.downtrend.xyaxis"
        case .liabilityPayment: return "creditcard"
        case .adjustment: return "slider.horizontal.3"
        }
    }

    /// Counts in income/expense cash-flow statistics.
    var isConsumptionFlow: Bool { self == .income || self == .expense }

    var color: Color {
        switch self {
        case .income: return DS.positive
        case .expense: return DS.textPrimary
        case .transfer: return DS.finBlue
        case .investBuy, .investSell: return DS.finBlue
        case .liabilityPayment: return DS.warning
        case .adjustment: return DS.textSecondary
        }
    }
}

// MARK: - Data sources

enum DataSource: String, Codable, CaseIterable, Identifiable {
    case manual
    case icost
    case alipayOCR
    case binance
    case market
    case sample

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual: return tr("Manual")
        case .icost: return "iCost"
        case .alipayOCR: return tr("Alipay OCR")
        case .binance: return "Binance"
        case .market: return tr("Market data")
        case .sample: return tr("Sample data")
        }
    }

    var icon: String {
        switch self {
        case .manual: return "pencil"
        case .icost: return "tablecells"
        case .alipayOCR: return "text.viewfinder"
        case .binance: return "bitcoinsign"
        case .market: return "globe"
        case .sample: return "sparkles"
        }
    }
}

// MARK: - Recurrence

enum Frequency: String, Codable, CaseIterable, Identifiable {
    case weekly
    case monthly
    case quarterly
    case semiannual
    case yearly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weekly: return tr("Weekly")
        case .monthly: return tr("Monthly")
        case .quarterly: return tr("Quarterly")
        case .semiannual: return tr("Every 6 months")
        case .yearly: return tr("Yearly")
        }
    }

    var occurrencesPerYear: Decimal {
        switch self {
        case .weekly: return 52
        case .monthly: return 12
        case .quarterly: return 4
        case .semiannual: return 2
        case .yearly: return 1
        }
    }

    func monthlyEquivalent(of amount: Decimal) -> Decimal {
        (amount * occurrencesPerYear / 12).rounded(2)
    }

    func yearlyEquivalent(of amount: Decimal) -> Decimal {
        (amount * occurrencesPerYear).rounded(2)
    }

    func next(after date: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .weekly: return calendar.date(byAdding: .day, value: 7, to: date) ?? date
        case .monthly: return calendar.date(byAdding: .month, value: 1, to: date) ?? date
        case .quarterly: return calendar.date(byAdding: .month, value: 3, to: date) ?? date
        case .semiannual: return calendar.date(byAdding: .month, value: 6, to: date) ?? date
        case .yearly: return calendar.date(byAdding: .year, value: 1, to: date) ?? date
        }
    }
}

// MARK: - Time ranges

enum TimeRange: String, CaseIterable, Identifiable {
    case m1 = "1M"
    case m3 = "3M"
    case m6 = "6M"
    case y1 = "1Y"
    case all = "ALL"

    var id: String { rawValue }
    var label: String { rawValue }

    /// Start date for the range; `.all` returns nil (use earliest data).
    func start(from now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .m1: return calendar.date(byAdding: .month, value: -1, to: now)
        case .m3: return calendar.date(byAdding: .month, value: -3, to: now)
        case .m6: return calendar.date(byAdding: .month, value: -6, to: now)
        case .y1: return calendar.date(byAdding: .year, value: -1, to: now)
        case .all: return nil
        }
    }
}

// MARK: - Import status

enum ImportStatus: String, Codable {
    case success
    case partial
    case failed

    var displayName: String {
        switch self {
        case .success: return tr("Imported")
        case .partial: return tr("Partial")
        case .failed: return tr("Failed")
        }
    }
}

// MARK: - Calendar helpers

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? date
    }
    func endOfMonth(for date: Date) -> Date {
        let start = startOfMonth(for: date)
        return self.date(byAdding: DateComponents(month: 1, second: -1), to: start) ?? date
    }
    func monthsBetween(_ a: Date, _ b: Date) -> Int {
        dateComponents([.month], from: startOfMonth(for: a), to: startOfMonth(for: b)).month ?? 0
    }
}

// MARK: - Risk exposure
//
// What a holding is actually exposed to, independent of the wrapper: a CNY
// QDII fund tracking the S&P 500 and a tokenized SPY on Binance are both US
// equity; a gold ETF feeder fund is gold, not equity. This is the first level
// of the portfolio view; holdings are the second. Guessed from name/ticker,
// overridable per asset.

enum Exposure: String, CaseIterable, Identifiable {
    case usEquity
    case chinaEquity
    case intlEquity
    case crypto
    case gold
    case bond
    case cash
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .usEquity: return tr("US equity")
        case .chinaEquity: return tr("China equity")
        case .intlEquity: return tr("Other intl equity")
        case .crypto: return tr("Crypto")
        case .gold: return tr("Gold")
        case .bond: return tr("Bonds")
        case .cash: return tr("Cash")
        case .other: return tr("Other")
        }
    }

    /// Color = risk family (violet risk assets, lime hedges & cash), shade =
    /// which one inside it. Fixed, never by rank.
    var color: Color {
        switch self {
        case .usEquity: return DS.violet
        case .intlEquity: return DS.violetSoft
        case .chinaEquity: return DS.violetDeep
        case .crypto: return DS.violetDark
        case .gold: return DS.lime
        case .bond: return DS.limeDeep
        case .cash: return DS.limeSoft
        case .other: return DS.textTertiary
        }
    }

    var family: RiskFamily {
        switch self {
        case .usEquity, .chinaEquity, .intlEquity, .crypto: return .risk
        case .gold, .bond, .cash: return .hedge
        case .other: return .other
        }
    }

    static func guess(name: String, symbol: String, assetClass: AssetClass) -> Exposure {
        let n = (name + " " + symbol).lowercased()
        func has(_ words: [String]) -> Bool { words.contains { n.contains($0) } }
        let sym = symbol.uppercased()

        if ["USDT", "USDC", "FDUSD", "BUSD", "DAI"].contains(sym) || assetClass == .cash
            || assetClass == .moneyMarket || has(["货币", "现金", "余额宝"]) { return .cash }
        if ["PAXG", "XAUT", "GLD", "IAU"].contains(sym) || has(["黄金", "上海金", "gold"]) { return .gold }
        if has(["债", "bond", "treasury"]) { return .bond }
        if has(["纳斯达克", "标普", "道琼斯", "美国", "s&p", "nasdaq", "dow jones", "spdr", "qqq", "russell"])
            || ["SPY", "QQQ", "VOO", "VTI", "IVV", "DIA", "AAPL", "MSFT", "NVDA", "TSLA", "GOOGL", "AMZN", "META"].contains(sym) {
            return .usEquity
        }
        if assetClass == .crypto { return .crypto }
        if has(["日经", "cac", "dax", "德国", "法国", "欧洲", "日本", "印度", "越南", "英国", "nikkei", "全球", "国际"]) {
            return .intlEquity
        }
        if has(["沪深", "中证", "上证", "深证", "创业板", "科创", "恒生", "港股", "a股", "中国", "红利"])
            || assetClass == .equity || assetClass == .mixedFund { return .chinaEquity }
        return .other
    }
}

extension Asset {
    /// Override when set, otherwise the guess.
    var exposure: Exposure {
        get {
            if let raw = exposureRaw, let chosen = Exposure(rawValue: raw) { return chosen }
            return Exposure.guess(name: name, symbol: symbol, assetClass: assetClass)
        }
        set { exposureRaw = newValue.rawValue }
    }
}

/// What a color means across the app.
enum RiskFamily: CaseIterable {
    case risk, hedge, other

    var displayName: String {
        switch self {
        case .risk: return tr("Risk assets")
        case .hedge: return tr("Hedges & cash")
        case .other: return tr("Other")
        }
    }

    var color: Color {
        switch self {
        case .risk: return DS.violet
        case .hedge: return DS.lime
        case .other: return DS.textTertiary
        }
    }
}

extension Exposure {
    /// Thin marks (share bars, legend squares): the card color in dark mode,
    /// one step deeper in light mode so pale shades still show on white.
    var markColor: Color {
        switch self {
        case .usEquity: return Color(light: 0x8A6CF0, dark: 0xA98BFA)
        case .intlEquity: return Color(light: 0xA98BFA, dark: 0xCDBDFD)
        case .chinaEquity: return Color(light: 0x6A4BD6, dark: 0x7E5FE6)
        case .crypto: return Color(light: 0x5E43B8, dark: 0x5E43B8)
        case .gold: return Color(light: 0x9CB84A, dark: 0xD5F56B)
        case .bond: return Color(light: 0x6B8E12, dark: 0x9CB84A)
        case .cash: return Color(light: 0xB9D95A, dark: 0xE9FAB0)
        case .other: return DS.textTertiary
        }
    }

    /// Text color that reads on `color`.
    var ink: Color {
        self == .crypto || self == .chinaEquity ? .white : DS.ink
    }
}

// MARK: - Account groups (cash side)
//
// How the Accounts page sorts cash-side accounts, the way bookkeeping apps
// do: money you hold, credit you use, prepaid cards, money owed to you and
// money you owe.

enum AccountGroup: String, CaseIterable, Identifiable {
    case fund, credit, recharge, receivable, payable

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fund: return tr("Fund Accounts")
        case .credit: return tr("Credit Accounts")
        case .recharge: return tr("Recharge Accounts")
        case .receivable: return tr("Receivable Accounts")
        case .payable: return tr("Payable Accounts")
        }
    }

    var shortName: String {
        switch self {
        case .fund: return tr("Fund")
        case .credit: return tr("Credit")
        case .recharge: return tr("Recharge")
        case .receivable: return tr("Lent out")
        case .payable: return tr("Borrowed")
        }
    }

    /// The account kind that carries the money semantics for this group.
    var kind: AccountKind {
        switch self {
        case .fund: return .payment
        case .credit, .payable: return .liability
        case .recharge: return .payment
        case .receivable: return .other
        }
    }

    static func guess(kind: AccountKind, name: String) -> AccountGroup {
        let n = name.lowercased()
        switch kind {
        case .liability:
            let credit = ["visa", "master", "credit", "信用", "amex", "unionpay", "花呗", "白条", "card"]
            return credit.contains(where: n.contains) ? .credit : .payable
        case .other:
            return .receivable
        default:
            let recharge = ["shop", "coffee", "t-money", "card", "会员", "充值", "储值", "卡"]
            let banks = ["bank", "银行", "boc", "icbc", "abc", "cmb", "ccb", "citic"]
            if recharge.contains(where: n.contains) && !banks.contains(where: n.contains) { return .recharge }
            return .fund
        }
    }
}

extension Account {
    var group: AccountGroup {
        get { AccountGroup(rawValue: groupRaw) ?? AccountGroup.guess(kind: kind, name: name) }
        set { groupRaw = newValue.rawValue }
    }

    /// What kind of account this looks like, until the user names it.
    var guessedTypeLabel: String {
        let n = name.lowercased()
        switch group {
        case .credit: return tr("Credit Card")
        case .recharge: return tr("Membership Card")
        case .receivable: return tr("Lend")
        case .payable: return tr("Borrow")
        case .fund:
            if kind == .cash || n.contains("cash") || n.contains("现金") { return tr("Cash") }
            if n.contains("wechat") || n.contains("微信") { return tr("WeChat Wallet") }
            if n.contains("yeb") || n.contains("余额宝") { return tr("Yu'E Bao") }
            if n.contains("alipay") || n.contains("支付宝") { return tr("Alipay") }
            return tr("Debit Card")
        }
    }

    /// Days until the next statement, for credit cards with a billing day.
    func daysToBilling(from now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let day = billingDay, (1...31).contains(day) else { return nil }
        let today = calendar.startOfDay(for: now)
        for offset in 0..<2 {
            guard let month = calendar.date(byAdding: .month, value: offset, to: today) else { continue }
            var parts = calendar.dateComponents([.year, .month], from: month)
            let range = calendar.range(of: .day, in: .month, for: month) ?? 1..<29
            parts.day = Swift.min(day, range.upperBound - 1)
            if let date = calendar.date(from: parts), date >= today {
                return calendar.dateComponents([.day], from: today, to: date).day
            }
        }
        return nil
    }
}
