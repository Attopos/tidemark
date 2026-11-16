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
    private var tint: Color { kind == .income ? DS.lime : kind == .expense ? DS.violet : DS.textTertiary }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if savedCount > 0 {
                Text(trf("%d recorded", savedCount))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.textTertiary)
                    .padding(.bottom, 2)
            }
            if kind == .transfer {
                transferPickers
                Spacer(minLength: 0)
            } else {
                categoryGrid
            }
            VStack(spacing: 10) {
                chips
                if showsDate {
                    DatePicker("", selection: $date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                EntryPad(input: input, kind: kind, currency: account?.currencyCode ?? "CNY",
                         category: kind == .transfer ? "" : (subcategory.isEmpty ? category : subcategory),
                         date: date, onSave: save)
            }
            .padding(.horizontal, margin)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background {
                UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous)
                    .fill(DS.panel)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .background(DS.page)
        #if os(macOS)
        .frame(width: 460, height: 760)
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
            else { input.press(key) }
        }
        #endif
    }

    private var margin: CGFloat {
        #if os(iOS)
        DS.phoneMargin
        #else
        20
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
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DS.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(DS.tile)
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .frame(maxWidth: .infinity, alignment: .leading)
            CapsuleSwitch(options: Self.kinds, selection: $kind) { $0.displayName }
                .fixedSize()
            Group {
                if kind != .transfer {
                    Menu {
                        ForEach(accounts) { item in
                            Button("\(item.name) · \(item.currencyCode)") { accountID = item.id }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(account?.name ?? tr("Account"))
                                .lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.textPrimary)
                        .padding(.horizontal, 11)
                        .frame(height: 32)
                        .background(DS.tile)
                        .clipShape(Capsule())
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, margin)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: Categories

    private func pick(_ name: String) {
        if category == name { category = ""; subcategory = "" }
        else { category = name; subcategory = "" }
    }

    private var categoryGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)
        let names = names
        let rows = stride(from: 0, to: names.count, by: 5).map { Array(names[$0..<Swift.min($0 + 5, names.count)]) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(row, id: \.self) { name in
                            CategoryCell(name: name, kind: kind, selected: category == name, size: 48,
                                         tint: tint, hasChildren: !subs(name).isEmpty) { pick(name) }
                        }
                    }
                    if row.contains(category), !subs(category).isEmpty {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(subs(category), id: \.self) { name in
                                CategoryCell(name: name, kind: kind, selected: subcategory == name, size: 40,
                                             tint: tint, hasChildren: false) {
                                    subcategory = subcategory == name ? "" : name
                                }
                            }
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 4)
                        .background(DS.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                    }
                }
                if names.isEmpty {
                    Text(tr("Categories you use appear here. Tap More to type a new one."))
                        .font(DS.caption)
                        .foregroundStyle(DS.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(.horizontal, margin)
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
        .padding(.horizontal, margin)
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
            .background(DS.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }

    // MARK: Chips

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { showsDate.toggle() } label: {
                    EntryChip(icon: "calendar", text: Calendar.current.isDateInToday(date)
                              ? tr("Today") : Fmt.dateMedium.string(from: date), active: showsDate)
                }
                .buttonStyle(.plain)
                if kind == .expense {
                    Button { claim.toggle() } label: {
                        EntryChip(icon: claim ? "checkmark.circle.fill" : "arrow.uturn.left.circle",
                                  text: tr("Reimburse"), active: claim)
                    }
                    .buttonStyle(.plain)
                }
                if kind != .transfer {
                    Button { excluded.toggle() } label: {
                        EntryChip(icon: excluded ? "eye.slash.fill" : "eye.slash", text: tr("Not counted"),
                                  active: excluded)
                    }
                    .buttonStyle(.plain)
                }
                imageChip
                Button { openMore() } label: {
                    EntryChip(icon: "ellipsis", text: tr("More"))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, margin)
        }
        .padding(.horizontal, -margin)
    }

    @ViewBuilder private var imageChip: some View {
        let label = EntryChip(icon: readingImage ? "hourglass" : "photo", text: tr("Image"))
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

    /// Done saves and closes; Again saves and clears for the next one.
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

private struct CategoryCell: View {
    let name: String
    let kind: TransactionKind
    let selected: Bool
    let size: CGFloat
    let tint: Color
    let hasChildren: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                CategoryIcon(name: name, kind: kind, size: size)
                    .background(Circle().fill(selected ? tint : .clear))
                    .overlay(alignment: .bottomTrailing) {
                        if hasChildren {
                            Image(systemName: "ellipsis.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(DS.textPrimary, DS.panel)
                                .offset(x: 2, y: 2)
                        }
                    }
                Text(CategoryName.label(name))
                    .font(.system(size: 11.5, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? DS.textPrimary : DS.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct EntryChip: View {
    let icon: String
    let text: String
    var active = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 14, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(active ? DS.ink : DS.textPrimary)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(active ? DS.accent : DS.tile)
        .clipShape(Capsule())
    }
}

/// Amount card and keypad. Reads EntryInput, so only this redraws on a key.
private struct EntryPad: View {
    @Bindable var input: EntryInput
    let kind: TransactionKind
    let currency: String
    let category: String
    let date: Date
    let onSave: (_ closing: Bool) -> Void
    @FocusState private var padFocused: Bool

    private static let rows = [["1", "2", "3", "⌫"], ["4", "5", "6", "+×"],
                               ["7", "8", "9", "−÷"], ["again", "0", ".", "done"]]

    var body: some View {
        VStack(spacing: 10) {
            card
            VStack(spacing: 8) {
                ForEach(Self.rows, id: \.self) { row in
                    HStack(spacing: 8) {
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

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                if !category.isEmpty {
                    CategoryIcon(name: category, kind: kind, size: 28)
                    Text(CategoryName.label(category))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    if input.hasOperator {
                        Text(input.expression)
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(DS.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Text(Fmt.money(input.amount ?? 0, currency))
                        .font(DS.money(32, weight: .bold))
                        .foregroundStyle(kind == .income ? FlowPalette.income
                                         : kind == .expense ? FlowPalette.expense : DS.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .layoutPriority(1)
            }
            Divider().overlay(DS.border)
            HStack(spacing: 8) {
                Text(date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(DS.textSecondary)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(DS.tile)
                    .clipShape(Capsule())
                TextField(tr("Add a note"), text: $input.note)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(DS.textPrimary)
                    .onSubmit { padFocused = true }
            }
        }
        .padding(14)
        .background(DS.page)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                case "⌫": Image(systemName: "delete.left")
                case "+×": Text("+ ×")
                case "−÷": Text("− ÷")
                case "again": Text(tr("Again"))
                case "done": Text(input.hasOperator ? "=" : tr("Done"))
                default: Text(key)
                }
            }
            .font(.system(size: isDone || isAgain ? 17 : 23, weight: isDone || isAgain ? .bold : .medium)
                .monospacedDigit())
            .foregroundStyle(isDone ? DS.ink : DS.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: keyHeight)
            .background(isDone ? DS.accent : DS.tile)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var keyHeight: CGFloat {
        #if os(iOS)
        52
        #else
        44
        #endif
    }
}
