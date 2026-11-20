import SwiftUI
import SwiftData

enum RecordField: String, Identifiable {
    case type, date, amount, currency, account, toAccount, arrived, remark, address, discount, refund, fee, reimbursement

    var id: String { rawValue }

    var title: String {
        switch self {
        case .type: return tr("Type")
        case .date: return tr("Date")
        case .amount: return tr("Amount")
        case .currency: return tr("Currency")
        case .account: return tr("Account")
        case .toAccount: return tr("To account")
        case .arrived: return tr("Arrived")
        case .remark: return tr("Remark")
        case .address: return tr("Address")
        case .discount: return tr("Discount")
        case .refund: return tr("Refund")
        case .fee: return tr("Fee")
        case .reimbursement: return tr("Reimbursement")
        }
    }

    var isNumber: Bool { [.amount, .arrived, .discount, .refund, .fee].contains(self) }

    #if os(iOS)
    var detents: Set<PresentationDetent> {
        switch self {
        case .type, .currency, .account, .toAccount: return [.medium, .large]
        case .date: return [.height(560)]
        case .reimbursement: return [.height(300)]
        default: return [.height(230)]
        }
    }
    #endif
}

/// One field of a record, edited on its own from the details page.
struct RecordFieldEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var transaction: Transaction
    let field: RecordField

    @State private var text = ""
    @State private var date = Date()
    @State private var claim: ClaimStatus = .none
    @State private var claimText = ""
    @State private var kind: TransactionKind = .expense
    @State private var expanded = ""
    @FocusState private var focused: Bool

    private static let posix = Locale(identifier: "en_US_POSIX")

    private static func decimal(_ text: String) -> Decimal? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty, let value = Decimal(string: cleaned, locale: posix), value >= 0 else { return nil }
        return value
    }

    private static func string(_ value: Decimal?) -> String {
        guard let value, value != 0 else { return "" }
        return NSDecimalNumber(decimal: value).stringValue
    }

    private var needsSave: Bool {
        [.date, .reimbursement, .remark, .address].contains(field) || field.isNumber
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(DS.page)
        #if os(macOS)
        .frame(width: 420, height: field.isNumber || field == .remark || field == .address ? 200 : 520)
        #endif
        .onAppear(perform: load)
    }

    private var header: some View {
        ZStack {
            Text(field.title)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(DS.textPrimary)
            HStack {
                Button(tr("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if needsSave {
                    Button(tr("Done")) { save() }
                        .fontWeight(.medium)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }
            .font(.system(size: 16))
            .foregroundStyle(DS.accentText)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    @ViewBuilder private var content: some View {
        switch field {
        case .amount, .arrived, .discount, .refund, .fee:
            inputField(placeholder: "0.00", number: true)
        case .remark, .address:
            inputField(placeholder: field.title, number: false)
        case .date:
            VStack(spacing: 12) {
                DatePicker("", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                DatePicker(tr("Time"), selection: $date, displayedComponents: .hourAndMinute)
                    .foregroundStyle(DS.textPrimary)
            }
            .tint(DS.accentText)
            .padding(.horizontal, 20)
        case .currency:
            choiceList(Self.currencies, selected: transaction.currencyCode) { code in
                let name = L10n.current.locale.localizedString(forCurrencyCode: code) ?? code
                return name == code ? code : "\(name) (\(code))"
            } choose: { code in
                transaction.currencyCode = code
                commit()
            }
        case .account, .toAccount:
            AccountPickerList(selected: field == .account ? transaction.account?.id : transaction.transferAccount?.id) { account in
                if field == .account { transaction.account = account } else { transaction.transferAccount = account }
                commit()
            }
        case .type:
            typePicker
        case .reimbursement:
            VStack(alignment: .leading, spacing: 14) {
                Picker("", selection: $claim) {
                    ForEach(ClaimStatus.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if claim == .claimed {
                    TextField(tr("Paid back"), text: $claimText)
                        .amountKeyboard()
                        .font(DS.money(22))
                        .padding(.horizontal, 16)
                        .frame(height: 52)
                        .background(DS.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func inputField(placeholder: String, number: Bool) -> some View {
        TextField(placeholder, text: $text, axis: number ? .horizontal : .vertical)
            .textFieldStyle(.plain)
            .font(number ? DS.money(26) : .system(size: 17))
            .foregroundStyle(DS.textPrimary)
            .lineLimit(1...4)
            .focused($focused)
            .modifier(NumberPad(on: number))
            .onSubmit { if canSave { save() } }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(DS.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 20)
    }

    private func choiceList(_ options: [String], selected: String, label: @escaping (String) -> String,
                            choose: @escaping (String) -> Void) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(options, id: \.self) { option in
                    Button { choose(option) } label: {
                        HStack {
                            Text(label(option)).foregroundStyle(DS.textPrimary)
                            Spacer()
                            if option == selected {
                                Image(systemName: "checkmark").foregroundStyle(DS.accentText)
                            }
                        }
                        .font(.system(size: 16))
                        .padding(.horizontal, 18)
                        .frame(height: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(DS.border.opacity(0.5)).padding(.leading, 18)
                }
            }
            .background(DS.panel)
            .clipShape(RoundedRectangle(cornerRadius: DS.panelRadius, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Type

    private var typePicker: some View {
        let stats = EntryStats.latest ?? EntryStats.load(context)
        let names = stats.categories[kind] ?? []
        return VStack(spacing: 12) {
            Picker("", selection: $kind) {
                Text(TransactionKind.expense.displayName).tag(TransactionKind.expense)
                Text(TransactionKind.income.displayName).tag(TransactionKind.income)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(names, id: \.self) { name in
                        let subs = stats.subcategories[kind]?[name] ?? []
                        categoryRow(name, selected: transaction.kind == kind && transaction.category == name,
                                    hasChildren: !subs.isEmpty, open: expanded == name) {
                            if subs.isEmpty { choose(name, "") }
                            else { withAnimation(.snappy(duration: 0.2)) { expanded = expanded == name ? "" : name } }
                        }
                        if expanded == name {
                            categoryRow(name, label: tr("No subcategory"), indent: true,
                                        selected: transaction.kind == kind && transaction.category == name
                                            && transaction.subcategory.isEmpty) { choose(name, "") }
                            ForEach(subs, id: \.self) { sub in
                                categoryRow(sub, indent: true,
                                            selected: transaction.kind == kind && transaction.category == name
                                                && transaction.subcategory == sub) { choose(name, sub) }
                            }
                        }
                        Divider().overlay(DS.border.opacity(0.5)).padding(.leading, 18)
                    }
                }
                .background(DS.panel)
                .clipShape(RoundedRectangle(cornerRadius: DS.panelRadius, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func categoryRow(_ name: String, label: String? = nil, indent: Bool = false, selected: Bool,
                             hasChildren: Bool = false, open: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if label == nil {
                    CategoryIcon(name: name, kind: kind, size: indent ? 28 : 32)
                }
                Text(label ?? CategoryName.label(name))
                    .font(.system(size: 16))
                    .foregroundStyle(label == nil ? DS.textPrimary : DS.textSecondary)
                Spacer()
                if selected && !hasChildren {
                    Image(systemName: "checkmark").foregroundStyle(DS.accentText)
                } else if hasChildren {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? DS.accentText : DS.textTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
            }
            .padding(.leading, indent ? 44 : 18)
            .padding(.trailing, 18)
            .frame(height: indent ? 46 : 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func choose(_ category: String, _ subcategory: String) {
        if transaction.kind != kind {
            transaction.kind = kind
            if kind != .expense {
                transaction.refundAmount = 0
                transaction.claimStatus = .none
                transaction.claimAmount = 0
            }
        }
        transaction.category = category
        transaction.subcategory = subcategory
        commit()
    }

    // MARK: Load & save

    private static var currencies: [String] {
        let first = ["CNY", "USD", "EUR", "HKD", "JPY", "GBP"]
        return first + Fmt.currencySymbols.keys.filter { !first.contains($0) }.sorted()
    }

    private func load() {
        kind = transaction.kind == .income ? .income : .expense
        expanded = transaction.subcategory.isEmpty ? "" : transaction.category
        date = transaction.date
        claim = transaction.claimStatus
        claimText = Self.string(transaction.claimAmount)
        switch field {
        case .amount: text = Self.string(transaction.amount)
        case .arrived: text = Self.string(transaction.transferAmount)
        case .discount: text = Self.string(transaction.discountAmount)
        case .refund: text = Self.string(transaction.refundAmount)
        case .fee: text = Self.string(transaction.feeAmount)
        case .remark: text = transaction.note
        case .address: text = transaction.address
        default: break
        }
        if field.isNumber || field == .remark || field == .address {
            Task { @MainActor in focused = true }
        }
    }

    private var canSave: Bool {
        switch field {
        case .amount: return (Self.decimal(text) ?? 0) > 0
        case .discount, .refund, .fee, .arrived: return text.isEmpty || Self.decimal(text) != nil
        default: return true
        }
    }

    private func save() {
        let value = Self.decimal(text)
        switch field {
        case .amount:
            guard let value, value > 0 else { return }
            transaction.amount = value
            transaction.refundAmount = min(transaction.refundAmount, value)
            if transaction.claimStatus == .claimed {
                transaction.claimAmount = min(transaction.claimAmount, value - transaction.refundAmount)
            }
        case .arrived: transaction.transferAmount = value
        case .discount: transaction.discountAmount = value ?? 0
        case .refund: transaction.refundAmount = min(value ?? 0, transaction.amount)
        case .fee: transaction.feeAmount = value ?? 0
        case .remark: transaction.note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .address: transaction.address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .date: transaction.date = date
        case .reimbursement:
            transaction.claimStatus = claim
            let rest = transaction.amount - transaction.refundAmount
            transaction.claimAmount = claim == .claimed ? min(Self.decimal(claimText) ?? rest, rest) : 0
        default: break
        }
        commit()
    }

    private func commit() {
        transaction.updatedAt = Date()
        try? context.save()
        dismiss()
    }
}

private struct NumberPad: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.amountKeyboard() } else { content }
    }
}

/// Ledger accounts with their icons, for picking one.
struct AccountPickerList: View {
    @Query(sort: \Account.createdAt) private var allAccounts: [Account]
    let selected: UUID?
    let choose: (Account) -> Void

    private var accounts: [Account] { allAccounts.filter { $0.isLedgerAccount && !$0.isArchived } }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(accounts) { account in
                    Button { choose(account) } label: {
                        HStack(spacing: 12) {
                            AccountIcon(account: account, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name)
                                    .font(.system(size: 16))
                                    .foregroundStyle(DS.textPrimary)
                                let type = account.typeLabel.isEmpty ? account.guessedTypeLabel : account.typeLabel
                                Text(type.isEmpty ? account.currencyCode : "\(type) · \(account.currencyCode)")
                                    .font(.system(size: 13))
                                    .foregroundStyle(DS.textTertiary)
                            }
                            Spacer()
                            if account.id == selected {
                                Image(systemName: "checkmark").foregroundStyle(DS.accentText)
                            }
                        }
                        .padding(.horizontal, 18)
                        .frame(height: 58)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(DS.border.opacity(0.5)).padding(.leading, 62)
                }
            }
            .background(DS.panel)
            .clipShape(RoundedRectangle(cornerRadius: DS.panelRadius, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
    }
}

/// The account picker in a sheet of its own, for the entry page.
struct AccountPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let selected: UUID?
    let choose: (Account) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(DS.textPrimary)
                HStack {
                    Button(tr("Cancel")) { dismiss() }
                        .font(.system(size: 16))
                        .foregroundStyle(DS.accentText)
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)
            AccountPickerList(selected: selected) { account in
                choose(account)
                dismiss()
            }
        }
        .background(DS.page)
        #if os(macOS)
        .frame(width: 420, height: 520)
        #endif
    }
}
