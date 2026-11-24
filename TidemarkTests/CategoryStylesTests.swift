import XCTest
import SwiftData
@testable import Tidemark

@MainActor
final class CategoryStylesTests: XCTestCase {
    func testLibraryLoadsGroupsAndSearches() {
        XCTAssertGreaterThan(CategoryIconLibrary.count, 1000)
        XCTAssertEqual(CategoryIconLibrary.groups.first?.key, "common")
        XCTAssertTrue(CategoryIconLibrary.search("咖啡").contains("cup.and.saucer"))
        XCTAssertTrue(CategoryIconLibrary.search("bicycle").contains("bicycle"))
        let results = CategoryIconLibrary.search("cart")
        XCTAssertEqual(results.count, Set(results).count)
    }

    func testCustomCategoriesReachEntryStats() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: CategoryStyles.storageKey)
        defer {
            if let saved { defaults.set(saved, forKey: CategoryStyles.storageKey) } else { defaults.removeObject(forKey: CategoryStyles.storageKey) }
        }
        let pets = CategoryName.compose(symbol: "pawprint", rest: "Pets zz")
        var catalog = CategoryCatalog()
        catalog.custom = [CustomCategory(kind: "expense", name: pets, parent: ""),
                          CustomCategory(kind: "expense", name: "Vet zz", parent: pets)]
        defaults.set(try JSONEncoder().encode(catalog), forKey: CategoryStyles.storageKey)

        let container = try TidemarkSchema.makeContainer(inMemory: true)
        let stats = EntryStats.load(container.mainContext)
        XCTAssertTrue(stats.categories[.expense]?.contains(pets) ?? false)
        XCTAssertEqual(stats.subcategories[.expense]?[pets], ["Vet zz"])
    }

    func testSymbolLivesInsideTheName() {
        let name = CategoryName.compose(symbol: "cart", rest: "🛒 Groceries")
        XCTAssertEqual(CategoryName.symbol(name), "cart")
        XCTAssertEqual(CategoryName.label(name), "Groceries")
        XCTAssertEqual(CategoryName.withoutSymbol(name), "🛒 Groceries")
        XCTAssertEqual(CategoryName.displaySymbol(for: name), "cart")
        XCTAssertEqual(CategoryName.displaySymbol(for: "Coffee"), "cup.and.saucer")
        XCTAssertEqual(CategoryName.compose(symbol: "bag", rest: name), "\u{E000}bag\u{E001}🛒 Groceries")
        XCTAssertEqual(CategoryName.resolve("Groceries", among: ["Food", name]), name)
        XCTAssertEqual(CategoryName.resolve("New", among: [name]), "New")
        XCTAssertNil(CategoryName.glyph(for: CategoryName.compose(symbol: "cart", rest: "Zzz")))
    }

    func testMigrationEmbedsAutomaticAndChosenIcons() throws {
        let container = try TidemarkSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        let account = Account(name: "Cash", kind: .payment)
        context.insert(account)
        let meal = Transaction(date: Date(), kind: .expense, amount: 5, category: "Food", subcategory: "Meal", account: account)
        let odd = Transaction(date: Date(), kind: .expense, amount: 5, category: "Qwerty", account: account)
        let chosen = Transaction(date: Date(), kind: .income, amount: 9, category: "Side", account: account)
        let move = Transaction(date: Date(), kind: .transfer, amount: 1, category: "Transfer", account: account)
        [meal, odd, chosen, move].forEach(context.insert)
        try context.save()

        try CategorySymbolMigration.run(context, legacy: ["income|Side": "star"])
        XCTAssertEqual(CategoryName.symbol(meal.category), "fork.knife")
        XCTAssertEqual(CategoryName.label(meal.category), "Food")
        XCTAssertEqual(CategoryName.symbol(meal.subcategory), "fork.knife")
        XCTAssertEqual(odd.category, "Qwerty")
        XCTAssertEqual(chosen.category, CategoryName.compose(symbol: "star", rest: "Side"))
        XCTAssertEqual(move.category, "Transfer")

        let before = meal.category
        try CategorySymbolMigration.run(context, legacy: [:])
        XCTAssertEqual(meal.category, before)
    }

    func testRenameUpdatesRecordsAndPresets() throws {
        let container = try TidemarkSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        let account = Account(name: "Cash", kind: .payment)
        context.insert(account)
        context.insert(Transaction(date: Date(), kind: .expense, amount: 5, category: "Food", subcategory: "Meal", account: account))
        context.insert(Transaction(date: Date(), kind: .expense, amount: 6, category: "Food", subcategory: "Fruit", account: account))
        context.insert(Transaction(date: Date(), kind: .income, amount: 7, category: "Food", account: account))
        let preset = RecordPreset(name: "Lunch", kind: .expense, amount: 5)
        preset.category = "Food"; preset.subcategory = "Meal"
        context.insert(preset)
        try context.save()

        XCTAssertEqual(try CategoryRenamer.renameRecords(kind: .expense, name: "Meal", parent: "Food", to: "Dinner", in: context), 1)
        XCTAssertEqual(try CategoryRenamer.renameRecords(kind: .expense, name: "Food", parent: "", to: "Eating", in: context), 2)
        let records = try context.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(Set(records.filter { $0.kind == .expense }.map { "\($0.category)/\($0.subcategory)" }), ["Eating/Dinner", "Eating/Fruit"])
        XCTAssertEqual(records.first { $0.kind == .income }?.category, "Food")
        XCTAssertEqual(preset.category, "Eating")
        XCTAssertEqual(preset.subcategory, "Dinner")
        XCTAssertEqual(CategoryRenamer.fullName(replacingLabelOf: "🍔 Food", with: "Eating", symbol: nil), "🍔 Eating")
        XCTAssertEqual(CategoryName.symbol(CategoryRenamer.fullName(replacingLabelOf: "Food", with: "Eating", symbol: "cart")), "cart")
    }
}
