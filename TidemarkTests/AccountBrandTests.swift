import XCTest
@testable import Tidemark

final class AccountBrandTests: XCTestCase {
    private func brand(_ name: String, type: String = "", currency: String = "CNY", cash: Bool = false) -> AccountBrand? {
        AccountBrand.match(name: name, typeLabel: type, currency: currency, isCash: cash)
    }

    func testBanksWalletsAndCash() {
        XCTAssertEqual(brand("BOC"), .bank(mark: "中", color: 0xB81C22))
        XCTAssertEqual(brand("ICBC Visa"), .bank(mark: "工", color: 0xC7000B))
        XCTAssertEqual(brand("CITIC"), .bank(mark: "信", color: 0xE60012))
        XCTAssertEqual(brand("CMBC"), .bank(mark: "民", color: 0x00A0E9))
        XCTAssertEqual(brand("CMB"), .bank(mark: "招", color: 0xD7000F))
        XCTAssertEqual(brand("建设银行储蓄卡"), .bank(mark: "建", color: 0x0066B3))
        XCTAssertEqual(brand("YEB"), .wordmark("余", color: 0xFF6A00))
        XCTAssertEqual(brand("Savings", type: "Yu'E Bao"), .wordmark("余", color: 0xFF6A00))
        XCTAssertEqual(brand("WECHAT"), .symbol("bubble.left.and.bubble.right.fill", color: 0x07C160))
        XCTAssertEqual(brand("支付宝"), .wordmark("支", color: 0x1677FF))
        XCTAssertEqual(brand("EUR CASH", currency: "EUR", cash: true), .flag("🇪🇺"))
        XCTAssertEqual(brand("THB CASH", currency: "THB", cash: true), .flag("🇹🇭"))
        XCTAssertEqual(brand("Wallet", currency: "KRW", cash: true), .flag("🇰🇷"))
        XCTAssertEqual(brand("VISA-US", currency: "USD"), .wordmark("VISA", color: 0x1A1F71))
        XCTAssertEqual(brand("T-money Card KR", currency: "KRW"), .symbol("tram.fill", color: 0x2E8BFF))
        XCTAssertEqual(brand("SiSYPHE Coffee"), .symbol("cup.and.saucer.fill", color: 0x8B5A3C))
    }

    func testNoFalseMatchesInsideWords() {
        XCTAssertNil(brand("Cabochon"))
        XCTAssertNil(brand("FYC BALANCE", currency: "USD"))
        XCTAssertNil(brand("W"))
    }
}
