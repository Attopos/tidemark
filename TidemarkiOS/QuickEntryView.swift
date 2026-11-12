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

    /// The typed expression, evaluated left to right (only + and −).
    private var amount: Decimal? {
        var total: Decimal = 0
        var sign: Decimal = 1
        var number = ""
        func flush() -> Bool {
            guard !number.isEmpty else { return true }
            guard let value = Decimal(string: number, locale: Locale(identifier: "en_US_POSIX")) else { return false }
            total += sign * value
            number = ""
            return true
        }
        for character in expression {
            switch character {
            case "+": guard flush() else { return nil }; sign = 1
            case "−": guard flush() else { return nil }; sign = -1
            default: number.append(character)
            }
        }
        guard flush(), total > 0 else { return nil }
        return total.rounded(2)
    }

    private var hasOperator: Bool { expression.contains("+") || expression.contains("−") }

    private func press(_ key: String) {
        switch key {
        case "⌫":
            if !expression.isEmpty { expression.removeLast() }
        case "+", "−":
            guard let last = expression.last, last != "+", last != "−", last != "." else { return }
            expression.append(key)
        case ".":
            let current = expression.split(whereSeparator: { $0 == "+" || $0 == "−" }).last.map(String.init) ?? ""
            if expression.isEmpty || expression.last == "+" || expression.last == "−" { expression += "0." }
            else if !current.contains(".") { expression.append(".") }
        default:
            let current = expression.split(whereSeparator: { $0 == "+" || $0 == "−" }).last.map(String.init) ?? ""
            if let dot = current.firstIndex(of: "."), current.distance(from: dot, to: current.endIndex) > 2 { return }
            if current == "0" { expression.removeLast() }
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
                Button(tr("Cancel")) { dismiss() }
                    .foregroundStyle(DS.textSecondary)
                Spacer()
                CapsuleSwitch(options: Self.kinds, selection: $kind) { $0.displayName }
                Spacer()
                Button(tr("More")) { showsMore = true }
                    .foregroundStyle(DS.textSecondary)
            }
            .font(.system(size: 15, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

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
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(categories, id: \.self) { name in
                        categoryCell(name, selected: category == name, size: 46) {
                            if category == name { category = ""; subcategory = "" }
                            else { category = name; subcategory = "" }
                        }
                    }
                }
                let subs = category.isEmpty ? [] : subcategories(of: category)
                if !subs.isEmpty {
                    Text(CategoryName.label(category))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.textSecondary)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(subs, id: \.self) { name in
                            categoryCell(name, selected: subcategory == name, size: 38) {
                                subcategory = subcategory == name ? "" : name
                            }
                        }
                    }
                }
                if categories.isEmpty {
                    Text(tr("Categories you use appear here. Tap More to type a new one."))
                        .font(DS.caption)
                        .foregroundStyle(DS.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func categoryCell(_ name: String, selected: Bool, size: CGFloat,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                CategoryIcon(name: name, kind: kind, size: size)
                    .overlay(Circle().strokeBorder(selected ? DS.accentText : .clear, lineWidth: 2.5))
                Text(CategoryName.label(name))
                    .font(.system(size: 11, weight: selected ? .bold : .medium))
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
            HStack(alignment: .firstTextBaseline) {
                TextField(tr("Note"), text: $note)
                    .font(.system(size: 15))
                    .foregroundStyle(DS.textPrimary)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 0) {
                    if hasOperator {
                        Text(expression)
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(DS.textTertiary)
                            .lineLimit(1)
                    }
                    Text(amount.map { NSDecimalNumber(decimal: $0).stringValue } ?? (expression.isEmpty ? "0" : expression))
                        .font(DS.money(30, weight: .bold))
                        .foregroundStyle(kind == .income ? FlowPalette.income : DS.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
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
                Button { showsDate.toggle() } label: {
                    chip(icon: "calendar", text: Calendar.current.isDateInToday(date)
                         ? tr("Today") : Fmt.dateMedium.string(from: date))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            if showsDate {
                DatePicker("", selection: $date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            keypad
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(DS.panel)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
    }

    private func chip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 13, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(DS.textSecondary)
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(DS.tile)
        .clipShape(Capsule())
    }

    private var keypad: some View {
        let rows = [["1", "2", "3", "⌫"], ["4", "5", "6", "+"], ["7", "8", "9", "−"], [".", "0", "00", "✓"]]
        return VStack(spacing: 8) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { key in
                        keyButton(key)
                    }
                }
            }
        }
    }

    private func keyButton(_ key: String) -> some View {
        let isSave = key == "✓"
        return Button {
            if isSave { save() }
            else if key == "00" { press("0"); press("0") }
            else { press(key) }
        } label: {
            Group {
                if key == "⌫" {
                    Image(systemName: "delete.left")
                } else if isSave {
                    Text(hasOperator ? "=" : tr("Save"))
                } else {
                    Text(key)
                }
            }
            .font(.system(size: isSave ? 17 : 22, weight: isSave ? .bold : .medium).monospacedDigit())
            .foregroundStyle(isSave ? DS.ink : DS.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(isSave ? (canSave || hasOperator ? DS.accent : DS.tile) : DS.tile)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func save() {
        // "=" first collapses the sum; a second tap saves.
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
                                 account: account,
                                 transferAccount: kind == .transfer ? accounts.first { $0.id == transferAccountID } : nil)
        context.insert(record)
        try? context.save()
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        dismiss()
    }
}
