import Foundation

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
                type = "支出"; category = CategoryName.withoutSymbol(record.category); subcategory = CategoryName.withoutSymbol(record.subcategory)
                amount = max(0, record.amount - record.refundAmount)
            case .income:
                type = "收入"; category = CategoryName.withoutSymbol(record.category); subcategory = CategoryName.withoutSymbol(record.subcategory)
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
