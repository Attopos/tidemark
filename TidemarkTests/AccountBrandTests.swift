import XCTest
@testable import Tidemark

final class AccountBrandTests: XCTestCase {
    private func brand(_ name: String, type: String = "", currency: String = "CNY", cash: Bool = false) -> AccountBrand? {
        AccountBrand.match(name: name, typeLabel: type, currency: currency, isCash: cash)
    }

    func testBanksWalletsAndCash() {
        XCTAssertEqual(brand("BOC"), .emblem("acct-boc"))
        XCTAssertEqual(brand("ICBC Visa"), .emblem("acct-icbc"))
        XCTAssertEqual(brand("CITIC"), .emblem("acct-citic"))
        XCTAssertEqual(brand("CMBC"), .emblem("acct-cmbc"))
        XCTAssertEqual(brand("CMB"), .emblem("acct-cmb"))
        XCTAssertEqual(brand("建设银行储蓄卡"), .emblem("acct-ccb"))
        XCTAssertEqual(brand("YEB"), .glyph("acct-alipay", color: 0xFF6A00))
        XCTAssertEqual(brand("Savings", type: "Yu'E Bao"), .glyph("acct-alipay", color: 0xFF6A00))
        XCTAssertEqual(brand("WECHAT"), .glyph("acct-wechat", color: 0x07C160))
        XCTAssertEqual(brand("支付宝"), .glyph("acct-alipay", color: 0x1677FF))
        XCTAssertEqual(brand("EUR CASH", currency: "EUR", cash: true), .flag("EUR"))
        XCTAssertEqual(brand("THB CASH", currency: "THB", cash: true), .flag("THB"))
        XCTAssertEqual(brand("Wallet", currency: "KRW", cash: true), .flag("KRW"))
        XCTAssertEqual(brand("VISA-US", currency: "USD"), .glyph("acct-visa", color: 0x1A1F71))
        XCTAssertEqual(brand("T-money Card KR", currency: "KRW"), .symbol("tram.fill", color: 0x2E8BFF))
        XCTAssertEqual(brand("SiSYPHE Coffee"), .symbol("cup.and.saucer.fill", color: 0x8B5A3C))
    }

    func testEveryIconFileIsBundled() {
        let names = ["acct-boc", "acct-icbc", "acct-ccb", "acct-abc", "acct-cmb", "acct-citic", "acct-bocom", "acct-psbc",
                     "acct-spdb", "acct-cib", "acct-cmbc", "acct-bob", "acct-bosh", "acct-wechat", "acct-alipay", "acct-visa",
                     "acct-paypal", "acct-revolut", "acct-wise", "acct-hsbc"]
            + AccountTypePreset.all.compactMap { preset -> String? in
                if case .glyph(let name, _) = preset.brand { return name }
                if case .emblem(let name) = preset.brand { return name }
                return nil
            }
            + AccountBrand.flagCurrencies.map { "flag-\($0.lowercased())" }
        for name in names {
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: "png"), name)
        }
    }

    func testNoFalseMatchesInsideWords() {
        XCTAssertNil(brand("Cabochon"))
        XCTAssertNil(brand("FYC BALANCE", currency: "USD"))
        XCTAssertNil(brand("W"))
    }
}
