import SwiftUI
import SwiftData

// MARK: - Quick entry (iPhone)
//
// The phone's way to record: pick a category from a grid of the ones you
// actually use (most used first), optionally its second level, then type the
// amount on a built-in keypad that also adds and subtracts. Account and date
// sit in chips above the keypad, defaulting to the last account used. Every
// other field (refund, reimbursement, tags) is one tap away in the full
// editor, which "More" opens with what is typed so far.

struct QuickEntryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Account.createdAt) private var allAccounts: [Account]

    private static let kinds: [TransactionKind] = [.expense, .income, .transfer]

    @State private var kind: TransactionKind = .expense
    @State private var category = ""
    @State private var subcategory = ""
    @State private var expression = ""
    @State private var note = ""
    @State private var date = Date()
    @State private var accountID: UUID?
    @State private var transferAccountID: UUID?
    @State private var showsMore = false
    @State private var showsDate = false
    @State private var claim = false
    @State private var tags = ""
    @State private var showsTags = false
    /// Records saved in this sitting with "Record" (enter another).
    @State private var savedCount = 0

    private var accounts: [Account] { allAccounts.filter { $0.isLedgerAccount && !$0.isArchived } }

    // MARK: What the ledger already uses

    /// First-level categories of this kind, most used first.
    private var categories: [String] {
        var counts: [String: Int] = [:]
        for record in transactions.prefix(3000) where record.kind == kind && !record.category.isEmpty {
            counts[record.category, default: 0] += 1
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    private func subcategories(of parent: String) -> [String] {
        var counts: [String: Int] = [:]
        for record in transactions.prefix(3000) where record.kind == kind && record.category == parent
            && !record.subcategory.isEmpty {
            counts[record.subcategory, default: 0] += 1
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    /// The account used most recently for this kind.
    private var lastAccountID: UUID? {
        transactions.first { $0.kind == kind && $0.account?.isArchived == false }?.account?.id ?? accounts.first?.id
    }

    // MARK: Amount

    /// The typed expression: × and ÷ before + and −.
    private var amount: Decimal? {
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

    private static let operators: Set<Character> = ["+", "−", "×", "÷"]
    private var hasOperator: Bool { expression.contains { Self.operators.contains($0) } }

    /// The number being typed (after the last operator).
    private var currentNumber: String {
        expression.split(whereSeparator: { Self.operators.contains($0) }).last.map(String.init) ?? ""
    }

    private func press(_ key: String) {
        switch key {
        case "⌫":
            if !expression.isEmpty { expression.removeLast() }
        case "+×", "−÷":
            // One key, two operators: a second tap swaps them.
            let pair: (Character, Character) = key == "+×" ? ("+", "×") : ("−", "÷")
            guard let last = expression.last, last != "." else { return }
            if last == pair.0 { expression.removeLast(); expression.append(pair.1) }
            else if last == pair.1 { expression.removeLast(); expression.append(pair.0) }
            else if Self.operators.contains(last) { expression.removeLast(); expression.append(pair.0) }
            else { expression.append(pair.0) }
        case ".":
            if expression.isEmpty || Self.operators.contains(expression.last!) { expression += "0." }
            else if !currentNumber.contains(".") { expression.append(".") }
        default:
            let current = currentNumber
            let atStart = expression.isEmpty || Self.operators.contains(expression.last!)
            if !atStart, let dot = current.firstIndex(of: "."), current.distance(from: dot, to: current.endIndex) > 2 { return }
            if !atStart && current == "0" { expression.removeLast() }
            expression.append(key)
        }
    }

    private var canSave: Bool {
        guard amount != nil else { return false }
        if kind == .transfer { return accountID != nil && transferAccountID != nil && accountID != transferAccountID }
        return !category.isEmpty
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(DS.textPrimary)
                        .frame(width: 42, height: 42)
                        .background(DS.tile)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                Spacer()
                CapsuleSwitch(options: Self.kinds, selection: $kind) { $0.displayName }
                Spacer()
                Button(tr("More")) { showsMore = true }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.accentText)
                    .frame(width: 42, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if savedCount > 0 {
                Text(trf("%d recorded", savedCount))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.textTertiary)
            }

            if kind == .transfer {
                transferPickers
                Spacer(minLength: 0)
            } else {
                categoryGrid
            }

            entryPanel
        }
        .background(DS.page)
        .onAppear { if accountID == nil { accountID = lastAccountID } }
        .onChange(of: kind) { _, _ in
            category = ""
            subcategory = ""
            accountID = lastAccountID
        }
        .sheet(isPresented: $showsMore) {
            TransactionEditor(transaction: nil, draft: ReceiptDraft(
                kind: kind, amount: amount, currency: nil, date: date, note: note.isEmpty ? nil : note,
                paymentMethod: nil, accountID: accountID,
                category: category.isEmpty ? nil : category, subcategory: subcategory.isEmpty ? nil : subcategory))
        }
    }

    // MARK: Categories

    private var categoryGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)
        let names = categories
        let rows = stride(from: 0, to: names.count, by: 5).map { Array(names[$0..<Swift.min($0 + 5, names.count)]) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(row, id: \.self) { name in
                            categoryCell(name, selected: category == name, size: 50,
                                         hasChildren: !subcategories(of: name).isEmpty) {
                                if category == name { category = ""; subcategory = "" }
                                else { category = name; subcategory = "" }
                            }
                        }
                    }
                    // The second level opens right under the row it belongs to.
                    if row.contains(category) {
                        let subs = subcategories(of: category)
                        if !subs.isEmpty {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(subs, id: \.self) { name in
                                    categoryCell(name, selected: subcategory == name, size: 44, hasChildren: false) {
                                        subcategory = subcategory == name ? "" : name
                                    }
                                }
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 4)
                            .background(DS.panel)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }
                }
                if names.isEmpty {
                    Text(tr("Categories you use appear here. Tap More to type a new one."))
                        .font(DS.caption)
                        .foregroundStyle(DS.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .animation(.easeInOut(duration: 0.18), value: category)
        }
    }

    private func categoryCell(_ name: String, selected: Bool, size: CGFloat, hasChildren: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                CategoryIcon(name: name, kind: kind, size: size)
                    .background(Circle().fill(selected ? (kind == .income ? DS.lime : DS.violet) : .clear))
                    .overlay(alignment: .bottomTrailing) {
                        if hasChildren {
                            Image(systemName: "ellipsis.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(DS.textPrimary, DS.panel)
                                .offset(x: 2, y: 2)
                        }
                    }
                Text(CategoryName.label(name))
                    .font(.system(size: 11.5, weight: selected ? .bold : .semibold))
                    .foregroundStyle(selected ? DS.textPrimary : DS.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var transferPickers: some View {
        VStack(spacing: 10) {
            accountMenu(title: tr("From"), selection: $accountID)
            Image(systemName: "arrow.down")
                .foregroundStyle(DS.textTertiary)
            accountMenu(title: tr("To"), selection: $transferAccountID)
        }
        .padding(16)
    }

    private func accountMenu(title: String, selection: Binding<UUID?>) -> some View {
        Menu {
            ForEach(accounts) { account in
                Button("\(account.name) · \(account.currencyCode)") { selection.wrappedValue = account.id }
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
    }

    // MARK: Amount, chips and keypad

    private var entryPanel: some View {
        VStack(spacing: 10) {
            // Account, tags, reimbursement, date — like the chips above iCost's keypad.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if kind != .transfer {
                        Menu {
                            ForEach(accounts) { account in
                                Button("\(account.name) · \(account.currencyCode)") { accountID = account.id }
                            }
                        } label: {
                            chip(icon: "creditcard", text: accounts.first { $0.id == accountID }?.name ?? tr("Account"))
                        }
                    }
                    Button { showsTags = true } label: {
                        chip(icon: "tag", text: tags.isEmpty ? tr("Tags") : tags)
                    }
                    .buttonStyle(.plain)
                    if kind == .expense {
                        Button { claim.toggle() } label: {
                            chip(icon: claim ? "checkmark.circle.fill" : "circle", text: tr("Reimburse"),
                                 active: claim)
                        }
                        .buttonStyle(.plain)
                    }
                    Button { showsDate.toggle() } label: {
                        chip(icon: "calendar", text: Calendar.current.isDateInToday(date)
                             ? tr("Today") : Fmt.dateMedium.string(from: date), active: showsDate)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 2)
            }
            if showsDate {
                DatePicker("", selection: $date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .lastTextBaseline) {
                    Text(Fmt.money(amount ?? 0, accounts.first { $0.id == accountID }?.currencyCode ?? "CNY"))
                        .font(DS.money(34, weight: .bold))
                        .foregroundStyle(kind == .income ? FlowPalette.income
                                         : kind == .expense ? FlowPalette.expense : DS.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    if hasOperator {
                        Text(expression)
                            .font(.system(size: 14).monospacedDigit())
                            .foregroundStyle(DS.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
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
                    TextField(tr("Add a note"), text: $note)
                        .font(.system(size: 15))
                        .foregroundStyle(DS.textPrimary)
                }
            }
            .padding(14)
            .background(DS.tile.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            keypad
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(DS.page)
        .alert(tr("Tags"), isPresented: $showsTags) {
            TextField(tr("Tags"), text: $tags)
            Button(tr("Done")) {}
        }
    }

    private func chip(icon: String, text: String, active: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 15, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(active ? DS.ink : DS.textPrimary)
        .padding(.horizontal, 13)
        .frame(height: 38)
        .background(active ? DS.accent : DS.tile)
        .clipShape(Capsule())
    }

    private var keypad: some View {
        let rows = [["1", "2", "3", "+×"], ["4", "5", "6", "−÷"], ["7", "8", "9", "again"], [".", "0", "⌫", "done"]]
        return VStack(spacing: 8) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { keyButton($0) }
                }
            }
        }
    }

    private func keyButton(_ key: String) -> some View {
        let isDone = key == "done"
        let isAgain = key == "again"
        return Button {
            if isDone { save(closing: true) }
            else if isAgain { save(closing: false) }
            else { press(key) }
        } label: {
            Group {
                switch key {
                case "⌫": Image(systemName: "delete.left")
                case "+×": Text("+ ×")
                case "−÷": Text("− ÷")
                case "again": Text(tr("Record"))
                case "done": Text(hasOperator ? "=" : tr("Done"))
                default: Text(key)
                }
            }
            .font(.system(size: isDone || isAgain ? 17 : 24, weight: isDone || isAgain ? .bold : .medium)
                .monospacedDigit())
            .foregroundStyle(isDone ? DS.ink : DS.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(isDone ? DS.accent : DS.tile)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Done saves and closes; Record saves and clears for the next one.
    private func save(closing: Bool) {
        // With a sum on screen the key works as "=" first.
        if hasOperator {
            if let amount { expression = NSDecimalNumber(decimal: amount).stringValue }
            return
        }
        guard canSave, let amount else { return }
        let account = accounts.first { $0.id == accountID }
        let record = Transaction(date: date, kind: kind, amount: amount,
                                 currencyCode: account?.currencyCode ?? "CNY",
                                 category: kind == .transfer ? "Transfer" : category,
                                 subcategory: kind == .transfer ? "" : subcategory,
                                 note: note.trimmingCharacters(in: .whitespaces),
                                 tags: tags.trimmingCharacters(in: .whitespaces),
                                 account: account,
                                 transferAccount: kind == .transfer ? accounts.first { $0.id == transferAccountID } : nil)
        if kind == .expense && claim { record.claimStatus = .pending }
        context.insert(record)
        try? context.save()
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        if closing {
            dismiss()
        } else {
            savedCount += 1
            expression = ""
            note = ""
            claim = false
        }
    }
}
