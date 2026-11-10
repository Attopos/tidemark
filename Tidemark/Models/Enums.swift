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
