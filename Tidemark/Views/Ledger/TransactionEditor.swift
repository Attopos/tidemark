import SwiftUI
import SwiftData

// MARK: - Record editor
//
// One sheet for adding and editing a record. Categories are free text with a
// menu of the ones already in use for that kind, so the list grows with the
// ledger instead of being configured up front.

struct TransactionEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.createdAt) private var allAccounts: [Account]
    @Query private var transactions: [Transaction]

    let transaction: Transaction?

    private static let kinds: [TransactionKind] = [.expense, .income, .transfer, .liabilityPayment]

    @State private var kind: TransactionKind
    @State private var amountText: String
    @State private var currency: String
    @State private var category: String
    @State private var subcategory: String
    @State private var accountID: UUID?
    @State private var transferAccountID: UUID?
    @State private var arrivalText: String
    @State private var date: Date
    @State private var note: String
    @State private var tags: String
    @State private var refundText: String
    @State private var excluded: Bool
    @FocusState private var amountFocused: Bool

    init(transaction: Transaction?, defaultDate: Date? = nil) {
        self.transaction = transaction
        let text: (Decimal) -> String = { $0 == 0 ? "" : NSDecimalNumber(decimal: $0).stringValue }
        _kind = State(initialValue: transaction?.kind ?? .expense)
        _amountText = State(initialValue: transaction.map { text($0.amount) } ?? "")
        _currency = State(initialValue: transaction?.currencyCode ?? "")
        _category = State(initialValue: transaction?.category ?? "")
        _subcategory = State(initialValue: transaction?.subcategory ?? "")
        _accountID = State(initialValue: transaction?.account?.id)
        _transferAccountID = State(initialValue: transaction?.transferAccount?.id)
        _arrivalText = State(initialValue: transaction?.transferAmount.map(text) ?? "")
        // A new record on a past day keeps the current time of day.
        var initialDate = Date()
        if let defaultDate, !Calendar.current.isDateInToday(defaultDate) {
            let time = Calendar.current.dateComponents([.hour, .minute], from: Date())
            initialDate = Calendar.current.date(bySettingHour: time.hour ?? 12, minute: time.minute ?? 0,
                                                second: 0, of: defaultDate) ?? defaultDate
        }
        _date = State(initialValue: transaction?.date ?? initialDate)
        _note = State(initialValue: transaction?.note ?? "")
        _tags = State(initialValue: transaction?.tags ?? "")
        _refundText = State(initialValue: transaction.map { text($0.refundAmount) } ?? "")
        _excluded = State(initialValue: transaction?.excludeFromStats ?? false)
    }

    private var accounts: [Account] { allAccounts.filter { $0.isLedgerAccount && !$0.isArchived } }
    private var isFlow: Bool { kind == .expense || kind == .income }
    private var amount: Decimal? { Self.decimal(amountText) }

    private static func decimal(_ text: String) -> Decimal? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty, let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")),
              value >= 0 else { return nil }
        return value
    }

    private var resolvedCurrency: String {
        let typed = currency.trimmingCharacters(in: .whitespaces).uppercased()
        if !typed.isEmpty { return typed }
        return accounts.first { $0.id == accountID }?.currencyCode ?? "CNY"
    }

    private var canSave: Bool {
        guard let amount, amount > 0 else { return false }
        if isFlow { return true }
        return accountID != nil || transferAccountID != nil
    }

    /// Names already used for this kind, most used first.
    private func suggestions(_ keyPath: KeyPath<Transaction, String>, within parent: String? = nil) -> [String] {
        var counts: [String: Int] = [:]
        for item in transactions where item.kind == kind {
            if let parent, item.category != parent { continue }
            let name = item[keyPath: keyPath]
            if !name.isEmpty { counts[name, default: 0] += 1 }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(transaction == nil ? tr("Add record") : tr("Edit record"))
                .font(DS.title(20))
                .foregroundStyle(DS.textPrimary)

            CapsuleSwitch(options: Self.kinds, selection: $kind) { $0.displayName }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    label(tr("Amount"))
                    HStack(spacing: 8) {
                        field(tr("0.00"), text: $amountText)
                            .amountKeyboard()
                            .focused($amountFocused)
                        field(resolvedCurrency, text: $currency).frame(width: 70)
                    }
                }
                if isFlow {
                    GridRow {
                        label(tr("Category"))
                        HStack(spacing: 8) {
                            suggestField(tr("Category"), text: $category, options: suggestions(\.category))
                            suggestField(tr("Subcategory"), text: $subcategory,
                                         options: suggestions(\.subcategory, within: category))
                        }
                    }
                }
                GridRow {
                    label(isFlow ? tr("Account") : tr("From"))
                    accountPicker($accountID)
                }
                if !isFlow {
                    GridRow {
                        label(tr("To"))
                        accountPicker($transferAccountID)
                    }
                    GridRow {
                        label(tr("Arrives as"))
                        field(tr("Same amount, converted"), text: $arrivalText)
                    }
                }
                GridRow {
                    label(tr("Date"))
                    DatePicker("", selection: $date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }
                GridRow {
                    label(tr("Note"))
                    field("", text: $note)
                }
                GridRow {
                    label(tr("Tags"))
                    field("", text: $tags)
                }
                if kind == .expense {
                    GridRow {
                        label(tr("Refund"))
                        field(tr("0.00"), text: $refundText)
                    }
                }
                if isFlow {
                    GridRow {
                        label("")
                        Toggle(tr("Leave out of statistics"), isOn: $excluded)
                            .toggleStyle(LimeCheckboxStyle())
                            .foregroundStyle(DS.textSecondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button(tr("Cancel")) { dismiss() }
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(tr("Save")) { save() }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.45)
            }
        }
        .editorSheet(width: 460)
        // A new record starts at the amount, keypad up.
        .onAppear { if transaction == nil { amountFocused = true } }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(DS.textSecondary)
            .frame(width: 78, alignment: .leading)
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(DS.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(DS.tile)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func suggestField(_ placeholder: String, text: Binding<String>, options: [String]) -> some View {
        HStack(spacing: 0) {
            field(placeholder, text: text)
            if !options.isEmpty {
                Menu {
                    ForEach(options, id: \.self) { option in
                        Button(option) { text.wrappedValue = option }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26)
            }
        }
    }

    private func accountPicker(_ selection: Binding<UUID?>) -> some View {
        Picker("", selection: selection) {
            Text("—").tag(UUID?.none)
            ForEach(accounts) { account in
                Text("\(account.name) · \(account.currencyCode)").tag(Optional(account.id))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .tint(DS.textPrimary)
    }

    private func save() {
        guard let amount else { return }
        let target = transaction ?? Transaction(date: date, kind: kind, amount: amount)
        target.kind = kind
        target.date = date
        target.amount = amount
        target.currencyCode = resolvedCurrency
        target.account = accounts.first { $0.id == accountID }
        target.note = note
        target.tags = tags.trimmingCharacters(in: .whitespaces)
        target.updatedAt = Date()
        if isFlow {
            target.category = category.trimmingCharacters(in: .whitespaces)
            target.subcategory = subcategory.trimmingCharacters(in: .whitespaces)
            target.transferAccount = nil
            target.transferAmount = nil
            target.refundAmount = kind == .expense ? min(Self.decimal(refundText) ?? 0, amount) : 0
            target.excludeFromStats = excluded
        } else {
            // Keep an imported label ("Lend", "Recharge"…) unless the kind changed.
            if transaction?.kind != kind || target.category.isEmpty {
                target.category = kind == .liabilityPayment ? "Repayment" : "Transfer"
            }
            target.subcategory = ""
            target.transferAccount = accounts.first { $0.id == transferAccountID }
            target.transferAmount = Self.decimal(arrivalText)
            target.refundAmount = 0
            target.excludeFromStats = false
        }
        if transaction == nil { context.insert(target) }
        try? context.save()
        dismiss()
    }
}
