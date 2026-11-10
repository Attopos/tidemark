import Foundation
import AppKit
import Vision
import SwiftData
import Observation

// MARK: - Alipay screenshot OCR
//
// Pipeline: NSImage → Vision text recognition (zh-Hans + en) → layout parser
// that groups observations into fund cards → editable review drafts → explicit
// user confirmation → holdings + dated valuation snapshots. Uncertain fields
// are flagged, never silently written. If a screenshot only shows a value, we
// store a dated valuation — units/cost are never invented.

struct RecognizedLine: Identifiable {
    let id = UUID()
    let text: String
    /// Vision-normalized bounding box (origin bottom-left, 0…1).
    let box: CGRect
    let confidence: Double
}

enum OCRError: LocalizedError {
    case notAnImage
    case recognitionFailed(String)
    case noText

    var errorDescription: String? {
        switch self {
        case .notAnImage: return "The file is not a readable image."
        case .recognitionFailed(let why): return "Text recognition failed: \(why)"
        case .noText: return "No text was recognized in this image."
        }
    }
}

// MARK: Vision wrapper

enum AlipayOCRService {
    static func recognize(image: NSImage) async throws -> [RecognizedLine] {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw OCRError.notAnImage
        }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: OCRError.recognitionFailed(error.localizedDescription))
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines: [RecognizedLine] = observations.compactMap { obs in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return RecognizedLine(text: candidate.string,
                                          box: obs.boundingBox,
                                          confidence: Double(candidate.confidence))
                }
                if lines.isEmpty {
                    continuation.resume(throwing: OCRError.noText)
                } else {
                    continuation.resume(returning: lines)
                }
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: OCRError.recognitionFailed(error.localizedDescription))
                }
            }
        }
    }
}

// MARK: Parsed structures

struct OCRField {
    var value: Decimal
    var confidence: Double
    var needsReview: Bool
    var sourceText: String
}

struct HoldingDraft: Identifiable {
    let id = UUID()
    var name: String
    var code: String?
    var nameConfidence: Double
    var marketValue: OCRField?
    var profit: OCRField?
    var returnRatePercent: OCRField?   // e.g. 12.4 means +12.4%
    var dayProfit: OCRField?
    var quantity: OCRField?
    var unitNAV: OCRField?
    var costBasis: OCRField?
    /// Union of contributing boxes (Vision coordinates) for the overlay.
    var box: CGRect

    var hasAnyValue: Bool {
        marketValue != nil || quantity != nil || unitNAV != nil || profit != nil
    }
    var needsReview: Bool {
        nameConfidence < 0.6
            || [marketValue, profit, returnRatePercent, quantity, unitNAV, costBasis]
                .compactMap { $0 }.contains { $0.needsReview }
    }
}

struct AlipayParseOutput {
    var drafts: [HoldingDraft]
    var accountTotal: OCRField?
    var lines: [RecognizedLine]
}

// MARK: Layout parser (pure — unit-testable without Vision)

enum AlipayScreenshotParser {

    enum FieldKind {
        case marketValue, profit, returnRate, dayProfit, dayReturnRate, quantity, nav, cost, accountTotal
    }

    static let labelMap: [(keywords: [String], kind: FieldKind)] = [
        (["持有收益率", "收益率"], .returnRate),
        (["昨日收益率", "日涨幅"], .dayReturnRate),
        (["昨日收益", "昨天收益", "日收益"], .dayProfit),
        (["持有收益", "累计收益", "总收益", "收益"], .profit),
        (["持有金额", "持仓金额", "资产金额", "总金额", "金额"], .marketValue),
        (["总资产", "资产总额"], .accountTotal),
        (["持有份额", "持仓份额", "份额"], .quantity),
        (["单位净值", "最新净值", "净值"], .nav),
        (["持仓成本价", "持仓成本", "成本价", "成本"], .cost),
    ]

    static let fundTypeHints = ["混合", "债", "股票", "指数", "货币", "QDII", "ETF", "联接", "基金",
                                "精选", "成长", "价值", "优选", "回报", "先锋", "主题", "医疗", "消费",
                                "科技", "红利", "新能源", "沪深", "中证", "标普", "纳斯达克", "行业",
                                "灵活配置", "养老", "量化", "平衡", "LOF", "FOF"]

    static let uiNoiseWords = ["持有", "收益", "金额", "净值", "份额", "成本", "昨日", "总资产", "隐藏", "排序",
                               "筛选", "搜索", "全部", "买入", "卖出", "定投", "明细", "交易", "组合", "自选",
                               "基金名称", "最近", "更多", "我的", "账户", "待确认", "资产分析", "安全保障"]

    /// Alipay renders category pills ("基金", "定投", "黄金") right after the
    /// fund name; Vision often merges them into the name observation. Strip
    /// them only when they follow a space, an ASCII letter/digit, or a closing
    /// paren — never when they end a CJK name ("天弘余额宝货币").
    static let nameBadgeSuffixes = ["定投", "基金", "黄金", "理财", "债券", "货币"]

    static func stripBadgeSuffixes(_ name: String) -> String {
        var result = name.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for badge in nameBadgeSuffixes where result.hasSuffix(badge) && result.count > badge.count {
                let stem = String(result.dropLast(badge.count))
                guard let prev = stem.last else { continue }
                let separated = prev.isWhitespace
                    || (prev.isASCII && (prev.isLetter || prev.isNumber))
                    || prev == ")" || prev == "）"
                if separated {
                    result = stem.trimmingCharacters(in: .whitespaces)
                    changed = true
                    break
                }
            }
        }
        return result
    }

    static func normalize(_ text: String) -> String {
        (text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text)
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "：", with: ":")
            .trimmingCharacters(in: .whitespaces)
    }

    static func cjkCount(_ text: String) -> Int {
        text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
    }

    /// Extract the first number from text: (value, isPercent, hadSign).
    static func extractNumber(_ text: String) -> (value: Decimal, isPercent: Bool)? {
        var normalized = normalize(text).replacingOccurrences(of: "−", with: "-")
        // Vision sometimes reads a thousands comma as a period ("18.432.75").
        // A period followed by exactly 3 digits and then another separator+digit
        // can only be a thousands separator, never a decimal point.
        if let dotGroup = try? NSRegularExpression(pattern: #"(\d{1,3})\.(\d{3})(?=[.,]\d)"#) {
            var previous = ""
            while previous != normalized {
                previous = normalized
                let range = NSRange(normalized.startIndex..., in: normalized)
                normalized = dotGroup.stringByReplacingMatches(in: normalized, range: range, withTemplate: "$1,$2")
            }
        }
        // Comma-grouped form must contain at least one comma group, otherwise
        // the plain form takes the whole digit run ("5200" must not parse as 520).
        guard let regex = try? NSRegularExpression(pattern: #"[-+]?[¥￥]?\s?\d{1,3}(?:,\d{3})+(?:\.\d+)?%?|[-+]?[¥￥]?\s?\d+(?:\.\d+)?%?"#) else { return nil }
        let range = NSRange(normalized.startIndex..., in: normalized)
        guard let match = regex.firstMatch(in: normalized, range: range),
              let swiftRange = Range(match.range, in: normalized) else { return nil }
        var token = String(normalized[swiftRange])
        let isPercent = token.hasSuffix("%")
        token = token.replacingOccurrences(of: "%", with: "")
        token = token.replacingOccurrences(of: "[¥￥,\\s+]", with: "", options: .regularExpression)
        guard let value = Decimal(string: token, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return (value, isPercent)
    }

    static func matchLabel(_ text: String) -> FieldKind? {
        let t = normalize(text)
        for (keywords, kind) in labelMap {
            if keywords.contains(where: { t.contains($0) }) { return kind }
        }
        return nil
    }

    /// Six-digit fund code not embedded in a longer digit run.
    static func extractFundCode(_ text: String) -> String? {
        let normalized = normalize(text)
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\d)\d{6}(?!\d)"#) else { return nil }
        let range = NSRange(normalized.startIndex..., in: normalized)
        guard let match = regex.firstMatch(in: normalized, range: range),
              let swiftRange = Range(match.range, in: normalized) else { return nil }
        return String(normalized[swiftRange])
    }

    static func looksLikeFundName(_ text: String) -> Bool {
        let t = normalize(text)
        guard cjkCount(t) >= 4 else { return false }
        // Reject pure UI chrome.
        let stripped = t.replacingOccurrences(of: "[0-9.,%+\\-¥￥\\s]", with: "", options: .regularExpression)
        if uiNoiseWords.contains(stripped) { return false }
        if matchLabel(t) != nil && !fundTypeHints.contains(where: { t.contains($0) }) { return false }
        return fundTypeHints.contains { t.contains($0) }
    }

    /// Group observations into visual rows (top to bottom).
    static func groupRows(_ lines: [RecognizedLine]) -> [[RecognizedLine]] {
        let sorted = lines.sorted { $0.box.midY > $1.box.midY }  // Vision origin is bottom-left
        var rows: [[RecognizedLine]] = []
        for line in sorted {
            if var last = rows.last, let anchor = last.first {
                let tolerance = max(anchor.box.height, line.box.height) * 0.6
                if Swift.abs(anchor.box.midY - line.box.midY) < tolerance {
                    last.append(line)
                    rows[rows.count - 1] = last
                    continue
                }
            }
            rows.append([line])
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    static func parse(lines: [RecognizedLine]) -> AlipayParseOutput {
        let rows = groupRows(lines)
        var drafts: [HoldingDraft] = []
        var accountTotal: OCRField?
        var current: HoldingDraft?

        func field(from line: RecognizedLine, value: Decimal, extraUncertain: Bool = false) -> OCRField {
            OCRField(value: value,
                     confidence: line.confidence,
                     needsReview: line.confidence < 0.6 || extraUncertain,
                     sourceText: line.text)
        }

        func assign(_ kind: FieldKind, _ field: OCRField, to draft: inout HoldingDraft) {
            switch kind {
            case .marketValue: if draft.marketValue == nil { draft.marketValue = field }
            case .profit: if draft.profit == nil { draft.profit = field }
            case .returnRate: if draft.returnRatePercent == nil { draft.returnRatePercent = field }
            case .dayProfit: if draft.dayProfit == nil { draft.dayProfit = field }
            case .quantity: if draft.quantity == nil { draft.quantity = field }
            case .nav: if draft.unitNAV == nil { draft.unitNAV = field }
            case .cost: if draft.costBasis == nil { draft.costBasis = field }
            case .accountTotal, .dayReturnRate: break
            }
        }

        func flush() {
            if let draft = current, draft.hasAnyValue || draft.code != nil {
                drafts.append(draft)
            }
            current = nil
        }

        for (rowIndex, row) in rows.enumerated() {
            // New fund card?
            if let nameLine = row.first(where: { looksLikeFundName($0.text) }) {
                flush()
                var cleanName = normalize(nameLine.text)
                let code = extractFundCode(cleanName)
                if let code {
                    cleanName = cleanName.replacingOccurrences(of: code, with: "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: " ()（）-|"))
                }
                cleanName = stripBadgeSuffixes(cleanName)
                current = HoldingDraft(name: cleanName, code: code,
                                       nameConfidence: nameLine.confidence, box: nameLine.box)
            }

            for line in row {
                let text = normalize(line.text)
                let labelKind = matchLabel(text)
                let number = extractNumber(text)

                // Account-level total.
                if labelKind == .accountTotal {
                    if let number, !number.isPercent, number.value > 0 {
                        accountTotal = field(from: line, value: number.value)
                    } else if let valueLine = valueNear(line: line, inRow: row, nextRow: rowIndex + 1 < rows.count ? rows[rowIndex + 1] : []),
                              let v = extractNumber(valueLine.text), !v.isPercent {
                        accountTotal = field(from: valueLine, value: v.value)
                    }
                    continue
                }

                guard var draft = current else { continue }
                defer { current = draft }
                if !looksLikeFundName(line.text) {
                    draft.box = draft.box.union(line.box)
                }
                if draft.code == nil, let code = extractFundCode(text), cjkCount(text) <= 2 {
                    draft.code = code
                }
                // A line whose digits are exactly a 6-digit fund code is an
                // identifier ("005827" under the name), never a value.
                if let code = extractFundCode(text),
                   text.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression) == code {
                    continue
                }

                if let labelKind {
                    // Value in the same observation ("持有金额 1,234.56")…
                    if let number {
                        let value = labelKind == .returnRate || number.isPercent ? number.value : number.value
                        assign(resolved(labelKind, isPercent: number.isPercent), field(from: line, value: value), to: &draft)
                    }
                    // …or in a neighbor (right on the same row, else below by column).
                    else if let valueLine = valueNear(line: line, inRow: row,
                                                     nextRow: rowIndex + 1 < rows.count ? rows[rowIndex + 1] : []),
                            let v = extractNumber(valueLine.text) {
                        assign(resolved(labelKind, isPercent: v.isPercent), field(from: valueLine, value: v.value), to: &draft)
                        draft.box = draft.box.union(valueLine.box)
                    }
                } else if let number, matchLabel(text) == nil, !looksLikeFundName(text) {
                    // Unlabeled numbers: classify heuristically (flagged for review).
                    if number.isPercent {
                        if draft.returnRatePercent == nil {
                            draft.returnRatePercent = field(from: line, value: number.value, extraUncertain: true)
                        }
                    } else if text.contains("+") || text.contains("-") {
                        if draft.profit == nil {
                            draft.profit = field(from: line, value: number.value, extraUncertain: true)
                        }
                    } else if draft.marketValue == nil, number.value >= 10 {
                        draft.marketValue = field(from: line, value: number.value, extraUncertain: true)
                    }
                }
            }
        }
        flush()
        return AlipayParseOutput(drafts: drafts, accountTotal: accountTotal, lines: lines)
    }

    private static func resolved(_ kind: FieldKind, isPercent: Bool) -> FieldKind {
        // A percent value under a "收益" label is really the rate.
        if kind == .profit && isPercent { return .returnRate }
        return kind
    }

    /// Value observation for a label: nearest number to the right on the same
    /// row, else the number in the next row with the largest x-overlap.
    private static func valueNear(line: RecognizedLine, inRow row: [RecognizedLine],
                                  nextRow: [RecognizedLine]) -> RecognizedLine? {
        let rightward = row
            .filter { $0.id != line.id && $0.box.minX >= line.box.minX - 0.02 && extractNumber($0.text) != nil && matchLabel($0.text) == nil }
            .sorted { Swift.abs($0.box.minX - line.box.maxX) < Swift.abs($1.box.minX - line.box.maxX) }
        if let best = rightward.first { return best }

        let below = nextRow
            .filter { extractNumber($0.text) != nil && matchLabel($0.text) == nil }
            .map { candidate -> (RecognizedLine, CGFloat) in
                let overlap = min(candidate.box.maxX, line.box.maxX + 0.06) - max(candidate.box.minX, line.box.minX - 0.06)
                return (candidate, overlap)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        return below.first?.0
    }
}

// MARK: - Review session

@MainActor
@Observable
final class AlipayOCRSession {
    enum Phase: Equatable {
        case recognizing
        case review
        case saving
        case done
        case failed(String)
    }

    struct EditableHolding: Identifiable {
        let id = UUID()
        var include = true
        var name: String
        var code: String
        var marketValue: String
        var profit: String
        var returnRatePercent: String
        var quantity: String
        var unitNAV: String
        var costBasis: String
        var flaggedFields: Set<String>
        var sourceBox: CGRect
        /// Existing holding this draft matched (by code, then name); nil = new.
        var matchedHoldingID: UUID?
        var matchedLabel: String?
    }

    let images: [NSImage]
    var phase: Phase = .recognizing
    private(set) var lines: [RecognizedLine] = []
    var holdings: [EditableHolding] = []
    var accountTotalText: String = ""
    var valuationDate = Date()
    var savedSummary = ""
    var showBoxes = true
    var currentImageIndex = 0

    init(images: [NSImage]) {
        self.images = images
    }

    func run(existingHoldings: [Holding]) async {
        phase = .recognizing
        var allDrafts: [HoldingDraft] = []
        var total: OCRField?
        var collectedLines: [RecognizedLine] = []
        for image in images {
            do {
                let recognized = try await AlipayOCRService.recognize(image: image)
                if collectedLines.isEmpty { collectedLines = recognized }
                let output = AlipayScreenshotParser.parse(lines: recognized)
                allDrafts.append(contentsOf: output.drafts)
                if total == nil { total = output.accountTotal }
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
        }
        self.lines = collectedLines

        // Merge duplicates across screenshots (same code or normalized name).
        var merged: [HoldingDraft] = []
        for draft in allDrafts {
            if let index = merged.firstIndex(where: { existing in
                if let c1 = existing.code, let c2 = draft.code { return c1 == c2 }
                return Self.normalizeName(existing.name) == Self.normalizeName(draft.name)
            }) {
                var target = merged[index]
                target.marketValue = target.marketValue ?? draft.marketValue
                target.profit = target.profit ?? draft.profit
                target.returnRatePercent = target.returnRatePercent ?? draft.returnRatePercent
                target.quantity = target.quantity ?? draft.quantity
                target.unitNAV = target.unitNAV ?? draft.unitNAV
                target.costBasis = target.costBasis ?? draft.costBasis
                target.code = target.code ?? draft.code
                merged[index] = target
            } else {
                merged.append(draft)
            }
        }

        holdings = merged.map { draft in
            var flagged = Set<String>()
            if draft.nameConfidence < 0.6 { flagged.insert("name") }
            func text(_ f: OCRField?, _ key: String, decimals: Int = 2) -> String {
                guard let f else { return "" }
                if f.needsReview { flagged.insert(key) }
                return NSDecimalNumber(decimal: f.value.rounded(decimals)).stringValue
            }
            let match = Self.match(draft: draft, in: existingHoldings)
            return EditableHolding(
                name: draft.name,
                code: draft.code ?? "",
                marketValue: text(draft.marketValue, "marketValue"),
                profit: text(draft.profit, "profit"),
                returnRatePercent: text(draft.returnRatePercent, "returnRatePercent"),
                quantity: text(draft.quantity, "quantity", decimals: 4),
                unitNAV: text(draft.unitNAV, "unitNAV", decimals: 4),
                costBasis: text(draft.costBasis, "costBasis"),
                flaggedFields: flagged,
                sourceBox: draft.box,
                matchedHoldingID: match?.id,
                matchedLabel: match.map { "\($0.asset?.name ?? "holding") · \($0.account?.name ?? "")" }
            )
        }
        if let total {
            accountTotalText = NSDecimalNumber(decimal: total.value.rounded(2)).stringValue
        }
        phase = holdings.isEmpty && accountTotalText.isEmpty
            ? .failed("No fund holdings were recognized. Try a clearer screenshot of the Alipay holdings list (持有页面).")
            : .review
    }

    static func normalizeName(_ name: String) -> String {
        name.replacingOccurrences(of: "[\\s()（）\\-·]", with: "", options: .regularExpression).lowercased()
    }

    static func match(draft: HoldingDraft, in holdings: [Holding]) -> Holding? {
        if let code = draft.code, !code.isEmpty {
            if let byCode = holdings.first(where: { $0.asset?.symbol == code }) { return byCode }
        }
        let target = normalizeName(draft.name)
        guard !target.isEmpty else { return nil }
        if let exact = holdings.first(where: { normalizeName($0.asset?.name ?? "") == target }) { return exact }
        return holdings.first { holding in
            let candidate = normalizeName(holding.asset?.name ?? "")
            guard candidate.count >= 6 else { return false }
            return candidate.contains(target) || target.contains(candidate)
        }
    }

    // MARK: Commit

    struct CommitStats {
        var created = 0
        var updated = 0
        var snapshots = 0
        var snapshotUpdates = 0
    }

    func commit(into context: ModelContext) {
        phase = .saving
        do {
            let stats = try performCommit(into: context)
            savedSummary = "\(stats.created) new holding\(stats.created == 1 ? "" : "s"), \(stats.updated) updated · \(stats.snapshots) valuation\(stats.snapshots == 1 ? "" : "s") saved"
                + (stats.snapshotUpdates > 0 ? " (\(stats.snapshotUpdates) same-day updated in place)" : "")
            phase = .done
        } catch {
            context.rollback()
            phase = .failed("Nothing was saved. \(error.localizedDescription)")
        }
    }

    static let defaultAccountName = "Alipay Funds"

    static func normalizeAccountKey(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private func performCommit(into context: ModelContext) throws -> CommitStats {
        var stats = CommitStats()
        let calendar = Calendar.current

        // New holdings land in one standing investment account; matched
        // holdings keep whichever account they already live in.
        let allAccounts = try context.fetch(FetchDescriptor<Account>())
        var cachedAccount: Account?
        func destinationAccount() -> Account {
            if let cachedAccount { return cachedAccount }
            let key = Self.normalizeAccountKey(Self.defaultAccountName)
            let account = allAccounts.first(where: {
                $0.kind == .investment && Self.normalizeAccountKey($0.name) == key
            }) ?? {
                let created = Account(name: Self.defaultAccountName, kind: .investment,
                                      currencyCode: "CNY", source: .alipayOCR)
                context.insert(created)
                return created
            }()
            cachedAccount = account
            return account
        }

        let record = ImportRecord(source: .alipayOCR, fileName: "Screenshot · \(Fmt.dateMedium.string(from: valuationDate))")
        context.insert(record)

        let allHoldings = try context.fetch(FetchDescriptor<Holding>())
        let allAssets = try context.fetch(FetchDescriptor<Asset>())

        func decimal(_ text: String) -> Decimal? {
            let t = text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            return AlipayScreenshotParser.extractNumber(t)?.value
        }

        for edited in holdings where edited.include {
            let name = edited.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let code = edited.code.trimmingCharacters(in: .whitespaces)
            let marketValue = decimal(edited.marketValue)
            let quantity = decimal(edited.quantity)
            let nav = decimal(edited.unitNAV)
            let cost = decimal(edited.costBasis)
            let profit = decimal(edited.profit)
            let rate = decimal(edited.returnRatePercent)
            guard marketValue != nil || (quantity != nil && nav != nil) else { continue }
            let effectiveValue = marketValue ?? ((quantity ?? 0) * (nav ?? 0))

            // Find or create the holding.
            let holding: Holding
            if let id = edited.matchedHoldingID, let matched = allHoldings.first(where: { $0.id == id }) {
                holding = matched
                stats.updated += 1
            } else {
                let asset: Asset
                if !code.isEmpty, let byCode = allAssets.first(where: { $0.symbol == code }) {
                    asset = byCode
                } else if let byName = allAssets.first(where: { Self.normalizeName($0.name) == Self.normalizeName(name) }) {
                    asset = byName
                } else {
                    asset = Asset(name: name, symbol: code,
                                  assetClass: AssetClass.guessFund(name: name), currencyCode: "CNY")
                    context.insert(asset)
                }
                let account = destinationAccount()
                if let existing = asset.holdings.first(where: { $0.account?.id == account.id && $0.isActive }) {
                    holding = existing
                    stats.updated += 1
                } else {
                    let created = Holding(asset: asset, account: account, source: .alipayOCR)
                    context.insert(created)
                    holding = created
                    stats.created += 1
                }
            }

            // Update current holding facts (only with reviewed, present values).
            if let quantity { holding.quantity = quantity }
            if let cost { holding.costBasis = cost }
            holding.lastUpdated = Date()

            // Same holding + same day → update in place; history is preserved otherwise.
            if let sameDay = holding.snapshots.first(where: { calendar.isDate($0.date, inSameDayAs: valuationDate) }) {
                sameDay.marketValue = effectiveValue
                if let quantity { sameDay.quantity = quantity }
                if let nav { sameDay.unitNAV = nav }
                if let cost { sameDay.costBasis = cost }
                if let profit { sameDay.unrealizedPL = profit }
                if let rate { sameDay.returnRate = rate / 100 }
                sameDay.sourceRaw = DataSource.alipayOCR.rawValue
                stats.snapshotUpdates += 1
            } else {
                let snap = HoldingSnapshot(holding: holding, date: valuationDate,
                                           marketValue: effectiveValue,
                                           quantity: quantity, unitNAV: nav, costBasis: cost,
                                           unrealizedPL: profit,
                                           returnRate: rate.map { $0 / 100 },
                                           source: .alipayOCR)
                snap.importRecord = record
                context.insert(snap)
                stats.snapshots += 1
            }

            // NAV becomes a price point for history.
            if let nav, let asset = holding.asset {
                let hasSameDay = asset.prices.contains { calendar.isDate($0.date, inSameDayAs: valuationDate) }
                if !hasSameDay {
                    context.insert(PricePoint(asset: asset, date: valuationDate, price: nav,
                                              currencyCode: "CNY", source: .alipayOCR))
                }
            }
        }

        record.inserted = stats.snapshots
        record.skipped = stats.snapshotUpdates
        record.summary = "\(stats.snapshots) valuations · \(stats.created) new holdings · \(stats.updated) updated"
        record.status = .success

        let ocrRaw = DataSource.alipayOCR.rawValue
        let stateFetch = FetchDescriptor<ImportSourceState>(predicate: #Predicate { $0.sourceRaw == ocrRaw })
        let state = (try? context.fetch(stateFetch))?.first ?? {
            let s = ImportSourceState(source: .alipayOCR)
            context.insert(s)
            return s
        }()
        state.lastSuccessAt = Date()
        state.totalRecords += stats.snapshots
        state.lastMessage = record.summary
        state.isConnected = true
        state.updatedAt = Date()

        try context.save()
        return stats
    }
}
