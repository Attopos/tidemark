import Foundation
import Observation

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
    nonisolated static let didReceive = Notification.Name("CategoryStylesDidReceive")

    private(set) var catalog: CategoryCatalog

    private init() {
        catalog = Self.stored()
    }

    nonisolated static func stored() -> CategoryCatalog {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(CategoryCatalog.self, from: data) else { return CategoryCatalog() }
        return value
    }

    nonisolated static func iconKey(_ kind: TransactionKind, _ name: String) -> String {
        "\(kind.rawValue)|\(name)"
    }

    func symbol(kind: TransactionKind, name: String) -> String? {
        catalog.icons[Self.iconKey(kind, name)]
    }

    func setSymbol(_ symbol: String?, kind: TransactionKind, name: String) {
        catalog.icons[Self.iconKey(kind, name)] = symbol
        save()
    }

    func custom(kind: TransactionKind) -> [CustomCategory] {
        catalog.custom.filter { $0.kind == kind.rawValue }
    }

    func isCustom(kind: TransactionKind, name: String, parent: String) -> Bool {
        catalog.custom.contains { $0.kind == kind.rawValue && $0.name == name && $0.parent == parent }
    }

    func add(name: String, parent: String, kind: TransactionKind, symbol: String?) {
        let entry = CustomCategory(kind: kind.rawValue, name: name, parent: parent)
        if !catalog.custom.contains(entry) { catalog.custom.append(entry) }
        catalog.icons[Self.iconKey(kind, name)] = symbol
        save()
    }

    func remove(_ entry: CustomCategory) {
        catalog.custom.removeAll { $0 == entry || ($0.kind == entry.kind && $0.parent == entry.name && entry.parent.isEmpty) }
        save()
    }

    func replace(with incoming: CategoryCatalog) {
        guard incoming != catalog, incoming.updatedAt > catalog.updatedAt else { return }
        catalog = incoming
        persist(notify: false)
        NotificationCenter.default.post(name: Self.didReceive, object: nil)
    }

    private func save() {
        catalog.updatedAt = Date()
        persist(notify: true)
    }

    private func persist(notify: Bool) {
        if let data = try? JSONEncoder().encode(catalog) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        if notify { NotificationCenter.default.post(name: Self.didChange, object: nil) }
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
