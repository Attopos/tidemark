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
        var catalog = CategoryCatalog()
        catalog.custom = [CustomCategory(kind: "expense", name: "Pets zz", parent: ""),
                          CustomCategory(kind: "expense", name: "Vet zz", parent: "Pets zz")]
        catalog.icons[CategoryStyles.iconKey(.expense, "Vet zz")] = "cross.case"
        defaults.set(try JSONEncoder().encode(catalog), forKey: CategoryStyles.storageKey)

        XCTAssertEqual(CategoryStyles.stored().icons["expense|Vet zz"], "cross.case")
        let container = try TidemarkSchema.makeContainer(inMemory: true)
        let stats = EntryStats.load(container.mainContext)
        XCTAssertTrue(stats.categories[.expense]?.contains("Pets zz") ?? false)
        XCTAssertEqual(stats.subcategories[.expense]?["Pets zz"], ["Vet zz"])
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
        XCTAssertEqual(CategoryRenamer.fullName(replacingLabelOf: "🍔 Food", with: "Eating"), "🍔 Eating")
    }
}
