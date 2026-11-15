import XCTest
import SwiftData
@testable import Tidemark

@MainActor
final class CurrencyConverterTests: XCTestCase {
    func testDatedRateLookup() throws {
        let day: TimeInterval = 86_400
        let rates = [CurrencyRate(code: "usd", rate: 7.2, date: Date(timeIntervalSince1970: 3 * day)),
                     CurrencyRate(code: "USD", rate: 7.0, date: Date(timeIntervalSince1970: 1 * day)),
                     CurrencyRate(code: "USD", rate: 7.1, date: Date(timeIntervalSince1970: 2 * day))]
        let converter = CurrencyConverter(rates: rates, base: "CNY")
        XCTAssertEqual(converter.rateToCNY("USD", at: Date(timeIntervalSince1970: 0)), 7.0, "before the first: earliest")
        XCTAssertEqual(converter.rateToCNY("USD", at: Date(timeIntervalSince1970: 2 * day)), 7.1, "on a rate's day")
        XCTAssertEqual(converter.rateToCNY("USD", at: Date(timeIntervalSince1970: 2.5 * day)), 7.1)
        XCTAssertEqual(converter.rateToCNY("USD", at: Date(timeIntervalSince1970: 9 * day)), 7.2, "after the last: latest")
        XCTAssertEqual(converter.toBase(10, "USD", at: Date(timeIntervalSince1970: 9 * day)), 72)
        XCTAssertEqual(converter.toBase(Decimal(string: "12.34")!, "CNY"), Decimal(string: "12.34"))
        XCTAssertEqual(converter.toBase(0, "USD"), 0)
        XCTAssertEqual(converter.toBase(5, "XYZ"), 5, "unknown codes convert 1:1")

        let usd = CurrencyConverter(rates: rates, base: "USD")
        XCTAssertEqual(usd.toBase(3, "USD"), 3)
        XCTAssertEqual(usd.toBase(72, "CNY", at: Date(timeIntervalSince1970: 9 * day)).rounded(6), 10)
    }
}
