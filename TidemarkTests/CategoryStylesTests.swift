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
}
