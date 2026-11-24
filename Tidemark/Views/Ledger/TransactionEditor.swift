import SwiftUI
import SwiftData

struct TransactionEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.createdAt) private var allAccounts: [Account]
    @Query private var transactions: [Transaction]
    @Query(sort: \RecordPreset.name) private var presets: [RecordPreset]

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
    @State private var refundText: String
    @State private var excluded: Bool
    @State private var claim: ClaimStatus
    @State private var claimText: String
    @State private var savedTemplate = false
    @FocusState private var amountFocused: Bool

    init(transaction: Transaction?, defaultDate: Date? = nil, draft: ReceiptDraft? = nil) {
        self.transaction = transaction
        let text: (Decimal) -> String = { $0 == 0 ? "" : NSDecimalNumber(decimal: $0).stringValue }
        _kind = State(initialValue: transaction?.kind ?? .expense)
        _amountText = State(initialValue: transaction.map { text($0.amount) } ?? "")
        _currency = State(initialValue: transaction?.currencyCode ?? "")
        _category = State(initialValue: CategoryName.label(transaction?.category ?? ""))
        _subcategory = State(initialValue: CategoryName.label(transaction?.subcategory ?? ""))
        _accountID = State(initialValue: transaction?.account?.id)
        _transferAccountID = State(initialValue: transaction?.transferAccount?.id)
        _arrivalText = State(initialValue: transaction?.transferAmount.map(text) ?? "")
        var initialDate = Date()
        if let defaultDate, !Calendar.current.isDateInToday(defaultDate) {
            let time = Calendar.current.dateComponents([.hour, .minute], from: Date())
            initialDate = Calendar.current.date(bySettingHour: time.hour ?? 12, minute: time.minute ?? 0,
                                                second: 0, of: defaultDate) ?? defaultDate
        }
        _date = State(initialValue: transaction?.date ?? initialDate)
        _note = State(initialValue: transaction?.note ?? "")
        _refundText = State(initialValue: transaction.map { text($0.refundAmount) } ?? "")
        _excluded = State(initialValue: transaction?.excludeFromStats ?? false)
        _claim = State(initialValue: transaction?.claimStatus ?? .none)
        _claimText = State(initialValue: transaction.map { text($0.claimAmount) } ?? "")
        if transaction == nil, let draft {
            _kind = State(initialValue: draft.kind)
            _amountText = State(initialValue: draft.amount.map(text) ?? "")
            _currency = State(initialValue: draft.currency ?? "")
            _category = State(initialValue: CategoryName.label(draft.category ?? ""))
            _subcategory = State(initialValue: CategoryName.label(draft.subcategory ?? ""))
            _accountID = State(initialValue: draft.accountID)
            _note = State(initialValue: draft.note ?? "")
            if let when = draft.date { _date = State(initialValue: when) }
        }
    }

    private func apply(_ preset: RecordPreset) {
        let text: (Decimal) -> String = { $0 == 0 ? "" : NSDecimalNumber(decimal: $0).stringValue }
        kind = preset.kind
        amountText = text(preset.amount)
        currency = preset.currencyCode
        category = CategoryName.label(preset.category)
        subcategory = CategoryName.label(preset.subcategory)
        accountID = preset.accountID
        transferAccountID = preset.transferAccountID
        note = preset.note
    }

    private func saveAsTemplate() {
        guard let amount else { return }
        let name = CategoryName.label(subcategory.isEmpty ? (category.isEmpty ? kind.displayName : category) : subcategory)
        let preset = RecordPreset(name: name, kind: kind, amount: amount, currencyCode: resolvedCurrency)
        preset.category = resolvedCategory
        preset.subcategory = resolvedSubcategory
        preset.accountID = accountID
        preset.transferAccountID = isFlow ? nil : transferAccountID
        preset.note = note
        context.insert(preset)
        try? context.save()
        savedTemplate = true
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

    private var resolvedCategory: String {
        CategoryName.resolve(category, among: suggestions(\.category))
    }

    private var resolvedSubcategory: String {
        CategoryName.resolve(subcategory, among: suggestions(\.subcategory, within: category))
    }

    private func suggestions(_ keyPath: KeyPath<Transaction, String>, within parent: String? = nil) -> [String] {
        var counts: [String: Int] = [:]
        for item in transactions where item.kind == kind {
            if let parent, CategoryName.label(item.category) != CategoryName.label(parent) { continue }
            let name = item[keyPath: keyPath]
            if !name.isEmpty { counts[name, default: 0] += 1 }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(transaction == nil ? tr("Add record") : tr("Edit record"))
                    .font(DS.title(20))
                    .foregroundStyle(DS.textPrimary)
                Spacer()
                let templates = presets.filter { $0.schedule == nil }
                if transaction == nil && !templates.isEmpty {
                    Menu {
                        ForEach(templates) { preset in
                            Button("\(preset.name) · \(Fmt.money(preset.amount, preset.currencyCode))") { apply(preset) }
                        }
                    } label: {
                        Label(tr("Template"), systemImage: "square.on.square")
                            .font(.system(size: 13, weight: .regular).monospacedDigit())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

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
                if kind == .expense {
                    GridRow {
                        label(tr("Refund"))
                        field(tr("0.00"), text: $refundText)
                    }
                    GridRow {
                        label(tr("Reimburse"))
                        CapsuleSwitch(options: ClaimStatus.allCases, selection: $claim) {
                            $0 == .none ? tr("No") : $0.displayName
                        }
                    }
                    if claim == .claimed {
                        GridRow {
                            label(tr("Paid back"))
                            field(amountText.isEmpty ? tr("0.00") : amountText, text: $claimText)
                        }
                    }
                }
                if isFlow {
                    GridRow {
                        label("")
                        Toggle(tr("Not counted in expense & income"), isOn: $excluded)
                            .toggleStyle(LimeCheckboxStyle())
                            .foregroundStyle(DS.textSecondary)
                    }
                }
            }

            HStack {
                Button(savedTemplate ? tr("Saved as template") : tr("Save as template")) { saveAsTemplate() }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(amount == nil || savedTemplate)
                    .opacity(amount == nil ? 0.45 : 1)
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
        .onAppear { if transaction == nil { amountFocused = true } }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13).monospacedDigit())
            .foregroundStyle(DS.textSecondary)
            .frame(width: 78, alignment: .leading)
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 14).monospacedDigit())
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
                        Button(CategoryName.label(option)) { text.wrappedValue = CategoryName.label(option) }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
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
        target.updatedAt = Date()
        if isFlow {
            target.category = resolvedCategory
            target.subcategory = resolvedSubcategory
            target.transferAccount = nil
            target.transferAmount = nil
            target.refundAmount = kind == .expense ? min(Self.decimal(refundText) ?? 0, amount) : 0
            target.excludeFromStats = excluded
            target.claimStatus = kind == .expense ? claim : .none
            target.claimAmount = target.claimStatus == .claimed
                ? min(Self.decimal(claimText) ?? (amount - target.refundAmount), amount - target.refundAmount) : 0
        } else {
            if transaction?.kind != kind || target.category.isEmpty {
                target.category = kind == .liabilityPayment ? "Repayment" : "Transfer"
            }
            target.subcategory = ""
            target.transferAccount = accounts.first { $0.id == transferAccountID }
            target.transferAmount = Self.decimal(arrivalText)
            target.refundAmount = 0
            target.excludeFromStats = false
            target.claimStatus = .none
            target.claimAmount = 0
        }
        if transaction == nil { context.insert(target) }
        try? context.save()
        dismiss()
    }
}
