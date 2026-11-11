import Foundation
import SwiftData
import CryptoKit

// MARK: - Bookkeeping export importer
//
// Reads the spreadsheet a bookkeeping app exports (one row per record:
// date, type, amount, two category levels, source and destination account,
// remark, currency, tag, ledger, address, refund, discount, fee) and writes
// it into the ledger. Columns are found by header name, so their order and
// any extra columns do not matter.
//
// Rules:
//  * Amounts are stored as positive magnitudes in the row's own currency;
//    the direction comes from the type.
//  * Every type that is not income or expense moves money between two
//    accounts and stays out of income/expense statistics. Its original type
//    name is kept as the category ("Transfer", "Repayment", "Lend"…).
//  * Accounts are matched by name and created when missing.
//  * Each row gets a fingerprint of its content, so importing the same file
//    again (or a longer export later) adds only what is new.
//  * The original row is kept verbatim in `rawPayload`.

struct LedgerExportRow: Equatable {
    var date: Date
    var type: LedgerExportType
    /// Original type text, kept as the category of transfer-like rows.
    var typeLabel: String
    var amount: Decimal
    var category: String
    var subcategory: String
    var account: String
    var transferAccount: String
    var remark: String
    var currency: String
    var tags: String
    var ledger: String
    var address: String
    var refund: Decimal
    var discount: Decimal
    var fee: Decimal
    /// Header → cell, for `rawPayload`.
    var raw: [String: String]
}

enum LedgerExportType: Equatable {
    case expense, income, transfer, repayment

    var kind: TransactionKind {
        switch self {
        case .expense: return .expense
        case .income: return .income
        case .transfer: return .transfer
        case .repayment: return .liabilityPayment
        }
    }

    static func parse(_ text: String) -> LedgerExportType? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "expense", "支出": return .expense
        case "income", "收入": return .income
        case "repayment", "还款": return .repayment
        case "transfer", "转账", "lend", "借出", "borrow", "借入", "collect", "收款", "收债",
             "recharge", "充值": return .transfer
        default: return nil
        }
    }
}

enum LedgerExportError: LocalizedError {
    case missingColumns([String])
    case empty

    var errorDescription: String? {
        switch self {
        case .missingColumns(let names):
            return "This does not look like a bookkeeping export: no \(names.joined(separator: ", ")) column."
        case .empty:
            return "The export has no records."
        }
    }
}

enum LedgerExportImporter {
    struct Parsed {
        var rows: [LedgerExportRow] = []
        /// 1-based sheet rows that could not be read, with the reason.
        var rejected: [(line: Int, reason: String)] = []
    }

    struct Stats: Equatable {
        var inserted = 0
        var skipped = 0
        var rejected = 0
        var accountsCreated = 0
    }

    private enum Column: CaseIterable {
        case date, type, amount, category, subcategory, account, transferAccount, remark,
             currency, tags, ledger, address, refund, discount, fee

        var aliases: [String] {
            switch self {
            case .date: return ["date", "日期", "时间"]
            case .type: return ["type", "类型"]
            case .amount: return ["amount", "金额"]
            case .category: return ["first-level category", "一级分类", "category", "分类"]
            case .subcategory: return ["second-level category", "二级分类"]
            case .account: return ["account 1", "账户1", "账户 1", "account"]
            case .transferAccount: return ["account 2", "账户2", "账户 2"]
            case .remark: return ["remark", "备注"]
            case .currency: return ["currency", "货币", "币种"]
            case .tags: return ["tag", "tags", "标签"]
            case .ledger: return ["ledger", "账本"]
            case .address: return ["address", "地址", "位置"]
            case .refund: return ["refund", "退款"]
            case .discount: return ["discount", "优惠"]
            case .fee: return ["fee", "手续费"]
            }
        }

        var isRequired: Bool { self == .date || self == .type || self == .amount }
    }

    private static let dateFormats = ["yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm",
                                      "yyyy-MM-dd HH:mm", "yyyy/MM/dd", "yyyy-MM-dd"]

    private static func makeDateParsers(timeZone: TimeZone) -> [DateFormatter] {
        dateFormats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            return formatter
        }
    }

    private static func decimal(_ text: String) -> Decimal? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        if cleaned.isEmpty { return 0 }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: Sheet rows → records

    static func parse(rows sheet: [[String]], timeZone: TimeZone = .current) throws -> Parsed {
        guard let header = sheet.first else { throw LedgerExportError.empty }
        let names = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var index: [Column: Int] = [:]
        for column in Column.allCases {
            if let found = column.aliases.lazy.compactMap({ names.firstIndex(of: $0) }).first {
                index[column] = found
            }
        }
        let missing = Column.allCases.filter { $0.isRequired && index[$0] == nil }
        guard missing.isEmpty else {
            throw LedgerExportError.missingColumns(missing.map { $0.aliases[0] })
        }

        let parsers = makeDateParsers(timeZone: timeZone)
        var parsed = Parsed()
        for (offset, cells) in sheet.enumerated().dropFirst() {
            if cells.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            func cell(_ column: Column) -> String {
                guard let i = index[column], i < cells.count else { return "" }
                return cells[i]
            }
            let line = offset + 1
            let dateText = cell(.date).trimmingCharacters(in: .whitespaces)
            guard let date = parsers.lazy.compactMap({ $0.date(from: dateText) }).first else {
                parsed.rejected.append((line, "unreadable date “\(dateText)”"))
                continue
            }
            let typeText = cell(.type).trimmingCharacters(in: .whitespaces)
            guard let type = LedgerExportType.parse(typeText) else {
                parsed.rejected.append((line, "unknown type “\(typeText)”"))
                continue
            }
            guard let amount = decimal(cell(.amount)),
                  let refund = decimal(cell(.refund)),
                  let discount = decimal(cell(.discount)),
                  let fee = decimal(cell(.fee)) else {
                parsed.rejected.append((line, "unreadable amount"))
                continue
            }
            var raw: [String: String] = [:]
            for (i, name) in header.enumerated() where i < cells.count && !cells[i].isEmpty {
                raw[name] = cells[i]
            }
            let currency = cell(.currency).trimmingCharacters(in: .whitespaces).uppercased()
            parsed.rows.append(LedgerExportRow(
                date: date, type: type, typeLabel: typeText,
                amount: abs(amount),
                category: cell(.category).trimmingCharacters(in: .whitespaces),
                subcategory: cell(.subcategory).trimmingCharacters(in: .whitespaces),
                account: cell(.account).trimmingCharacters(in: .whitespaces),
                transferAccount: cell(.transferAccount).trimmingCharacters(in: .whitespaces),
                remark: cell(.remark),
                currency: currency.isEmpty ? "CNY" : currency,
                tags: cell(.tags).trimmingCharacters(in: .whitespaces),
                ledger: cell(.ledger).trimmingCharacters(in: .whitespaces),
                address: cell(.address).trimmingCharacters(in: .whitespaces),
                refund: abs(refund), discount: abs(discount), fee: abs(fee),
                raw: raw))
        }
        guard !parsed.rows.isEmpty || !parsed.rejected.isEmpty else { throw LedgerExportError.empty }
        return parsed
    }

    // MARK: Fingerprints

    /// Content hash per row; identical rows get "#2", "#3"… so two real
    /// purchases with the same second, amount and remark both survive.
    static func fingerprints(for rows: [LedgerExportRow]) -> [String] {
        var seen: [String: Int] = [:]
        return rows.map { row in
            let key = [String(Int(row.date.timeIntervalSince1970)), row.typeLabel,
                       "\(row.amount)", row.category, row.subcategory, row.account,
                       row.transferAccount, row.remark, row.currency].joined(separator: "\u{1F}")
            let digest = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            let occurrence = (seen[digest] ?? 0) + 1
            seen[digest] = occurrence
            return occurrence == 1 ? "ledger:\(digest)" : "ledger:\(digest)#\(occurrence)"
        }
    }

    // MARK: Records → store

    @MainActor
    @discardableResult
    static func commit(_ parsed: Parsed, fileName: String?, into context: ModelContext) throws -> Stats {
        var stats = Stats(rejected: parsed.rejected.count)
        let rows = parsed.rows

        var accounts: [String: Account] = [:]
        for account in try context.fetch(FetchDescriptor<Account>()) where accounts[account.name] == nil {
            accounts[account.name] = account
        }
        // An account's currency is the one most of its own records use.
        var currencyVotes: [String: [String: Int]] = [:]
        var receivables: Set<String> = []
        for row in rows {
            if row.type == .expense || row.type == .income, !row.account.isEmpty {
                currencyVotes[row.account, default: [:]][row.currency, default: 0] += 1
            }
            let label = row.typeLabel.lowercased()
            if ["lend", "借出"].contains(label), !row.transferAccount.isEmpty { receivables.insert(row.transferAccount) }
        }
        func account(named name: String, fallbackCurrency: String) -> Account? {
            guard !name.isEmpty else { return nil }
            if let existing = accounts[name] { return existing }
            let currency = currencyVotes[name]?.max { $0.value < $1.value }?.key ?? fallbackCurrency
            let kind: AccountKind = receivables.contains(name) ? .other : AccountKind.guess(fromName: name)
            let created = Account(name: name, kind: kind, currencyCode: currency, source: .icost)
            context.insert(created)
            accounts[name] = created
            stats.accountsCreated += 1
            return created
        }

        var existing = Set(try context.fetch(FetchDescriptor<Transaction>()).map(\.fingerprint))
        let record = ImportRecord(source: .icost, fileName: fileName)
        context.insert(record)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for (row, fingerprint) in zip(rows, fingerprints(for: rows)) {
            if existing.contains(fingerprint) {
                stats.skipped += 1
                continue
            }
            existing.insert(fingerprint)
            let isFlow = row.type == .expense || row.type == .income
            let transaction = Transaction(
                date: row.date,
                kind: row.type.kind,
                amount: row.amount,
                currencyCode: row.currency,
                category: isFlow ? row.category : row.typeLabel,
                subcategory: isFlow ? row.subcategory : "",
                note: row.remark,
                tags: row.tags,
                account: account(named: row.account, fallbackCurrency: row.currency),
                transferAccount: isFlow ? nil : account(named: row.transferAccount, fallbackCurrency: row.currency),
                source: .icost,
                fingerprint: fingerprint,
                rawPayload: (try? encoder.encode(row.raw)).map { String(decoding: $0, as: UTF8.self) })
            transaction.address = row.address
            transaction.refundAmount = row.refund
            transaction.discountAmount = row.discount
            transaction.feeAmount = row.fee
            transaction.importRecord = record
            context.insert(transaction)
            stats.inserted += 1
        }

        record.inserted = stats.inserted
        record.skipped = stats.skipped
        record.flagged = stats.rejected
        record.status = stats.rejected == 0 ? .success : .partial
        record.summary = "\(stats.inserted) added, \(stats.skipped) already there"
        record.errorLog = parsed.rejected.prefix(50).map { "row \($0.line): \($0.reason)" }.joined(separator: "\n")
        try context.save()
        return stats
    }

    @MainActor
    @discardableResult
    static func importFile(at url: URL, into context: ModelContext) throws -> Stats {
        let parsed = try parse(rows: try XLSXReader.firstSheetRows(at: url))
        return try commit(parsed, fileName: url.lastPathComponent, into: context)
    }
}
