import XCTest
@testable import Tidemark

final class EntryInputTests: XCTestCase {
    private func type(_ keys: [String]) -> String {
        var expression = ""
        for key in keys { EntryInput.press(key, on: &expression) }
        return expression
    }

    func testPrecedenceAndRounding() {
        XCTAssertEqual(EntryInput.evaluate("12+3×4"), 24)
        XCTAssertEqual(EntryInput.evaluate("10÷3"), Decimal(string: "3.33"))
        XCTAssertNil(EntryInput.evaluate("5−5"))
        XCTAssertNil(EntryInput.evaluate("5÷0"))
    }

    func testKeys() {
        XCTAssertEqual(type(["+×", "1", "2", ".", "3", "4", "5"]), "12.34")
        XCTAssertEqual(type(["5", "+×", "+×"]), "5×")
        XCTAssertEqual(type(["5", "+×", "−÷"]), "5−")
        XCTAssertEqual(type([".", "5"]), "0.5")
        XCTAssertEqual(type(["0", "7"]), "7")
        XCTAssertEqual(type(["8", "−", "⌫"]), "8")
        XCTAssertEqual(type(["8", "+", "×"]), "8×")
    }
}
