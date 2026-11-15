import Foundation

// MARK: - Bookkeeping export writer
//
// Writes the ledger as iCost's import template (help.icostapp.com, 模板导入;
// file.icostapp.com/icost_template.xlsx), so iCost can import it — iCost's
// own export is "not suitable for secondary import". One sheet
// "icost_template", columns 日期 类型 金额 一级分类 二级分类 账户1 账户2 备注
// 货币 标签, dates "yyyy年MM月dd日 HH:mm:ss" in local time, types 支出 / 收入 /
// 转账, amounts as plain positive numbers (expenses net of refunds). The
// template has only 转账 for money between accounts, so the kind of transfer
// (Transfer, Lend, Repayment…) goes in 一级分类, where Tidemark's importer
// reads it back. Records iCost has no type for (investments, adjustments) are
// left out.

enum LedgerExportWriter {
    static let sheetName = "icost_template"
    static let header = ["日期", "类型", "金额", "一级分类", "二级分类", "账户1", "账户2", "备注", "货币", "标签"]
    static let amountColumn = 2

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
        formatter.dateFormat = "yyyy年MM月dd日 HH:mm:ss"

        let records = transactions.filter(isExportable).sorted {
            $0.date == $1.date ? $0.createdAt < $1.createdAt : $0.date < $1.date
        }
        var rows = [header]
        for record in records {
            let type: String
            let category: String
            let subcategory: String
            var amount = record.amount
            switch record.kind {
            case .expense:
                type = "支出"; category = record.category; subcategory = record.subcategory
                amount = max(0, record.amount - record.refundAmount)
            case .income:
                type = "收入"; category = record.category; subcategory = record.subcategory
            case .liabilityPayment:
                type = "转账"; category = "Repayment"; subcategory = ""
            default:
                type = "转账"; category = LedgerExportType.canonical(record.category.isEmpty ? "Transfer" : record.category)
                subcategory = ""
            }
            let isFlow = record.kind == .expense || record.kind == .income
            rows.append([formatter.string(from: record.date), type, NSDecimalNumber(decimal: amount).stringValue,
                         category, subcategory, record.account?.name ?? "",
                         isFlow ? "" : (record.transferAccount?.name ?? ""),
                         record.note, record.currencyCode, ""])
        }
        return rows
    }

    static func workbook(for transactions: [Transaction], timeZone: TimeZone = .current) -> Data {
        XLSXWriter.workbook(sheetName: sheetName, rows: rows(for: transactions, timeZone: timeZone),
                            numericColumns: [amountColumn])
    }

    static func fileName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return "Tidemark_\(formatter.string(from: date)).xlsx"
    }
}
