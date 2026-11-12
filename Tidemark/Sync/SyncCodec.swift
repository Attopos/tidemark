import Foundation
import SwiftData
import CryptoKit

// MARK: - Sync codec
//
// What travels between devices: each account and each ledger record as a flat
// dictionary of strings (amounts as decimal strings, dates as seconds since
// 1970, references as ids). The same dictionary is the record's content on
// the server and the input of the digest that tells whether a local row has
// changed since it was last sent. `updatedAt` travels but is left out of the
// digest: it says when a row changed, not what it holds.

enum SyncKind: String {
    case account = "A"
    case transaction = "T"
    case preset = "P"

    var recordType: String {
        switch self {
        case .account: return "Account"
        case .transaction: return "LedgerRecord"
        case .preset: return "Preset"
        }
    }
}

/// "A:<uuid>" or "T:<uuid>" — also the record name on the server.
struct SyncKey: Hashable {
    let kind: SyncKind
    let id: UUID

    var name: String { "\(kind.rawValue):\(id.uuidString)" }

    init(_ kind: SyncKind, _ id: UUID) {
        self.kind = kind
        self.id = id
    }

    init?(name: String) {
        let parts = name.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let kind = SyncKind(rawValue: String(parts[0])),
              let id = UUID(uuidString: String(parts[1])) else { return nil }
        self.kind = kind
        self.id = id
    }
}

typealias SyncFields = [String: String]

enum SyncCodec {
    private static let posix = Locale(identifier: "en_US_POSIX")

    static func string(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).description(withLocale: posix) }
    static func decimal(_ text: String?) -> Decimal { text.flatMap { Decimal(string: $0, locale: posix) } ?? 0 }
    static func string(_ date: Date) -> String { String(format: "%.3f", date.timeIntervalSince1970) }
    static func date(_ text: String?) -> Date? { text.flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) }
    static func string(_ flag: Bool) -> String { flag ? "1" : "0" }

    // MARK: Account

    static func fields(of account: Account) -> SyncFields {
        ["name": account.name,
         "kind": account.kindRaw,
         "currency": account.currencyCode,
         "opening": string(account.openingBalance),
         "counted": string(account.includeInNetWorth),
         "source": account.sourceRaw,
         "note": account.note,
         "archived": string(account.isArchived),
         "createdAt": string(account.createdAt),
         "updatedAt": string(account.updatedAt)]
    }

    static func apply(_ fields: SyncFields, to account: Account) {
        account.name = fields["name"] ?? account.name
        account.kindRaw = fields["kind"] ?? account.kindRaw
        account.currencyCode = fields["currency"] ?? account.currencyCode
        account.openingBalance = decimal(fields["opening"])
        account.includeInNetWorth = fields["counted"] != "0"
        account.sourceRaw = fields["source"] ?? account.sourceRaw
        account.note = fields["note"] ?? ""
        account.isArchived = fields["archived"] == "1"
        account.createdAt = date(fields["createdAt"]) ?? account.createdAt
        account.updatedAt = date(fields["updatedAt"]) ?? account.updatedAt
    }

    // MARK: Ledger record

    static func fields(of transaction: Transaction) -> SyncFields {
        var fields: SyncFields = [
            "date": string(transaction.date),
            "kind": transaction.kindRaw,
            "amount": string(transaction.amount),
            "currency": transaction.currencyCode,
            "category": transaction.category,
            "subcategory": transaction.subcategory,
            "merchant": transaction.merchant,
            "note": transaction.note,
            "tags": transaction.tags,
            "address": transaction.address,
            "refund": string(transaction.refundAmount),
            "claimStatus": transaction.claimStatusRaw,
            "claimAmount": string(transaction.claimAmount),
            "discount": string(transaction.discountAmount),
            "fee": string(transaction.feeAmount),
            "source": transaction.sourceRaw,
            "fingerprint": transaction.fingerprint,
            "excluded": string(transaction.excludeFromStats),
            "createdAt": string(transaction.createdAt),
            "updatedAt": string(transaction.updatedAt),
        ]
        if let account = transaction.account { fields["account"] = account.id.uuidString }
        if let destination = transaction.transferAccount { fields["transferAccount"] = destination.id.uuidString }
        if let arrival = transaction.transferAmount { fields["transferAmount"] = string(arrival) }
        if let external = transaction.externalID { fields["externalID"] = external }
        if let raw = transaction.rawPayload { fields["rawPayload"] = raw }
        if let preset = transaction.presetID { fields["preset"] = preset.uuidString }
        return fields
    }

    /// Returns false when the record names an account that is not here yet;
    /// everything else is still applied, and the caller retries later.
    @discardableResult
    static func apply(_ fields: SyncFields, to transaction: Transaction, accounts: [UUID: Account]) -> Bool {
        transaction.date = date(fields["date"]) ?? transaction.date
        transaction.kindRaw = fields["kind"] ?? transaction.kindRaw
        transaction.amount = decimal(fields["amount"])
        transaction.currencyCode = fields["currency"] ?? transaction.currencyCode
        transaction.category = fields["category"] ?? ""
        transaction.subcategory = fields["subcategory"] ?? ""
        transaction.merchant = fields["merchant"] ?? ""
        transaction.note = fields["note"] ?? ""
        transaction.tags = fields["tags"] ?? ""
        transaction.address = fields["address"] ?? ""
        transaction.refundAmount = decimal(fields["refund"])
        transaction.claimStatusRaw = fields["claimStatus"] ?? ""
        transaction.claimAmount = decimal(fields["claimAmount"])
        transaction.presetID = fields["preset"].flatMap(UUID.init(uuidString:))
        transaction.discountAmount = decimal(fields["discount"])
        transaction.feeAmount = decimal(fields["fee"])
        transaction.sourceRaw = fields["source"] ?? transaction.sourceRaw
        transaction.excludeFromStats = fields["excluded"] == "1"
        transaction.createdAt = date(fields["createdAt"]) ?? transaction.createdAt
        transaction.updatedAt = date(fields["updatedAt"]) ?? transaction.updatedAt
        transaction.transferAmount = fields["transferAmount"].map { decimal($0) }
        transaction.externalID = fields["externalID"]
        transaction.rawPayload = fields["rawPayload"]

        var complete = true
        func resolve(_ key: String) -> Account? {
            guard let text = fields[key], let id = UUID(uuidString: text) else { return nil }
            if let account = accounts[id] { return account }
            complete = false
            return nil
        }
        transaction.account = resolve("account")
        transaction.transferAccount = resolve("transferAccount")
        return complete
    }

    // MARK: Preset

    static func fields(of preset: RecordPreset) -> SyncFields {
        var fields: SyncFields = [
            "name": preset.name,
            "kind": preset.kindRaw,
            "amount": string(preset.amount),
            "currency": preset.currencyCode,
            "category": preset.category,
            "subcategory": preset.subcategory,
            "note": preset.note,
            "tags": preset.tags,
            "schedule": preset.scheduleRaw,
            "start": string(preset.startDate),
            "through": String(preset.generatedThrough),
            "active": string(preset.isActive),
            "createdAt": string(preset.createdAt),
            "updatedAt": string(preset.updatedAt),
        ]
        if let id = preset.accountID { fields["account"] = id.uuidString }
        if let id = preset.transferAccountID { fields["transferAccount"] = id.uuidString }
        if let end = preset.endDate { fields["end"] = string(end) }
        if let limit = preset.occurrenceLimit { fields["limit"] = String(limit) }
        return fields
    }

    static func apply(_ fields: SyncFields, to preset: RecordPreset) {
        preset.name = fields["name"] ?? preset.name
        preset.kindRaw = fields["kind"] ?? preset.kindRaw
        preset.amount = decimal(fields["amount"])
        preset.currencyCode = fields["currency"] ?? preset.currencyCode
        preset.category = fields["category"] ?? ""
        preset.subcategory = fields["subcategory"] ?? ""
        preset.note = fields["note"] ?? ""
        preset.tags = fields["tags"] ?? ""
        preset.scheduleRaw = fields["schedule"] ?? ""
        preset.startDate = date(fields["start"]) ?? preset.startDate
        // Never go back: an occurrence written on either device stays written.
        preset.generatedThrough = max(preset.generatedThrough, Int(fields["through"] ?? "") ?? -1)
        preset.isActive = fields["active"] != "0"
        preset.createdAt = date(fields["createdAt"]) ?? preset.createdAt
        preset.updatedAt = date(fields["updatedAt"]) ?? preset.updatedAt
        preset.accountID = fields["account"].flatMap(UUID.init(uuidString:))
        preset.transferAccountID = fields["transferAccount"].flatMap(UUID.init(uuidString:))
        preset.endDate = date(fields["end"])
        preset.occurrenceLimit = fields["limit"].flatMap { Int($0) }
    }

    // MARK: Digest

    static func digest(_ fields: SyncFields) -> String {
        var hasher = SHA256()
        for key in fields.keys.sorted() where key != "updatedAt" {
            hasher.update(data: Data(key.utf8))
            hasher.update(data: Data([0x1F]))
            hasher.update(data: Data((fields[key] ?? "").utf8))
            hasher.update(data: Data([0x1E]))
        }
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Change detection
//
// The store is compared with what the server is known to hold. This does not
// depend on every code path remembering to flag its edits: an import, a
// restore or an editor all end up as "the digest differs".

struct SyncEntry: Codable, Equatable {
    /// Digest of the content the server holds.
    var digest: String
    /// Server bookkeeping of the record (its change tag), archived.
    var system: Data?
}

struct SyncPlan: Equatable {
    var saves: [String] = []
    var deletes: [String] = []
    /// A deletion sweep this large looks like a lost store, not a clean-up.
    var refusedDeletes = false
}

enum SyncPlanner {
    /// - Parameters:
    ///   - local: digest of every row in the store, by record name.
    ///   - synced: what the server is known to hold.
    ///   - queued: digests already handed to the engine and not yet confirmed.
    static func plan(local: [String: String], synced: [String: SyncEntry], queued: [String: String]) -> SyncPlan {
        var plan = SyncPlan()
        for (name, digest) in local where synced[name]?.digest != digest && queued[name] != digest {
            plan.saves.append(name)
        }
        let missing = synced.keys.filter { local[$0] == nil }
        if missing.count > 20 && missing.count * 2 > synced.count {
            plan.refusedDeletes = true
        } else {
            plan.deletes = missing
        }
        plan.saves.sort()
        plan.deletes.sort()
        return plan
    }

    /// Two rows that are the same thing under different ids (the same export
    /// imported on two devices): every device keeps the smaller id, so they
    /// converge without talking to each other.
    static func survivor(_ a: UUID, _ b: UUID) -> UUID {
        a.uuidString < b.uuidString ? a : b
    }
}
