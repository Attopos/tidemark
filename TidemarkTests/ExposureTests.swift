import XCTest
@testable import Tidemark

// Risk-exposure guesses: the wrapper (CNY QDII fund, tokenized stock, coin)
// must not decide the exposure — what it tracks does.

final class ExposureTests: XCTestCase {
    private func guess(_ name: String, _ symbol: String = "", _ cls: AssetClass = .equity) -> Exposure {
        Exposure.guess(name: name, symbol: symbol, assetClass: cls)
    }

    func testGuesses() {
        XCTAssertEqual(guess("某某标普500指数(QDII)A"), .usEquity)
        XCTAssertEqual(guess("某某纳斯达克100指数(QDII)C"), .usEquity)
        XCTAssertEqual(guess("Invesco QQQ Trust, Series 1", "QQQ"), .usEquity)
        XCTAssertEqual(guess("Some S&P 500 ETF", "SPY"), .usEquity)
        XCTAssertEqual(guess("某某日经225ETF联接(QDII)A"), .intlEquity)
        XCTAssertEqual(guess("某某法国CAC40ETF联接(QDII)A"), .intlEquity)
        XCTAssertEqual(guess("某某上海金ETF联接C"), .gold, "gold feeder funds are gold, not equity")
        XCTAssertEqual(guess("某某沪深300指数A"), .chinaEquity)
        XCTAssertEqual(guess("某某蓝筹精选混合", "", .mixedFund), .chinaEquity)
        XCTAssertEqual(guess("某某纯债债券A", "", .bond), .bond)
        XCTAssertEqual(guess("某某货币A", "", .moneyMarket), .cash)
        XCTAssertEqual(guess("Bitcoin", "BTC", .crypto), .crypto)
        XCTAssertEqual(guess("USDC", "USDC", .cash), .cash)
        XCTAssertEqual(guess("某某基金", "", .other), .other, "'基金' alone is not gold")
    }
}

final class ShareBarTests: XCTestCase {
    func testBarLengthIsProportional() {
        let w: CGFloat = 80
        XCTAssertEqual(PortfolioView.barLength(share: 0.28, scale: 0.28, width: w), 80)
        XCTAssertEqual(PortfolioView.barLength(share: 0.07, scale: 0.28, width: w), 20, accuracy: 0.001)
        XCTAssertEqual(PortfolioView.barLength(share: 0.035, scale: 0.28, width: w), 10, accuracy: 0.001)
        XCTAssertEqual(PortfolioView.barLength(share: 0.002, scale: 0.28, width: w), 1, "tiny share keeps a 1pt sliver")
        XCTAssertEqual(PortfolioView.barLength(share: 0, scale: 0.28, width: w), 0)
    }
}

final class IndexIconTests: XCTestCase {
    func testIndexDetection() {
        func key(_ n: String, _ t: String = "") -> String? { AssetIconStore.indexKey(name: n, symbol: t)?.key }
        XCTAssertEqual(key("南方纳斯达克100指数(QDII)A"), "nasdaq")
        XCTAssertEqual(key("Invesco QQQ Trust, Series 1", "QQQ"), "nasdaq")
        XCTAssertEqual(key("博时标普500ETF联接(QDII)A"), "sp500")
        XCTAssertEqual(key("State Street SPDR S&P 500 ET", "SPY"), "sp500")
        XCTAssertEqual(key("华安国际龙头(DAX)ETF联接(QDII)A"), "dax")
        XCTAssertEqual(key("华安法国CAC40ETF联接(QDII)A"), "cac")
        XCTAssertEqual(key("华安三菱日联日经225ETF联接(QDII)A"), "nikkei")
        XCTAssertEqual(key("富国上海金ETF联接C"), "gold")
        XCTAssertNil(key("Bitcoin", "BTC"))
        XCTAssertNil(key("某某蓝筹精选混合"))
    }
}
