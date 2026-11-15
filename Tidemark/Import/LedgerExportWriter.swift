import Foundation

// MARK: - Bookkeeping export writer
//
// Writes the ledger as iCost's own export: sheet "收支账单", the 21 columns
// below in this order, dates "yyyy/MM/dd HH:mm:ss" in local time, every cell
// text, expense amounts negative and the rest positive, refund/discount/fee
// blank when zero. Transfer-like rows use their type (Transfer, Lend…) with
// "Transfer" as the category; repayments use "Repayment" for both. Records
// iCost has no type for (investments, adjustments) are left out.

enum LedgerExportWriter {
    static let sheetName = "收支账单"
    static let header = ["Date", "Type", "Amount", "First-Level Category", "Second-Level Category",
                         "Account 1", "Account 2", "Remark", "Currency", "Tag", "Ledger", "Address",
                         "Refund", "Discount", "Fee", "Image 1", "Image 2", "Image 3",
                         "Attachment 1", "Attachment 2", "Attachment 3"]

    private static let transferTypes: [String: String] = [
        "transfer": "Transfer", "转账": "Transfer", "lend": "Lend", "借出": "Lend",
        "borrow": "Borrow", "借入": "Borrow", "collect": "Collect", "收款": "Collect", "收债": "Collect",
        "recharge": "Recharge", "充值": "Recharge",
    ]

    static func isExportable(_ transaction: Transaction) -> Bool {
        switch transaction.kind {
        case .income, .expense, .transfer, .liabilityPayment: return true
        case .investBuy, .investSell, .adjustment: return false
        }
    }

    static func rows(for transactions: [Transaction], timeZone: TimeZone = .current) -> [[String]] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"

        let records = transactions.filter(isExportable).sorted {
            $0.date == $1.date ? $0.createdAt < $1.createdAt : $0.date < $1.date
        }
        let ledgers = records.map(ledgerName)
        var votes: [String: Int] = [:]
        for name in ledgers where !name.isEmpty { votes[name, default: 0] += 1 }
        let defaultLedger = votes.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key ?? ""

        var rows = [header]
        for (record, ledger) in zip(records, ledgers) {
            let type: String
            let category: String
            let subcategory: String
            var amount = number(record.amount)
            switch record.kind {
            case .expense:
                type = "Expense"; category = record.category; subcategory = record.subcategory
                if record.amount != 0 { amount = "-" + amount }
            case .income:
                type = "Income"; category = record.category; subcategory = record.subcategory
            case .liabilityPayment:
                type = "Repayment"; category = "Repayment"; subcategory = ""
            default:
                type = transferTypes[record.category.trimmingCharacters(in: .whitespaces).lowercased()] ?? "Transfer"
                category = "Transfer"; subcategory = ""
            }
            let isFlow = record.kind == .expense || record.kind == .income
            var row = [formatter.string(from: record.date), type, amount, category, subcategory,
                       record.account?.name ?? "", isFlow ? "" : (record.transferAccount?.name ?? ""),
                       record.note, record.currencyCode, record.tags, ledger.isEmpty ? defaultLedger : ledger,
                       record.address, optional(record.refundAmount), optional(record.discountAmount),
                       optional(record.feeAmount)]
            row += Array(repeating: "", count: header.count - row.count)
            rows.append(row)
        }
        return rows
    }

    static func workbook(for transactions: [Transaction], timeZone: TimeZone = .current) -> Data {
        XLSXWriter.workbook(sheetName: sheetName, rows: rows(for: transactions, timeZone: timeZone))
    }

    static func fileName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return "Tidemark_\(formatter.string(from: date)).xlsx"
    }

    private static func ledgerName(_ transaction: Transaction) -> String {
        guard let payload = transaction.rawPayload?.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: String].self, from: payload) else { return "" }
        return (raw["Ledger"] ?? raw["账本"] ?? "").trimmingCharacters(in: .whitespaces)
    }

    private static func number(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private static func optional(_ value: Decimal) -> String {
        value == 0 ? "" : number(abs(value))
    }
}
