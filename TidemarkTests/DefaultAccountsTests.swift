import XCTest
@testable import Tidemark

@MainActor
final class DefaultAccountsTests: XCTestCase {
    func testDefaultWinsOverLastUsedAndFallsBackWhenMissing() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: "defaultExpenseAccount")
        defer {
            if let saved { defaults.set(saved, forKey: "defaultExpenseAccount") } else { defaults.removeObject(forKey: "defaultExpenseAccount") }
        }
        let cash = Account(name: "Cash", kind: .payment)
        let card = Account(name: "Card", kind: .payment)
        DefaultAccounts.set(card.id, for: .expense)
        XCTAssertEqual(DefaultAccounts.pick(for: .expense, among: [cash, card], lastUsed: cash.id), card.id)
        XCTAssertEqual(DefaultAccounts.pick(for: .expense, among: [cash], lastUsed: nil), cash.id)
        DefaultAccounts.set(nil, for: .expense)
        XCTAssertEqual(DefaultAccounts.pick(for: .expense, among: [cash, card], lastUsed: card.id), card.id)
        XCTAssertNil(DefaultAccounts.id(for: .transfer))
    }
}
