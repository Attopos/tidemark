import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

// MARK: - Quick entry
//
// The way to add a record on both iPhone and Mac, laid out like iCost's: kind
// switch with the account on top, a grid of the categories actually used
// (second level opens under its row), quick chips, the amount card and a
// calculator keypad. Typing lives in EntryInput so a key press redraws only
// the pad; category counts are read once per sitting, not on every render.

@Observable
final class EntryInput {
    var expression = ""
    var note = ""

    static let operators: Set<Character> = ["+", "−", "×", "÷"]

    var hasOperator: Bool { expression.contains { Self.operators.contains($0) } }
    var amount: Decimal? { Self.evaluate(expression) }

    /// × and ÷ before + and −; nil unless the result is above zero.
    static func evaluate(_ expression: String) -> Decimal? {
        let posix = Locale(identifier: "en_US_POSIX")
        var terms: [Decimal] = []
        var term: Decimal?
        var pendingProduct: Character?
        var sign: Decimal = 1
        var number = ""
        func takeNumber() -> Bool {
            guard !number.isEmpty, let value = Decimal(string: number, locale: posix) else { return number.isEmpty }
            number = ""
            switch pendingProduct {
            case "×": term = (term ?? 0) * value
            case "÷": guard value != 0 else { return false }; term = (term ?? 0) / value
            default: term = sign * value
            }
            pendingProduct = nil
            return true
        }
        for character in expression {
            switch character {
            case "+", "−":
                guard takeNumber() else { return nil }
                if let term { terms.append(term) }
                term = nil
                sign = character == "+" ? 1 : -1
            case "×", "÷":
                guard takeNumber() else { return nil }
                pendingProduct = character
            default:
                number.append(character)
            }
        }
        guard takeNumber() else { return nil }
        if let term { terms.append(term) }
        let total = terms.reduce(0, +)
        guard total > 0 else { return nil }
        return total.rounded(2)
    }

    static func press(_ key: String, on expression: inout String) {
        let currentNumber = expression.split(whereSeparator: { operators.contains($0) }).last.map(String.init) ?? ""
        let atStart = expression.last.map { operators.contains($0) } ?? true
        switch key {
        case "⌫":
            if !expression.isEmpty { expression.removeLast() }
        case "+×", "−÷", "+", "−", "×", "÷":
            let pair: (Character, Character) = key.hasPrefix("+") || key == "×" ? ("+", "×") : ("−", "÷")
            guard let last = expression.last, last != "." else { return }
            if key.count == 1 {
                let symbol = Character(key)
                if operators.contains(last) { expression.removeLast() }
                expression.append(symbol)
            } else if last == pair.0 { expression.removeLast(); expression.append(pair.1) }
            else if last == pair.1 { expression.removeLast(); expression.append(pair.0) }
            else if operators.contains(last) { expression.removeLast(); expression.append(pair.0) }
            else { expression.append(pair.0) }
        case ".":
            if atStart { expression += "0." }
            else if !currentNumber.contains(".") { expression.append(".") }
        default:
            if !atStart, let dot = currentNumber.firstIndex(of: "."),
               currentNumber.distance(from: dot, to: currentNumber.endIndex) > 2 { return }
            if !atStart && currentNumber == "0" { expression.removeLast() }
            expression.append(key)
        }
    }

    func press(_ key: String) { Self.press(key, on: &expression) }

    func set(amount: Decimal?) {
        expression = amount.map { NSDecimalNumber(decimal: $0.rounded(2)).stringValue } ?? ""
    }
}

/// Categories in use, most used first, and the last account per kind.
struct EntryStats {
    var categories: [TransactionKind: [String]] = [:]
    var subcategories: [TransactionKind: [String: [String]]] = [:]
    var lastAccount: [TransactionKind: UUID] = [:]
    var lastTransferTarget: UUID?

    @MainActor
    static func load(_ context: ModelContext) -> EntryStats {
        var descriptor = FetchDescriptor<Transaction>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 3000
        descriptor.propertiesToFetch = [\.kindRaw, \.category, \.subcategory, \.date]
        let records = (try? context.fetch(descriptor)) ?? []
        var top: [TransactionKind: [String: Int]] = [:]
        var second: [TransactionKind: [String: [String: Int]]] = [:]
        var stats = EntryStats()
        for record in records {
            let kind = record.kind
            guard kind == .expense || kind == .income || kind == .transfer else { continue }
            if kind != .transfer && !record.category.isEmpty {
                top[kind, default: [:]][record.category, default: 0] += 1
                if !record.subcategory.isEmpty {
                    second[kind, default: [:]][record.category, default: [:]][record.subcategory, default: 0] += 1
                }
            }
            if stats.lastAccount[kind] == nil, let account = record.account, !account.isArchived {
                stats.lastAccount[kind] = account.id
                if kind == .transfer { stats.lastTransferTarget = record.transferAccount?.id }
            }
        }
        func ranked(_ counts: [String: Int]) -> [String] {
            counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
        }
        for (kind, counts) in top { stats.categories[kind] = ranked(counts) }
        for (kind, parents) in second { stats.subcategories[kind] = parents.mapValues(ranked) }
        return stats
    }
}

struct QuickEntryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.createdAt) private var allAccounts: [Account]

    private static let kinds: [TransactionKind] = [.expense, .income, .transfer]

    @State private var input = EntryInput()
    @State private var stats = EntryStats()
    @State private var kind: TransactionKind = .expense
    @State private var category = ""
    @State private var subcategory = ""
    @State private var date: Date
    @State private var accountID: UUID?
    @State private var transferAccountID: UUID?
    @State private var showsDate = false
    @State private var claim = false
    @State private var excluded = false
    @State private var moreDraft: PendingReceipt?
    @State private var readingImage = false
    @State private var savedCount = 0
    @State private var carried: (category: String, subcategory: String)?
    #if os(iOS)
    @State private var photo: PhotosPickerItem?
    #endif

    init(defaultDate: Date? = nil) {
        var start = Date()
        if let defaultDate, !Calendar.current.isDateInToday(defaultDate) {
            let time = Calendar.current.dateComponents([.hour, .minute], from: Date())
            start = Calendar.current.date(bySettingHour: time.hour ?? 12, minute: time.minute ?? 0,
                                          second: 0, of: defaultDate) ?? defaultDate
        }
        _date = State(initialValue: start)
    }

    private var accounts: [Account] { allAccounts.filter { $0.isLedgerAccount && !$0.isArchived } }
    private var account: Account? { accounts.first { $0.id == accountID } }
    private var names: [String] { stats.categories[kind] ?? [] }
    private func subs(_ parent: String) -> [String] { stats.subcategories[kind]?[parent] ?? [] }

    /// iCost's entry page sits 10pt from the edges, not the app's usual 25.
    private static let margin: CGFloat = 10

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if kind == .transfer {
                transferPickers
                Spacer(minLength: 0)
            } else {
                categoryGrid
            }
            VStack(spacing: 8) {
                chips
                if showsDate {
                    DatePicker("", selection: $date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Self.margin)
                }
                EntryPad(input: input, kind: kind, currency: account?.currencyCode ?? "CNY",
                         date: date, onMore: openMore, onSave: save)
                    .padding(.horizontal, Self.margin)
            }
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .background(DS.bgSecondary.ignoresSafeArea())
        #if os(macOS)
        .frame(width: 460, height: 780)
        #endif
        .onAppear(perform: load)
        .onChange(of: kind) { _, _ in
            category = carried?.category ?? ""
            subcategory = carried?.subcategory ?? ""
            carried = nil
            accountID = stats.lastAccount[kind] ?? accounts.first?.id
            if kind == .transfer && transferAccountID == nil { transferAccountID = stats.lastTransferTarget }
        }
        .sheet(item: $moreDraft, onDismiss: { stats = EntryStats.load(context) }) {
            TransactionEditor(transaction: nil, draft: $0.draft)
        }
        #if os(iOS)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            readingImage = true
            Task { @MainActor in
                defer { readingImage = false; photo = nil }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data)?.cgImageValue else { return }
                apply(await ReceiptImport.draft(from: image, context: context))
            }
        }
        #endif
        #if DEBUG && os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: PerfProbe.entryKey)) { note in
            guard let key = note.object as? String, key != "noop" else { return }
            if key.hasPrefix("cat:"), let i = Int(key.dropFirst(4)), i < names.count { pick(names[i]) }
            else if key == "sub:0", let first = subs(category).first { subcategory = first }
            else { input.press(key) }
        }
        #endif
    }

    private func load() {
        stats = EntryStats.load(context)
        if accountID == nil { accountID = stats.lastAccount[kind] ?? accounts.first?.id }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 0) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(DS.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(DS.bgPrimary))
                    .overlay(Circle().strokeBorder(DS.border, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .frame(maxWidth: .infinity, alignment: .leading)
            kindSwitch
            Button { showsDate.toggle() } label: {
                Text(Calendar.current.isDateInToday(date) ? tr("Today") : Fmt.dateMedium.string(from: date))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(DS.accentText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    private var kindSwitch: some View {
        HStack(spacing: 0) {
            ForEach(Self.kinds, id: \.self) { option in
                let selected = option == kind
                Button { kind = option } label: {
                    Text(option.displayName)
                        .font(.system(size: 15, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? DS.textPrimary : DS.textSecondary)
                        .fixedSize()
                        .padding(.horizontal, 13)
                        .frame(height: 30)
                        .background(Capsule().fill(selected ? DS.bgElevated.opacity(1) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(DS.bgPrimary))
        .overlay(Capsule().strokeBorder(DS.border, lineWidth: 1))
        .fixedSize()
    }

    // MARK: Categories

    private func pick(_ name: String) {
        if category == name { category = ""; subcategory = "" }
        else { category = name; subcategory = "" }
    }

    private var categoryGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 5)
        let names = names
        let rows = stride(from: 0, to: names.count, by: 5).map { Array(names[$0..<Swift.min($0 + 5, names.count)]) }
        return ScrollView {
            VStack(spacing: 18) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(row, id: \.self) { name in
                            EntryCategoryCell(name: name, selected: category == name, size: 46,
                                              hasChildren: !subs(name).isEmpty) { pick(name) }
                        }
                    }
                    if row.contains(category), !subs(category).isEmpty {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(subs(category), id: \.self) { name in
                                EntryCategoryCell(name: name, selected: subcategory == name, size: 42,
                                                  hasChildren: false) {
                                    subcategory = subcategory == name ? "" : name
                                }
                            }
                        }
                        .padding(.vertical, 14)
                        .background(DS.bgElevated.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .padding(.horizontal, 6)
                        .transition(.opacity)
                    }
                }
                if names.isEmpty {
                    Text(tr("Categories you use appear here. Tap More to type a new one."))
                        .font(DS.caption)
                        .foregroundStyle(DS.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .padding(.bottom, 14)
            .animation(.easeOut(duration: 0.16), value: category)
        }
        .scrollIndicators(.hidden)
    }

    private var transferPickers: some View {
        VStack(spacing: 10) {
            accountMenu(title: tr("From"), selection: $accountID)
            Image(systemName: "arrow.down")
                .foregroundStyle(DS.textTertiary)
            accountMenu(title: tr("To"), selection: $transferAccountID)
        }
        .padding(.horizontal, Self.margin)
        .padding(.vertical, 16)
    }

    private func accountMenu(title: String, selection: Binding<UUID?>) -> some View {
        Menu {
            ForEach(accounts) { item in
                Button("\(item.name) · \(item.currencyCode)") { selection.wrappedValue = item.id }
            }
        } label: {
            HStack {
                Text(title).foregroundStyle(DS.textTertiary)
                Spacer()
                Text(accounts.first { $0.id == selection.wrappedValue }?.name ?? "—")
                    .foregroundStyle(DS.textPrimary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)).foregroundStyle(DS.textTertiary)
            }
            .font(.system(size: 16, weight: .medium))
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(DS.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }

    // MARK: Chips

    private var chips: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if kind != .transfer {
                        Menu {
                            ForEach(accounts) { item in
                                Button("\(item.name) · \(item.currencyCode)") { accountID = item.id }
                            }
                        } label: {
                            EntryChip(text: account?.name ?? tr("Account")) {
                                Image(systemName: "creditcard.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(DS.ink)
                                    .frame(width: 24, height: 24)
                                    .background(Circle().fill(DS.accent))
                            }
                        }
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                    }
                    if kind == .expense {
                        Button { claim.toggle() } label: {
                            EntryChip(text: tr("Reimburse"), active: claim) {
                                Image(systemName: claim ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 17))
                                    .foregroundStyle(claim ? DS.accentText : DS.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if kind != .transfer {
                        Button { excluded.toggle() } label: {
                            EntryChip(text: tr("Not counted"), active: excluded) {
                                Image(systemName: excluded ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 17))
                                    .foregroundStyle(excluded ? DS.accentText : DS.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    imageChip
                }
                .padding(.leading, Self.margin)
                .padding(.trailing, 4)
            }
            Button { openMore() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(DS.textPrimary)
                    .frame(width: 34, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, Self.margin)
        }
    }

    @ViewBuilder private var imageChip: some View {
        let label = EntryChip(text: tr("Image")) {
            Image(systemName: readingImage ? "hourglass" : "photo")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.ink)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.violet))
        }
        #if os(iOS)
        PhotosPicker(selection: $photo, matching: .images) { label }
            .buttonStyle(.plain)
        #else
        Button { pickImage() } label: { label }
            .buttonStyle(.plain)
        #endif
    }

    #if os(macOS)
    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let image = PlatformImage.load(url)?.cgImageValue else { return }
        readingImage = true
        Task { @MainActor in
            defer { readingImage = false }
            apply(await ReceiptImport.draft(from: image, context: context))
        }
    }
    #endif

    /// Fill from a receipt screenshot.
    private func apply(_ draft: ReceiptDraft) {
        let name = draft.category ?? ""
        if draft.kind != kind && Self.kinds.contains(draft.kind) {
            if !name.isEmpty { carried = (name, draft.subcategory ?? "") }
            kind = draft.kind
        } else if !name.isEmpty {
            category = name
            subcategory = draft.subcategory ?? ""
        }
        if let amount = draft.amount { input.set(amount: amount) }
        if let note = draft.note, input.note.isEmpty { input.note = note }
        if let when = draft.date { date = when }
        if let id = draft.accountID { accountID = id }
    }

    private func openMore() {
        moreDraft = PendingReceipt(draft: ReceiptDraft(
            kind: kind, amount: input.amount, currency: nil, date: date,
            note: input.note.isEmpty ? nil : input.note, paymentMethod: nil, accountID: accountID,
            category: category.isEmpty ? nil : category, subcategory: subcategory.isEmpty ? nil : subcategory))
    }

    // MARK: Save

    /// Done saves and closes; Record saves and clears for the next one.
    private func save(closing: Bool) {
        if input.hasOperator {
            input.set(amount: input.amount)
            return
        }
        guard let amount = input.amount else { return }
        if kind == .transfer {
            guard accountID != nil, transferAccountID != nil, accountID != transferAccountID else { return }
        } else if category.isEmpty {
            return
        }
        let record = Transaction(date: date, kind: kind, amount: amount,
                                 currencyCode: account?.currencyCode ?? "CNY",
                                 category: kind == .transfer ? "Transfer" : category,
                                 subcategory: kind == .transfer ? "" : subcategory,
                                 note: input.note.trimmingCharacters(in: .whitespaces),
                                 account: account,
                                 transferAccount: kind == .transfer ? accounts.first { $0.id == transferAccountID } : nil)
        if kind == .expense && claim { record.claimStatus = .pending }
        if kind != .transfer && excluded { record.excludeFromStats = true }
        context.insert(record)
        try? context.save()
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        if closing {
            dismiss()
        } else {
            savedCount += 1
            input.expression = ""
            input.note = ""
            claim = false
            excluded = false
        }
    }
}

// MARK: - Pieces

/// Line glyphs for the entry grid, like iCost's; the emoji stays in the label.
enum EntryGlyph {
    private static let table: [(words: [String], symbol: String)] = [
        (["subway", "metro", "地铁"], "tram"),
        (["train", "火车", "高铁"], "train.side.front.car"),
        (["taxi", "打车", "出租"], "car"),
        (["bike", "bicycle", "单车", "自行车"], "bicycle"),
        (["aircraft", "plane", "flight", "飞机", "机票"], "airplane"),
        (["bus", "公交"], "bus"),
        (["car rent", "租车"], "car.side"),
        (["motor", "摩托", "电动车"], "scooter"),
        (["parking", "停车"], "parkingsign.circle"),
        (["relation", "social", "人情", "社交"], "person.2"),
        (["ferry", "轮渡", "船"], "ferry"),
        (["transp", "交通"], "tram"),
        (["meal", "正餐", "饭"], "fork.knife"),
        (["fruit", "水果"], "carrot"),
        (["bread", "面包"], "takeoutbag.and.cup.and.straw"),
        (["cook", "做饭", "买菜"], "frying.pan"),
        (["protein", "肉", "蛋"], "fish"),
        (["sweet", "dessert", "甜"], "birthday.cake"),
        (["vege", "蔬菜"], "leaf"),
        (["snack", "零食"], "popcorn"),
        (["food", "餐", "吃"], "fork.knife"),
        (["drink", "coffee", "tea", "饮", "咖啡", "奶茶"], "cup.and.saucer"),
        (["accom", "rent", "hotel", "住", "房"], "building.2"),
        (["daily", "日用"], "basket"),
        (["digital", "数码", "phone", "手机"], "iphone"),
        (["sport", "gym", "fitness", "运动", "健身"], "figure.run"),
        (["travel", "旅"], "globe.asia.australia"),
        (["entertain", "game", "娱乐", "游戏"], "gamecontroller"),
        (["movie", "电影"], "film"),
        (["study", "learn", "course", "学", "书"], "book"),
        (["work", "office", "工作", "办公"], "briefcase"),
        (["outfit", "cloth", "衣", "服"], "tshirt"),
        (["pet", "cat", "dog", "宠"], "pawprint"),
        (["health", "medic", "hospital", "医", "药"], "waveform.path.ecg"),
        (["beauty", "美"], "sparkles"),
        (["invest", "投资"], "chart.line.uptrend.xyaxis"),
        (["insur", "保险"], "shield"),
        (["utilit", "electric", "水电"], "bolt"),
        (["subscri", "订阅", "会员"], "repeat"),
        (["salary", "工资", "薪"], "banknote"),
        (["part time", "兼职", "freelance"], "clock"),
        (["bonus", "奖金"], "star"),
        (["interest", "利息", "dividend", "分红"], "percent"),
        (["refund", "退款"], "arrow.uturn.backward"),
        (["resale", "二手"], "arrow.triangle.2.circlepath"),
        (["gift", "favor", "红包", "礼"], "gift"),
    ]

    static func symbol(for name: String) -> String? {
        let label = CategoryName.label(name).lowercased()
        return table.first { $0.words.contains(where: label.contains) }?.symbol
    }
}

private struct EntryCategoryCell: View {
    let name: String
    let selected: Bool
    let size: CGFloat
    let hasChildren: Bool
    let action: () -> Void

    var body: some View {
        let parts = CategoryName.split(name)
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    Circle().fill(selected ? DS.accent : DS.bgElevated)
                    if let symbol = EntryGlyph.symbol(for: name) {
                        Image(systemName: symbol)
                            .font(.system(size: size * 0.42, weight: .regular))
                            .foregroundStyle(selected ? DS.ink : DS.textPrimary)
                    } else if let emoji = parts.emoji {
                        Text(emoji).font(.system(size: size * 0.46))
                    } else {
                        Text(String(parts.label.prefix(1)).uppercased())
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundStyle(selected ? DS.ink : DS.textPrimary)
                    }
                }
                .frame(width: size, height: size)
                .overlay(alignment: .bottomTrailing) {
                    if hasChildren {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.bgSecondary, DS.textPrimary)
                            .offset(x: 3, y: 1)
                    }
                }
                Text((parts.emoji ?? "") + parts.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct EntryChip<Icon: View>: View {
    let text: String
    var active = false
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: 7) {
            icon()
            Text(text).font(.system(size: 15, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(DS.textPrimary)
        .padding(.leading, 8)
        .padding(.trailing, 13)
        .frame(height: 36)
        .background(Capsule().fill(active ? DS.accentDark : DS.bgElevated))
    }
}

/// Amount card and keypad. Reads EntryInput, so only this redraws on a key.
private struct EntryPad: View {
    @Bindable var input: EntryInput
    let kind: TransactionKind
    let currency: String
    let date: Date
    let onMore: () -> Void
    let onSave: (_ closing: Bool) -> Void
    @FocusState private var padFocused: Bool

    private static let rows = [["1", "2", "3", "+×"], ["4", "5", "6", "−÷"],
                               ["7", "8", "9", "again"], [".", "0", "⌫", "done"]]

    var body: some View {
        VStack(spacing: 8) {
            card
                .padding(.bottom, 4)
            VStack(spacing: 7) {
                ForEach(Self.rows, id: \.self) { row in
                    HStack(spacing: 7) {
                        ForEach(row, id: \.self) { key($0) }
                    }
                }
            }
        }
        #if os(macOS)
        .focusable()
        .focusEffectDisabled()
        .focused($padFocused)
        .onAppear { padFocused = true }
        .onKeyPress(phases: .down) { press in
            if press.key == .return { onSave(true); return .handled }
            if press.key == .delete || press.key == .deleteForward { input.press("⌫"); return .handled }
            let map: [String: String] = ["+": "+", "-": "−", "*": "×", "x": "×", "/": "÷", ",": "."]
            let typed = press.characters
            if let symbol = map[typed] { input.press(symbol); return .handled }
            if typed.count == 1, typed == "." || typed.first!.isWholeNumber { input.press(typed); return .handled }
            return .ignored
        }
        #endif
    }

    private var amountColor: Color {
        kind == .income ? FlowPalette.income : kind == .expense ? FlowPalette.expense : DS.textPrimary
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(Fmt.money(input.amount ?? 0, currency))
                    .font(DS.money(34, weight: .semibold))
                    .foregroundStyle(amountColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if input.hasOperator {
                    Text(input.expression)
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(DS.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(height: 62)
            Divider().overlay(DS.border)
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: "clock").font(.system(size: 13, weight: .medium))
                    Text(date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 15, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(DS.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Capsule().fill(DS.bgPrimary.opacity(0.6)))
                TextField(tr("Add a note"), text: $input.note)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(DS.textPrimary)
                    .onSubmit { padFocused = true }
                Button(action: onMore) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DS.textPrimary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(DS.bgPrimary.opacity(0.6)))
                }
                .buttonStyle(.plain)
            }
            .frame(height: 50)
        }
        .padding(.horizontal, 16)
        .background(DS.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func key(_ key: String) -> some View {
        let isDone = key == "done"
        let isAgain = key == "again"
        return Button {
            if isDone { onSave(true) }
            else if isAgain { onSave(false) }
            else { input.press(key) }
        } label: {
            Group {
                switch key {
                case "⌫": Image(systemName: "delete.left.fill").font(.system(size: 22))
                case "+×": Text("+ ×")
                case "−÷": Text("− ÷")
                case "again": Text(tr("Again"))
                case "done": Text(input.hasOperator ? "=" : tr("Done"))
                default: Text(key)
                }
            }
            .font(.system(size: isDone || isAgain ? 18 : 25, weight: isDone || isAgain ? .semibold : .regular)
                .monospacedDigit())
            .foregroundStyle(isDone ? DS.ink : DS.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: keyHeight)
            .background(isDone ? DS.accent : DS.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var keyHeight: CGFloat {
        #if os(iOS)
        49
        #else
        44
        #endif
    }
}
