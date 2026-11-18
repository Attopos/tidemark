import SwiftUI

enum AccountBrand: Equatable {
    case emblem(String)
    case glyph(String, color: UInt32)
    case bank(mark: String, color: UInt32)
    case symbol(String, color: UInt32)
    case flag(String)
    case mastercard

    private static let banks: [(words: [String], brand: AccountBrand)] = [
        (["cmbc", "民生"], .emblem("acct-cmbc")),
        (["bocom", "交通银行", "交行"], .emblem("acct-bocom")),
        (["boc", "中国银行", "中行", "bank of china"], .emblem("acct-boc")),
        (["icbc", "工商", "工行"], .emblem("acct-icbc")),
        (["ccb", "建设银行", "建行"], .emblem("acct-ccb")),
        (["abc", "农业银行", "农行"], .emblem("acct-abc")),
        (["cmb", "招商", "招行"], .emblem("acct-cmb")),
        (["citic", "中信"], .emblem("acct-citic")),
        (["psbc", "邮储", "邮政"], .emblem("acct-psbc")),
        (["spdb", "浦发"], .emblem("acct-spdb")),
        (["cib", "兴业"], .emblem("acct-cib")),
        (["bob", "北京银行"], .emblem("acct-bob")),
        (["bosh", "上海银行"], .emblem("acct-bosh")),
        (["hsbc", "汇丰"], .glyph("acct-hsbc", color: 0xDB0011)),
        (["revolut"], .glyph("acct-revolut", color: 0x0075EB)),
        (["wise"], .glyph("acct-wise", color: 0x163300)),
        (["paypal"], .glyph("acct-paypal", color: 0x003087)),
        (["chase"], .glyph("acct-chase", color: 0x117ACA)),
        (["bofa", "bank of america"], .glyph("acct-bankofamerica", color: 0x012169)),
        (["wells fargo", "wellsfargo"], .glyph("acct-wellsfargo", color: 0xD71E28)),
        (["barclays"], .glyph("acct-barclays", color: 0x00AEEF)),
        (["n26"], .glyph("acct-n26", color: 0x36A18B)),
        (["monzo"], .glyph("acct-monzo", color: 0xFF4F40)),
        (["starling"], .glyph("acct-starlingbank", color: 0x6935D3)),
        (["venmo"], .glyph("acct-venmo", color: 0x008CFF)),
        (["cash app", "cashapp"], .glyph("acct-cashapp", color: 0x00C244)),
        (["payoneer"], .glyph("acct-payoneer", color: 0xFF4800)),
        (["klarna"], .glyph("acct-klarna", color: 0x17120F)),
        (["amex", "american express"], .glyph("acct-americanexpress", color: 0x2E77BC)),
        (["jcb"], .glyph("acct-jcb", color: 0x0B4EA2)),
        (["discover"], .glyph("acct-discover", color: 0xFF6000)),
        (["diners"], .glyph("acct-dinersclub", color: 0x004C97)),
        (["apple cash", "apple pay", "applepay"], .glyph("acct-applepay", color: 0x000000)),
        (["qq"], .glyph("acct-qq", color: 0x12B7F5)),
        (["douyin", "抖音", "tiktok"], .glyph("acct-tiktok", color: 0x000000)),
        (["meituan", "美团"], .glyph("acct-meituan", color: 0xFFC300)),
        (["kakao"], .glyph("acct-kakao", color: 0x3C1E1E)),
        (["line pay", "line"], .glyph("acct-line", color: 0x06C755)),
        (["naver"], .glyph("acct-naver", color: 0x03C75A)),
        (["grab"], .glyph("acct-grab", color: 0x00B14F)),
        (["gojek", "gopay"], .glyph("acct-gojek", color: 0x00AA13)),
        (["ceb", "光大"], .bank(mark: "光", color: 0x6B2C91)),
        (["pingan", "平安"], .bank(mark: "平", color: 0xFF6600)),
        (["cgb", "广发"], .bank(mark: "广", color: 0xC8102E)),
        (["hxb", "华夏"], .bank(mark: "华", color: 0xD7000F)),
        (["webank", "微众"], .bank(mark: "微", color: 0x2F6BFF)),
    ]

    static let flagCurrencies: Set<String> = [
        "CNY", "USD", "EUR", "THB", "KRW", "VND", "EGP", "GEL", "TRY", "JPY", "HKD", "GBP", "TWD", "SGD",
        "AUD", "CAD", "CHF", "MOP", "MYR", "IDR", "PHP", "INR", "AED", "RUB", "MXN", "NZD",
    ]

    private static func currencyIn(_ name: String) -> String? {
        name.uppercased().split { !$0.isLetter }.map(String.init).first { flagCurrencies.contains($0) }
    }

    static func match(name: String, typeLabel: String, currency: String, isCash: Bool) -> AccountBrand? {
        let text = "\(name) \(typeLabel)".lowercased()
        func has(_ words: [String]) -> Bool {
            words.contains { word in
                guard word.allSatisfy({ $0.isASCII && $0.isLetter }) else { return text.contains(word) }
                return text.split { !$0.isLetter }.contains { $0 == Substring(word) }
            }
        }
        if has(["wechat", "微信", "weixin"]) { return .glyph("acct-wechat", color: 0x07C160) }
        if has(["yeb", "余额宝", "yu'e", "yue bao"]) { return .glyph("acct-alipay", color: 0xFF6A00) }
        if has(["alipay", "支付宝", "花呗", "huabei"]) { return .glyph("acct-alipay", color: 0x1677FF) }
        for bank in banks where has(bank.words) { return bank.brand }
        if has(["visa"]) { return .glyph("acct-visa", color: 0x1A1F71) }
        if has(["mastercard", "master"]) { return .mastercard }
        if has(["t-money", "tmoney", "octopus", "transit", "metro", "公交", "地铁", "交通卡", "suica"]) {
            return .symbol("tram.fill", color: 0x2E8BFF)
        }
        if has(["coffee", "cafe", "咖啡", "starbucks", "luckin"]) { return .symbol("cup.and.saucer.fill", color: 0x8B5A3C) }
        if has(["shop", "store", "店", "超市", "mall"]) { return .symbol("bag.fill", color: 0xE07A2F) }
        if isCash || has(["cash", "现金"]) {
            let code = currencyIn(name) ?? currency.uppercased()
            if flagCurrencies.contains(code) { return .flag(code) }
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

enum AccountIconImages {
    @MainActor private static var cache: [String: PlatformImage] = [:]

    @MainActor
    static func image(_ name: String) -> PlatformImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = PlatformImage.load(url) else { return nil }
        cache[name] = image
        return image
    }
}

struct AccountBrandBadge: View {
    let brand: AccountBrand
    var size: CGFloat

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(Circle())
    }

    @ViewBuilder
    private func picture(_ name: String) -> some View {
        if let image = AccountIconImages.image(name) {
            Image(platformImage: image).resizable().interpolation(.high).scaledToFit()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch brand {
        case .emblem(let name):
            ZStack {
                Circle().fill(Color.white)
                picture(name).padding(size * 0.17)
            }
        case .glyph(let name, let color):
            ZStack {
                Circle().fill(Color(hex: color))
                picture(name)
                    .colorInvert()
                    .padding(size * 0.24)
            }
        case .flag(let code):
            ZStack {
                Circle().fill(Color.white)
                picture("flag-\(code.lowercased())")
            }
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
