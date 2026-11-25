import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

@Observable
final class EntryInput {
    var expression = ""
    var note = ""

    static let operators: Set<Character> = ["+", "−", "×", "÷"]

    var hasOperator: Bool { expression.contains { Self.operators.contains($0) } }
    var amount: Decimal? { Self.evaluate(expression) }

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

struct EntryStats {
    var categories: [TransactionKind: [String]] = [:]
    var subcategories: [TransactionKind: [String: [String]]] = [:]
    var lastAccount: [TransactionKind: UUID] = [:]
    var lastTransferTarget: UUID?

    @MainActor static var latest: EntryStats?

    static func refresh(_ container: ModelContainer) async -> EntryStats {
        let stats = await Task.detached(priority: .userInitiated) { load(ModelContext(container)) }.value
        await MainActor.run { latest = stats }
        return stats
    }

    nonisolated static func load(_ context: ModelContext) -> EntryStats {
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
        for entry in CategoryStyles.stored().custom {
            guard let kind = TransactionKind(rawValue: entry.kind) else { continue }
            if entry.parent.isEmpty {
                if !(stats.categories[kind] ?? []).contains(entry.name) { stats.categories[kind, default: []].append(entry.name) }
            } else {
                var subs = stats.subcategories[kind]?[entry.parent] ?? []
                if !subs.contains(entry.name) { subs.append(entry.name) }
                stats.subcategories[kind, default: [:]][entry.parent] = subs
                if !(stats.categories[kind] ?? []).contains(entry.parent) { stats.categories[kind, default: []].append(entry.parent) }
            }
        }
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
    @State private var picking: AccountSlot?

    private enum AccountSlot: String, Identifiable {
        case account, to
        var id: String { rawValue }
    }
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

    private static let margin: CGFloat = 10

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
                         date: date, savedCount: savedCount, onMore: openMore, onSave: save)
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
            accountID = DefaultAccounts.pick(for: kind, among: accounts, lastUsed: stats.lastAccount[kind])
            if kind == .transfer && transferAccountID == nil { transferAccountID = stats.lastTransferTarget }
        }
        .sheet(item: $picking) { slot in
            AccountPickerSheet(title: slot == .to ? tr("To") : (kind == .transfer ? tr("From") : tr("Account")),
                               selected: slot == .to ? transferAccountID : accountID) { chosen in
                if slot == .to { transferAccountID = chosen.id } else { accountID = chosen.id }
            }
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #endif
        }
        .sheet(item: $moreDraft, onDismiss: load) {
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
            else if key == "save" || key == "done" { input.note = "perf-probe"; save(closing: key == "done") }
            else { input.press(key) }
        }
        #endif
    }

    private func load() {
        #if os(iOS)
        keyTapFeedback.prepare()
        savedFeedback.prepare()
        #endif
        if let latest = EntryStats.latest { use(latest) }
        let container = context.container
        Task { @MainActor in
            let fresh = await EntryStats.refresh(container)
            withAnimation(.easeOut(duration: 0.18)) { use(fresh) }
        }
    }

    private func use(_ fresh: EntryStats) {
        stats = fresh
        if accountID == nil { accountID = DefaultAccounts.pick(for: kind, among: accounts, lastUsed: fresh.lastAccount[kind]) }
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 19, weight: .medium).monospacedDigit())
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
                    .font(.system(size: 16, weight: .regular).monospacedDigit())
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
                        .font(.system(size: 15, weight: selected ? .semibold : .medium).monospacedDigit())
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
                            EntryCategoryCell(name: name, kind: kind, selected: category == name, size: 46,
                                              hasChildren: !subs(name).isEmpty) { pick(name) }
                        }
                    }
                    if row.contains(category), !subs(category).isEmpty {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(subs(category), id: \.self) { name in
                                EntryCategoryCell(name: name, kind: kind, selected: subcategory == name, size: 42,
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
            accountMenu(title: tr("From"), slot: .account, selection: accountID)
            Image(systemName: "arrow.down")
                .foregroundStyle(DS.textTertiary)
            accountMenu(title: tr("To"), slot: .to, selection: transferAccountID)
        }
        .padding(.horizontal, Self.margin)
        .padding(.vertical, 16)
    }

    private func accountMenu(title: String, slot: AccountSlot, selection: UUID?) -> some View {
        Button { picking = slot } label: {
            HStack(spacing: 10) {
                Text(title).foregroundStyle(DS.textTertiary)
                Spacer()
                if let chosen = accounts.first(where: { $0.id == selection }) {
                    AccountIcon(account: chosen, size: 26)
                }
                Text(accounts.first { $0.id == selection }?.name ?? "—")
                    .foregroundStyle(DS.textPrimary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11).monospacedDigit()).foregroundStyle(DS.textTertiary)
            }
            .font(.system(size: 16, weight: .regular).monospacedDigit())
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(DS.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if kind != .transfer {
                        Button { picking = .account } label: {
                            EntryChip(text: account?.name ?? tr("Account")) {
                                if let account {
                                    AccountIcon(account: account, size: 24)
                                } else {
                                    Image(systemName: "creditcard.fill")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(DS.ink)
                                        .frame(width: 24, height: 24)
                                        .background(Circle().fill(DS.accent))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if kind == .expense {
                        Button { claim.toggle() } label: {
                            EntryChip(text: tr("Reimburse"), active: claim) {
                                Image(systemName: claim ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 17).monospacedDigit())
                                    .foregroundStyle(claim ? DS.accentText : DS.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if kind != .transfer {
                        Button { excluded.toggle() } label: {
                            EntryChip(text: tr("Not counted"), active: excluded) {
                                Image(systemName: excluded ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 17).monospacedDigit())
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
                    .font(.system(size: 21, weight: .regular).monospacedDigit())
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
                .font(.system(size: 11, weight: .medium).monospacedDigit())
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

    private func apply(_ draft: ReceiptDraft) {
        let name = CategoryName.resolve(draft.category ?? "", among: stats.categories[draft.kind] ?? [])
        let sub = CategoryName.resolve(draft.subcategory ?? "", among: stats.subcategories[draft.kind]?[name] ?? [])
        if draft.kind != kind && Self.kinds.contains(draft.kind) {
            if !name.isEmpty { carried = (name, sub) }
            kind = draft.kind
        } else if !name.isEmpty {
            category = name
            subcategory = sub
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
        let values = (date: date, kind: kind, account: account, category: category, subcategory: subcategory,
                      note: input.note.trimmingCharacters(in: .whitespaces), claim: claim, excluded: excluded,
                      target: accounts.first { $0.id == transferAccountID })
        let context = context
        let commit = {
            let record = Transaction(date: values.date, kind: values.kind, amount: amount,
                                     currencyCode: values.account?.currencyCode ?? "CNY",
                                     category: values.kind == .transfer ? "Transfer" : values.category,
                                     subcategory: values.kind == .transfer ? "" : values.subcategory,
                                     note: values.note,
                                     account: values.account,
                                     transferAccount: values.kind == .transfer ? values.target : nil)
            if values.kind == .expense && values.claim { record.claimStatus = .pending }
            if values.kind != .transfer && values.excluded { record.excludeFromStats = true }
            context.insert(record)
            PerfLog.time("entry.save") { try? context.save() }
        }
        if closing {
            #if os(iOS)
            savedFeedback.notificationOccurred(.success)
            #endif
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: commit)
        } else {
            savedCount += 1
            withAnimation(.snappy(duration: 0.22)) { input.expression = "" }
            input.note = ""
            claim = false
            excluded = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: commit)
        }
    }
}

enum EntryGlyph {
    private static let table: [(words: [String], symbol: String)] = [
        (["cigar", "smok", "香烟", "抽烟"], "smoke"),
        (["juice", "果汁"], "takeoutbag.and.cup.and.straw"),
        (["milk", "牛奶"], "mug"),
        (["bottled water", "drinking water", "mineral water", "矿泉水", "饮用水"], "waterbottle"),
        (["cocktail", "wine", "beer", "鸡尾酒", "啤酒", "红酒"], "wineglass"),
        (["necess", "日用品"], "cart"),
        (["lover", "love", "恋人", "约会"], "heart"),
        (["massage", "按摩"], "figure.mind.and.body"),
        (["ticket", "门票"], "ticket"),
        (["edu", "tuition", "教育", "学费"], "graduationcap"),
        (["family", "家人", "家庭"], "figure.2.and.child.holdinghands"),
        (["haircut", "barber", "理发"], "scissors"),
        (["openai", "chatgpt", "claude", "gpt"], "brain"),
        (["express", "delivery", "courier", "快递"], "shippingbox"),
        (["badminton", "羽毛球"], "figure.badminton"),
        (["visa", "passport", "签证"], "person.text.rectangle"),
        (["vpn", "梯子"], "network"),
        (["google one", "icloud", "cloud", "云盘"], "cloud"),
        (["ipad", "tablet", "平板"], "ipad"),
        (["laundry", "洗衣"], "washer"),
        (["laptop", "macbook", "电脑"], "laptopcomputer"),
        (["drift", "漂移", "卡丁"], "steeringwheel"),
        (["usdt", "usdc", "crypto"], "dollarsign"),
        (["diving", "潜水"], "figure.open.water.swim"),
        (["squash", "壁球"], "figure.squash"),
        (["climb", "攀岩"], "figure.climbing"),
        (["roller", "amusement", "游乐"], "party.popper"),
        (["volley", "排球"], "volleyball"),
        (["ktv", "karaoke", "唱歌"], "music.mic"),
        (["tennis", "网球"], "figure.tennis"),
        (["surf", "冲浪", "帆板"], "figure.surfing"),
        (["paddl", "kayak", "桨板"], "figure.sailing"),
        (["cycling", "骑行"], "figure.outdoor.cycle"),
        (["opera", "theater", "theatre", "戏剧", "歌剧", "话剧"], "theatermasks"),
        (["swim", "游泳"], "figure.pool.swim"),
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
        (["accom", "rent", "hotel", "住", "房", "酒店"], "building.2"),
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
    let kind: TransactionKind
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
                    if let symbol = CategoryName.displaySymbol(for: name) {
                        Image(systemName: symbol)
                            .font(.system(size: size * 0.42, weight: .regular).monospacedDigit())
                            .foregroundStyle(selected ? DS.ink : DS.textPrimary)
                    } else {
                        Text(String(parts.label.prefix(1)).uppercased())
                            .font(.system(size: size * 0.42, weight: .medium).monospacedDigit())
                            .foregroundStyle(selected ? DS.ink : DS.textPrimary)
                    }
                }
                .frame(width: size, height: size)
                .overlay(alignment: .bottomTrailing) {
                    if hasChildren {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(DS.bgSecondary, DS.textPrimary)
                            .offset(x: 3, y: 1)
                    }
                }
                Text(parts.label)
                    .font(.system(size: 12, weight: .regular).monospacedDigit())
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
            Text(text).font(.system(size: 15, weight: .regular).monospacedDigit()).lineLimit(1)
        }
        .foregroundStyle(DS.textPrimary)
        .padding(.leading, 8)
        .padding(.trailing, 13)
        .frame(height: 36)
        .background(Capsule().fill(active ? DS.accentDark : DS.bgElevated))
    }
}

private struct EntryPad: View {
    @Bindable var input: EntryInput
    let kind: TransactionKind
    let currency: String
    let date: Date
    let savedCount: Int
    let onMore: () -> Void
    let onSave: (_ closing: Bool) -> Void
    @FocusState private var padFocused: Bool
    @State private var toast = false
    @State private var bump = false

    private static let rows = [["1", "2", "3", "+×"], ["4", "5", "6", "−÷"],
                               ["7", "8", "9", "again"], [".", "0", "⌫", "done"]]

    var body: some View {
        VStack(spacing: 8) {
            card
                .scaleEffect(bump ? 0.97 : 1)
                .overlay(alignment: .top) {
                    if toast {
                        Label(trf("%d recorded", savedCount), systemImage: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(DS.ink)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(Capsule().fill(DS.accent))
                            .offset(y: -16)
                            .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.8)))
                    }
                }
                .padding(.bottom, 4)
                .onChange(of: savedCount) { _, _ in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.55)) { bump = true; toast = true }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(140))
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { bump = false }
                        try? await Task.sleep(for: .milliseconds(1000))
                        withAnimation(.easeOut(duration: 0.25)) { toast = false }
                    }
                }
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
                    .font(DS.money(34))
                    .foregroundStyle(amountColor)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.22), value: input.expression)
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
                    Image(systemName: "clock").font(.system(size: 13, weight: .regular).monospacedDigit())
                    Text(date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 15, weight: .regular).monospacedDigit())
                }
                .foregroundStyle(DS.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Capsule().fill(DS.bgPrimary.opacity(0.6)))
                TextField(tr("Add a note"), text: $input.note)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16).monospacedDigit())
                    .foregroundStyle(DS.textPrimary)
                    .onSubmit { padFocused = true }
                Button(action: onMore) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 14, weight: .regular).monospacedDigit())
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
        return PadKey(fill: isDone ? DS.accent : DS.bgElevated, height: keyHeight, firesOnTouchDown: !isDone && !isAgain) {
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
        }
    }

    private var keyHeight: CGFloat {
        #if os(iOS)
        49
        #else
        44
        #endif
    }
}

private struct PadKey<Label: View>: View {
    let fill: Color
    let height: CGFloat
    let firesOnTouchDown: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var pressed = false
    @State private var cancelled = false

    var body: some View {
        label()
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(fill.opacity(pressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .scaleEffect(pressed ? 0.95 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: pressed)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !pressed && !cancelled {
                            pressed = true
                            if firesOnTouchDown { fire() }
                        }
                        let inside = abs(value.translation.width) < 40 && abs(value.translation.height) < 40
                        if !inside && pressed && !firesOnTouchDown { pressed = false; cancelled = true }
                    }
                    .onEnded { _ in
                        if pressed && !firesOnTouchDown { fire() }
                        pressed = false
                        cancelled = false
                    }
            )
    }

    private func fire() {
        #if os(iOS)
        keyTapFeedback.impactOccurred(intensity: 0.6)
        #endif
        action()
    }
}

#if os(iOS)
@MainActor private let keyTapFeedback = UIImpactFeedbackGenerator(style: .soft)
@MainActor private let savedFeedback = UINotificationFeedbackGenerator()
#endif
