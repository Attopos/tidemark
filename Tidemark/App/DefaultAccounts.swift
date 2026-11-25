import Foundation

enum DefaultAccounts {
    static func key(_ kind: TransactionKind) -> String? {
        switch kind {
        case .expense: return "defaultExpenseAccount"
        case .income: return "defaultIncomeAccount"
        default: return nil
        }
    }

    static func id(for kind: TransactionKind) -> UUID? {
        guard let key = key(kind) else { return nil }
        return UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    static func set(_ id: UUID?, for kind: TransactionKind) {
        guard let key = key(kind) else { return }
        if let id { UserDefaults.standard.set(id.uuidString, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }

    static func pick(for kind: TransactionKind, among accounts: [Account], lastUsed: UUID?) -> UUID? {
        if let id = id(for: kind), accounts.contains(where: { $0.id == id }) { return id }
        return lastUsed ?? accounts.first?.id
    }
}
