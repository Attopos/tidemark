import Foundation
import Observation
import SwiftData

struct CustomCategory: Codable, Hashable, Identifiable {
    var kind: String
    var name: String
    var parent: String

    var id: String { "\(kind)|\(parent)|\(name)" }
}

struct CategoryCatalog: Codable, Equatable {
    var icons: [String: String] = [:]
    var custom: [CustomCategory] = []
    var updatedAt: Date = .distantPast
}

@MainActor
@Observable
final class CategoryStyles {
    static let shared = CategoryStyles()
    nonisolated static let storageKey = "categoryCatalog"
    nonisolated static let didChange = Notification.Name("CategoryStylesDidChange")

    private(set) var catalog: CategoryCatalog

    private init() {
        catalog = Self.stored()
    }

    nonisolated static func stored() -> CategoryCatalog {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(CategoryCatalog.self, from: data) else { return CategoryCatalog() }
        return value
    }

    func isCustom(kind: TransactionKind, name: String, parent: String) -> Bool {
        catalog.custom.contains { $0.kind == kind.rawValue && $0.name == name && $0.parent == parent }
    }

    func add(name: String, parent: String, kind: TransactionKind) {
        let entry = CustomCategory(kind: kind.rawValue, name: name, parent: parent)
        if !catalog.custom.contains(entry) { catalog.custom.append(entry) }
        save()
    }

    func remove(_ entry: CustomCategory) {
        catalog.custom.removeAll { $0 == entry || ($0.kind == entry.kind && $0.parent == entry.name && entry.parent.isEmpty) }
        save()
    }

    func rename(kind: TransactionKind, name: String, parent: String, to newName: String) {
        for index in catalog.custom.indices where catalog.custom[index].kind == kind.rawValue {
            if catalog.custom[index].name == name && catalog.custom[index].parent == parent {
                catalog.custom[index].name = newName
            }
            if parent.isEmpty && catalog.custom[index].parent == name {
                catalog.custom[index].parent = newName
            }
        }
        var seen = Set<CustomCategory>()
        catalog.custom = catalog.custom.filter { seen.insert($0).inserted }
        save()
    }

    func reload() {
        catalog = Self.stored()
    }

    private func save() {
        catalog.updatedAt = Date()
        if let data = try? JSONEncoder().encode(catalog) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

enum CategorySymbolMigration {
    static let doneKey = "categorySymbolsEmbedded.v2"

    @MainActor
    static func runIfNeeded(_ context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: doneKey), !TidemarkSchema.isTesting else { return }
        do {
            let backup = try BackupService.makeBackup(from: context, settings: BackupFile.Settings())
            if !(backup.transactions ?? []).isEmpty {
                _ = try BackupService.writeBackup(backup, to: BackupService.automaticFolder)
            }
            try run(context, legacy: CategoryStyles.stored().icons)
            var catalog = CategoryStyles.stored()
            catalog.icons = [:]
            catalog.custom = catalog.custom.map { entry in
                var copy = entry
                let kind = TransactionKind(rawValue: entry.kind) ?? .expense
                copy.name = embed(entry.name, kind: kind, legacy: CategoryStyles.stored().icons)
                if !entry.parent.isEmpty { copy.parent = embed(entry.parent, kind: kind, legacy: CategoryStyles.stored().icons) }
                return copy
            }
            UserDefaults.standard.set(try JSONEncoder().encode(catalog), forKey: CategoryStyles.storageKey)
            CategoryStyles.shared.reload()
            UserDefaults.standard.set(true, forKey: doneKey)
        } catch {
            UserDefaults.standard.set(false, forKey: doneKey)
        }
    }

    static func embed(_ name: String, kind: TransactionKind, legacy: [String: String]) -> String {
        guard !name.isEmpty, CategoryName.symbol(name) == nil else { return name }
        let symbol = legacy["\(kind.rawValue)|\(name)"] ?? CategoryName.automaticSymbol(for: name)
        return CategoryName.compose(symbol: symbol, rest: name)
    }

    @MainActor
    static func run(_ context: ModelContext, legacy: [String: String]) throws {
        let flows: [String] = [TransactionKind.expense.rawValue, TransactionKind.income.rawValue]
        let records = try context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { flows.contains($0.kindRaw) }))
        for record in records {
            let category = embed(record.category, kind: record.kind, legacy: legacy)
            let subcategory = embed(record.subcategory, kind: record.kind, legacy: legacy)
            if record.category != category { record.category = category }
            if record.subcategory != subcategory { record.subcategory = subcategory }
        }
        let presets = try context.fetch(FetchDescriptor<RecordPreset>(predicate: #Predicate { flows.contains($0.kindRaw) }))
        for preset in presets {
            let category = embed(preset.category, kind: preset.kind, legacy: legacy)
            let subcategory = embed(preset.subcategory, kind: preset.kind, legacy: legacy)
            if preset.category != category { preset.category = category }
            if preset.subcategory != subcategory { preset.subcategory = subcategory }
        }
        for commitment in try context.fetch(FetchDescriptor<RecurringCommitment>()) {
            let category = embed(commitment.category, kind: .expense, legacy: legacy)
            if commitment.category != category { commitment.category = category }
        }
        if context.hasChanges { try context.save() }
    }
}

struct CategoryIconGroup: Decodable, Identifiable {
    let key: String
    let title: String
    let icon: String
    let symbols: [String]

    var id: String { key }
}

enum CategoryIconLibrary {
    private struct File: Decodable {
        let groups: [CategoryIconGroup]
        let keywords: [String: [String]]
    }

    private static let file: File = {
        guard let url = Bundle.main.url(forResource: "category-icons", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(File.self, from: data) else { return File(groups: [], keywords: [:]) }
        return value
    }()

    static var groups: [CategoryIconGroup] { file.groups }

    private static let all: [String] = {
        var seen = Set<String>()
        return file.groups.flatMap(\.symbols).filter { seen.insert($0).inserted }
    }()

    static var count: Int { all.count }

    private static let chinese: [String: String] = [
        "吃": "fork", "餐": "fork", "饭": "fork", "咖啡": "cup", "茶": "cup", "酒": "wineglass", "水果": "carrot",
        "菜": "carrot", "面包": "bag", "蛋糕": "cake", "甜": "cake", "零食": "popcorn", "购物": "cart", "超市": "cart",
        "包": "bag", "衣": "tshirt", "鞋": "shoe", "车": "car", "地铁": "tram", "火车": "train", "公交": "bus",
        "飞机": "airplane", "船": "ferry", "自行车": "bicycle", "油": "fuelpump", "停车": "parking", "房": "house",
        "家": "house", "电": "bolt", "水": "drop", "网": "wifi", "手机": "iphone", "电脑": "laptop", "电视": "tv",
        "游戏": "gamecontroller", "电影": "film", "音乐": "music", "书": "book", "学": "graduationcap", "工作": "briefcase",
        "医": "cross", "药": "pills", "健康": "heart", "运动": "figure", "健身": "dumbbell", "宠物": "pawprint",
        "猫": "cat", "狗": "dog", "礼物": "gift", "红包": "gift", "钱": "banknote", "工资": "banknote", "卡": "creditcard",
        "投资": "chart", "保险": "shield", "旅": "suitcase", "酒店": "bed", "美": "sparkles", "理发": "scissors",
        "孩子": "figure.and.child", "婴儿": "stroller", "花": "camera.macro", "树": "tree", "天气": "cloud",
        "照片": "camera", "社交": "person.2", "朋友": "person.2", "时间": "clock", "订阅": "repeat", "会员": "star",
    ]

    static func search(_ query: String) -> [String] {
        var text = query.lowercased()
        for (zh, en) in chinese.sorted(by: { $0.key.count > $1.key.count }) where text.contains(zh) { text = text.replacingOccurrences(of: zh, with: " \(en) ") }
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return all.filter { symbol in
            let haystack = ([symbol] + (file.keywords[symbol] ?? [])).joined(separator: " ")
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}

enum CategoryRenamer {
    @MainActor
    static func rename(kind: TransactionKind, name: String, parent: String, to newName: String,
                       in context: ModelContext) throws -> Int {
        guard newName != name, !newName.isEmpty else { return 0 }
        let changed = try renameRecords(kind: kind, name: name, parent: parent, to: newName, in: context)
        CategoryStyles.shared.rename(kind: kind, name: name, parent: parent, to: newName)
        return changed
    }

    @MainActor
    static func renameRecords(kind: TransactionKind, name: String, parent: String, to newName: String,
                              in context: ModelContext) throws -> Int {
        let kindRaw = kind.rawValue
        var changed = 0
        if parent.isEmpty {
            let records = try context.fetch(FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.kindRaw == kindRaw && $0.category == name }))
            for record in records { record.category = newName; changed += 1 }
            let presets = try context.fetch(FetchDescriptor<RecordPreset>(
                predicate: #Predicate { $0.kindRaw == kindRaw && $0.category == name }))
            for preset in presets { preset.category = newName }
            if kind == .expense {
                let commitments = try context.fetch(FetchDescriptor<RecurringCommitment>(
                    predicate: #Predicate { $0.category == name }))
                for commitment in commitments { commitment.category = newName }
            }
        } else {
            let records = try context.fetch(FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.kindRaw == kindRaw && $0.category == parent && $0.subcategory == name }))
            for record in records { record.subcategory = newName; changed += 1 }
            let presets = try context.fetch(FetchDescriptor<RecordPreset>(
                predicate: #Predicate { $0.kindRaw == kindRaw && $0.category == parent && $0.subcategory == name }))
            for preset in presets { preset.subcategory = newName }
        }
        try context.save()
        return changed
    }

    static func fullName(replacingLabelOf name: String, with label: String, symbol: String?) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = CategoryName.split(name).emoji.map { "\($0) \(trimmed)" } ?? trimmed
        return CategoryName.compose(symbol: symbol, rest: rest)
    }
}
