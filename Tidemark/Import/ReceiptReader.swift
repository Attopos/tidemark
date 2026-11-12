import Foundation
import Vision
import CoreGraphics
import SwiftData

// MARK: - Receipt screenshots
//
// A payment screenshot (an Alipay or WeChat bill detail, a bank app's
// transaction page) becomes a filled-in record: the amount is the largest
// money figure on the page, the merchant is the line just above it, the
// time is the first date-and-time on the page, and the account is guessed
// from the payment-method line. Category and subcategory are taken from the
// latest record with the same merchant, so the ledger's own habits fill
// them in. Nothing is saved until the user confirms the editor.

/// What a screenshot told us; every part is optional.
struct ReceiptDraft: Equatable {
    var kind: TransactionKind = .expense
    var amount: Decimal?
    var currency: String?
    var date: Date?
    var note: String?
    var paymentMethod: String?
    var accountID: UUID?
    var category: String?
    var subcategory: String?
}

/// One recognized line and where it sat (Vision coordinates: 0…1, origin
/// bottom-left).
struct ReceiptLine: Equatable {
    let text: String
    let box: CGRect
}

enum ReceiptReader {

    // MARK: Recognition

    static func recognize(_ image: CGImage) async throws -> [ReceiptLine] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let lines = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { observation in
                    observation.topCandidates(1).first.map { ReceiptLine(text: $0.string, box: observation.boundingBox) }
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = false
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: Parsing

    private static let moneyPattern = try! NSRegularExpression(
        pattern: #"^([+\-−])?\s*([¥￥$€]|CNY|RMB)?\s*([+\-−])?\s*(\d{1,3}(?:,\d{3})+|\d+)\.(\d{2})(?:\s*元)?$"#)
    private static let datePattern = try! NSRegularExpression(
        pattern: #"(20\d{2})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})\s*日?\s*(\d{1,2}):(\d{2})(?::(\d{2}))?"#)

    /// Words that sit near the amount but are never the merchant.
    private static let notMerchant = ["交易成功", "支付成功", "已支付", "当前状态", "账单详情", "付款成功", "成功",
                                      "Transaction", "Success", "Paid", "收款", "全部账单"]
    private static let methodLabels = ["付款方式", "支付方式", "付款卡", "Payment method", "Paid with"]

    /// Read a draft out of recognized lines. `history` maps merchant text to
    /// its latest (category, subcategory); `accounts` are (id, name) pairs.
    static func parse(_ lines: [ReceiptLine],
                      history: [String: (category: String, subcategory: String)] = [:],
                      accounts: [(id: UUID, name: String)] = [],
                      timeZone: TimeZone = .current) -> ReceiptDraft {
        var draft = ReceiptDraft()
        // Top of the page first.
        let ordered = lines.sorted { $0.box.midY > $1.box.midY }

        // Amount: the tallest standalone money figure.
        var amountLine: ReceiptLine?
        for line in ordered {
            let text = line.text.replacingOccurrences(of: " ", with: "")
            let range = NSRange(text.startIndex..., in: text)
            guard let match = moneyPattern.firstMatch(in: text, range: range) else { continue }
            if let current = amountLine, current.box.height >= line.box.height { continue }
            amountLine = line
            func group(_ index: Int) -> String? {
                let r = match.range(at: index)
                return r.location == NSNotFound ? nil : Range(r, in: text).map { String(text[$0]) }
            }
            let digits = (group(4) ?? "").replacingOccurrences(of: ",", with: "") + "." + (group(5) ?? "00")
            draft.amount = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX"))
            let sign = group(1) ?? group(3)
            draft.kind = sign == "+" ? .income : .expense
            switch group(2) {
            case "$": draft.currency = "USD"
            case "€": draft.currency = "EUR"
            case .some: draft.currency = "CNY"
            default: draft.currency = nil
            }
        }

        // Merchant: the nearest real line above the amount.
        if let amountLine {
            let above = ordered.filter { $0.box.midY > amountLine.box.maxY }
                .sorted { $0.box.midY < $1.box.midY }
            draft.note = above.first { line in
                let text = line.text.trimmingCharacters(in: .whitespaces)
                return text.count >= 2 && !notMerchant.contains(where: text.contains)
                    && moneyPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil
            }?.text.trimmingCharacters(in: .whitespaces)
        }

        // Time: the first full date and time on the page.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        for line in ordered {
            let text = line.text
            guard let match = datePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
                continue
            }
            func number(_ index: Int) -> Int? {
                let r = match.range(at: index)
                return r.location == NSNotFound ? nil : Range(r, in: text).flatMap { Int(text[$0]) }
            }
            draft.date = calendar.date(from: DateComponents(year: number(1), month: number(2), day: number(3),
                                                           hour: number(4), minute: number(5), second: number(6) ?? 0))
            break
        }

        // Payment method: text after the label, on the same line or to its right.
        for line in ordered {
            guard let label = methodLabels.first(where: line.text.contains) else { continue }
            var value = line.text.components(separatedBy: label).last?
                .trimmingCharacters(in: CharacterSet(charactersIn: " :：")) ?? ""
            if value.isEmpty {
                value = ordered.filter { $0 != line && abs($0.box.midY - line.box.midY) < line.box.height * 0.8
                    && $0.box.minX > line.box.minX }
                    .min { $0.box.minX < $1.box.minX }?.text ?? ""
            }
            if !value.isEmpty { draft.paymentMethod = value }
            break
        }
        if let method = draft.paymentMethod {
            draft.accountID = matchAccount(method, accounts: accounts)
        }

        // Category from the ledger's own history with this merchant.
        if let merchant = draft.note, let known = history[merchant] {
            draft.category = known.category
            draft.subcategory = known.subcategory
        }
        return draft
    }

    /// Payment-method text → one of the user's accounts.
    static func matchAccount(_ method: String, accounts: [(id: UUID, name: String)]) -> UUID? {
        let text = method.lowercased()
        // Direct name match first ("BOC", "WECHAT").
        if let direct = accounts.first(where: { !$0.name.isEmpty && text.contains($0.name.lowercased()) }) {
            return direct.id
        }
        let aliases: [(words: [String], names: [String])] = [
            (["余额宝"], ["yeb", "余额宝"]),
            (["零钱", "微信"], ["wechat", "微信"]),
            (["余额"], ["alipay", "支付宝"]),
            (["中国银行"], ["boc", "中国银行"]),
            (["工商银行"], ["icbc", "工商"]),
            (["农业银行"], ["abc", "农业"]),
            (["招商银行"], ["cmb", "招商"]),
            (["中信银行"], ["citic", "中信"]),
            (["建设银行"], ["ccb", "建设"]),
            (["花呗"], ["花呗", "huabei"]),
        ]
        for alias in aliases where alias.words.contains(where: text.contains) {
            if let found = accounts.first(where: { account in
                alias.names.contains { account.name.lowercased().contains($0) }
            }) {
                return found.id
            }
        }
        return nil
    }
}

// MARK: - From an image to an editor

/// A draft waiting for the editor sheet.
struct PendingReceipt: Identifiable {
    let id = UUID()
    let draft: ReceiptDraft
}

enum ReceiptImport {
    /// Recognize the screenshot and fill a draft from the ledger's accounts
    /// and the categories already used with the same merchant.
    @MainActor
    static func draft(from image: CGImage, context: ModelContext) async -> ReceiptDraft {
        let lines = (try? await ReceiptReader.recognize(image)) ?? []
        let records = (try? context.fetch(FetchDescriptor<Transaction>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        var history: [String: (category: String, subcategory: String)] = [:]
        for record in records where record.kind == .expense || record.kind == .income {
            let merchant = record.note.trimmingCharacters(in: .whitespaces)
            if !merchant.isEmpty && history[merchant] == nil {
                history[merchant] = (record.category, record.subcategory)
            }
        }
        let accounts = ((try? context.fetch(FetchDescriptor<Account>())) ?? [])
            .filter { $0.isLedgerAccount && !$0.isArchived }
            .map { (id: $0.id, name: $0.name) }
        return ReceiptReader.parse(lines, history: history, accounts: accounts)
    }
}
