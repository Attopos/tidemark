import SwiftUI

enum AccountBrand: Equatable {
    case bank(mark: String, color: UInt32)
    case symbol(String, color: UInt32)
    case wordmark(String, color: UInt32)
    case flag(String)
    case mastercard

    private static let banks: [(words: [String], mark: String, color: UInt32)] = [
        (["cmbc", "民生"], "民", 0x00A0E9),
        (["bocom", "交通银行", "交行"], "交", 0x1D2088),
        (["boc", "中国银行", "中行", "bank of china"], "中", 0xB81C22),
        (["icbc", "工商", "工行"], "工", 0xC7000B),
        (["ccb", "建设银行", "建行"], "建", 0x0066B3),
        (["abc", "农业银行", "农行"], "农", 0x00936B),
        (["cmb", "招商", "招行"], "招", 0xD7000F),
        (["citic", "中信"], "信", 0xE60012),
        (["psbc", "邮储", "邮政"], "邮", 0x007F3D),
        (["spdb", "浦发"], "浦", 0x0E3E8E),
        (["cib", "兴业"], "兴", 0x004B9C),
        (["ceb", "光大"], "光", 0x6B2C91),
        (["pingan", "平安"], "平", 0xFF6600),
        (["cgb", "广发"], "广", 0xC8102E),
        (["hxb", "华夏"], "华", 0xD7000F),
        (["webank", "微众"], "微", 0x2F6BFF),
        (["hsbc", "汇丰"], "H", 0xDB0011),
        (["revolut"], "R", 0x191C1F),
        (["wise"], "W", 0x9FE870),
        (["paypal"], "P", 0x003087),
    ]

    private static let flags: [String: String] = [
        "CNY": "🇨🇳", "USD": "🇺🇸", "EUR": "🇪🇺", "THB": "🇹🇭", "KRW": "🇰🇷", "VND": "🇻🇳", "EGP": "🇪🇬",
        "GEL": "🇬🇪", "TRY": "🇹🇷", "JPY": "🇯🇵", "HKD": "🇭🇰", "GBP": "🇬🇧", "TWD": "🇹🇼", "SGD": "🇸🇬",
        "AUD": "🇦🇺", "CAD": "🇨🇦", "CHF": "🇨🇭", "MOP": "🇲🇴", "MYR": "🇲🇾", "IDR": "🇮🇩", "PHP": "🇵🇭",
        "INR": "🇮🇳", "AED": "🇦🇪", "RUB": "🇷🇺", "MXN": "🇲🇽", "NZD": "🇳🇿",
    ]

    private static func currencyIn(_ name: String) -> String? {
        let words = name.uppercased().split { !$0.isLetter }.map(String.init)
        return words.first { flags[$0] != nil }
    }

    static func match(name: String, typeLabel: String, currency: String, isCash: Bool) -> AccountBrand? {
        let text = "\(name) \(typeLabel)".lowercased()
        func has(_ words: [String]) -> Bool {
            words.contains { word in
                guard word.allSatisfy({ $0.isASCII && $0.isLetter }) else { return text.contains(word) }
                return text.split { !$0.isLetter }.contains { $0 == Substring(word) }
            }
        }
        if has(["wechat", "微信", "weixin"]) { return .symbol("bubble.left.and.bubble.right.fill", color: 0x07C160) }
        if has(["yeb", "余额宝", "yu'e", "yue bao"]) || text.contains("yu'e bao") { return .wordmark("余", color: 0xFF6A00) }
        if has(["alipay", "支付宝", "花呗", "huabei"]) { return .wordmark("支", color: 0x1677FF) }
        if has(["unionpay", "银联"]) { return .wordmark("银联", color: 0xE21836) }
        for bank in banks where has(bank.words) { return .bank(mark: bank.mark, color: bank.color) }
        if has(["visa"]) { return .wordmark("VISA", color: 0x1A1F71) }
        if has(["mastercard", "master"]) { return .mastercard }
        if has(["t-money", "tmoney", "octopus", "transit", "metro", "公交", "地铁", "交通卡", "suica"]) || text.contains("t-money") {
            return .symbol("tram.fill", color: 0x2E8BFF)
        }
        if has(["coffee", "cafe", "咖啡", "starbucks", "luckin"]) { return .symbol("cup.and.saucer.fill", color: 0x8B5A3C) }
        if has(["shop", "store", "店", "超市", "mall"]) { return .symbol("bag.fill", color: 0xE07A2F) }
        if isCash || has(["cash", "现金"]) {
            if let code = currencyIn(name) ?? (flags[currency.uppercased()] != nil ? currency.uppercased() : nil),
               let flag = flags[code] {
                return .flag(flag)
            }
            return .symbol("banknote.fill", color: 0x3BA55C)
        }
        return nil
    }
}

extension Account {
    var brand: AccountBrand? {
        AccountBrand.match(name: name, typeLabel: typeLabel, currency: currencyCode, isCash: kind == .cash)
    }
}

struct AccountBrandBadge: View {
    let brand: AccountBrand
    var size: CGFloat

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        switch brand {
        case .bank(let mark, let color):
            ZStack {
                Circle().fill(Color.white)
                Circle().strokeBorder(Color(hex: color), lineWidth: size * 0.075).padding(size * 0.1)
                Text(mark)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .default))
                    .foregroundStyle(Color(hex: color))
            }
        case .symbol(let name, let color):
            ZStack {
                Circle().fill(Color(hex: color))
                Image(systemName: name)
                    .font(.system(size: size * 0.42, weight: .regular))
                    .foregroundStyle(.white)
            }
        case .wordmark(let text, let color):
            ZStack {
                Circle().fill(Color(hex: color))
                Text(text)
                    .font(.system(size: size * (text.count > 2 ? 0.26 : 0.42), weight: .semibold, design: .default))
                    .italic(text == "VISA")
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, size * 0.1)
            }
        case .flag(let flag):
            ZStack {
                Circle().fill(Color.white)
                Text(flag)
                    .font(.system(size: size * 1.25))
                    .fixedSize()
            }
        case .mastercard:
            ZStack {
                Circle().fill(Color(hex: 0x1C1C1E))
                HStack(spacing: -size * 0.14) {
                    Circle().fill(Color(hex: 0xEB001B)).frame(width: size * 0.36)
                    Circle().fill(Color(hex: 0xF79E1B).opacity(0.9)).frame(width: size * 0.36)
                }
            }
        }
    }
}
