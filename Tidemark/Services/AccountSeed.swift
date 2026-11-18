#if DEBUG
import Foundation
import SwiftData

enum AccountSeed {
    struct Entry: Decodable {
        var balance: Decimal?
        var currency: String?
        var typeLabel: String?
        var cardNumber: String?
        var note: String?
        var group: String?
        var archived: Bool?
        var kind: String?
    }

    @MainActor
    static func applyFromEnvironment(_ context: ModelContext) {
        guard let json = ProcessInfo.processInfo.environment["TIDEMARK_ACCOUNT_SEED"],
              let entries = try? JSONDecoder().decode([String: Entry].self, from: Data(json.utf8)) else { return }
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let records = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let rates = (try? context.fetch(FetchDescriptor<CurrencyRate>())) ?? []
        let converter = CurrencyConverter(rates: rates, base: "CNY")
        var log: [String] = []
        for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
            let account = accounts.first { $0.name == name } ?? {
                let created = Account(name: name, kind: .cash, currencyCode: entry.currency ?? "CNY", source: .icost)
                context.insert(created)
                return created
            }()
            if let kind = entry.kind { account.kindRaw = kind }
            if let currency = entry.currency { account.currencyCode = currency }
            if let typeLabel = entry.typeLabel { account.typeLabel = typeLabel }
            if let cardNumber = entry.cardNumber { account.cardNumber = cardNumber }
            if let note = entry.note { account.note = note }
            if let group = entry.group { account.groupRaw = group }
            if let archived = entry.archived { account.isArchived = archived }
            if let balance = entry.balance {
                let imported = records.filter { $0.source == .icost }
                    .flatMap { $0.movements(using: converter) }
                    .filter { $0.account == account.id }
                    .reduce(Decimal(0)) { $0 + $1.delta }
                account.openingBalance = (balance - imported).rounded(2)
                log.append("\(name): imported \(imported) → opening \(account.openingBalance)")
            }
            account.updatedAt = Date()
        }
        try? context.save()
        let url = URL.applicationSupportDirectory.appending(path: "account-seed.log")
        try? log.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
