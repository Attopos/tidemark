import SwiftUI
import SwiftData

struct AccountTypePreset: Identifiable, Hashable {
    let label: String
    let group: AccountGroup
    var kind: AccountKind? = nil
    let brand: AccountBrand
    var asksCardNumber = false

    var id: String { label }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.label == rhs.label }
    func hash(into hasher: inout Hasher) { hasher.combine(label) }

    static let all: [AccountTypePreset] = [
        .init(label: "Cash", group: .fund, kind: .cash, brand: .symbol("wallet.bifold.fill", color: 0xF5B83D)),
        .init(label: "Debit Card", group: .fund, brand: .symbol("creditcard.fill", color: 0xF5B83D), asksCardNumber: true),
        .init(label: "Alipay", group: .fund, brand: .glyph("acct-alipay", color: 0x1677FF)),
        .init(label: "Yu'E Bao", group: .fund, brand: .glyph("acct-alipay", color: 0xFF6A00)),
        .init(label: "WeChat Wallet", group: .fund, brand: .glyph("acct-wechat", color: 0x07C160)),
        .init(label: "PayPal", group: .fund, brand: .glyph("acct-paypal", color: 0x003087)),
        .init(label: "Wise", group: .fund, brand: .glyph("acct-wise", color: 0x163300)),
        .init(label: "Revolut", group: .fund, brand: .glyph("acct-revolut", color: 0x0075EB)),
        .init(label: "Credit Card", group: .credit, brand: .symbol("creditcard.fill", color: 0x7E5FE6), asksCardNumber: true),
        .init(label: "Huabei", group: .credit, brand: .glyph("acct-alipay", color: 0x1677FF)),
        .init(label: "Visa", group: .credit, brand: .glyph("acct-visa", color: 0x1A1F71), asksCardNumber: true),
        .init(label: "Mastercard", group: .credit, brand: .mastercard, asksCardNumber: true),
        .init(label: "Membership Card", group: .recharge, brand: .symbol("person.text.rectangle.fill", color: 0xE07A2F)),
        .init(label: "Transit Card", group: .recharge, brand: .symbol("tram.fill", color: 0x2E8BFF)),
        .init(label: "Lend", group: .receivable, brand: .symbol("arrow.up.right", color: 0x9CB84A)),
        .init(label: "Borrow", group: .payable, brand: .symbol("arrow.down.left", color: 0x7458E0)),
    ]
}

struct AccountEditor: View {
    let account: Account?
    let currentBalance: Decimal
    @State private var path: [AccountTypePreset] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let account {
                AccountForm(account: account, preset: nil, currentBalance: currentBalance)
            } else {
                NavigationStack(path: $path) {
                    AccountTypePicker()
                        .navigationDestination(for: AccountTypePreset.self) { preset in
                            AccountForm(account: nil, preset: preset, currentBalance: 0) { dismiss() }
                        }
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 660)
        #endif
        #if os(iOS) && DEBUG
        .onReceive(NotificationCenter.default.publisher(for: PerfProbe.pushAccountType)) { _ in
            path = [AccountTypePreset.all[1]]
        }
        #endif
    }
}

private struct SheetHeader<Trailing: View>: View {
    let title: String
    var back: Bool
    @ViewBuilder var trailing: Trailing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(DS.textPrimary)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: back ? "chevron.left" : "xmark")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(DS.textPrimary)
                        .frame(width: 40, height: 40)
                        .background(DS.tile)
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr(back ? "Back" : "Close"))
                Spacer()
                trailing
            }
        }
        .padding(.horizontal, AccountForm.margin)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

struct AccountTypePicker: View {
    @State private var folded: Set<AccountGroup> = []

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: tr("Choose Type"), back: false) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(AccountGroup.allCases) { group in
                        let presets = AccountTypePreset.all.filter { $0.group == group }
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if folded.contains(group) { folded.remove(group) } else { folded.insert(group) }
                            }
                        } label: {
                            HStack {
                                Text(group.displayName)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(DS.textPrimary)
                                Spacer()
                                Image(systemName: folded.contains(group) ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(DS.textTertiary)
                            }
                            .padding(.top, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if !folded.contains(group) {
                            VStack(spacing: 0) {
                                ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                                    NavigationLink(value: preset) {
                                        HStack(spacing: 14) {
                                            AccountBrandBadge(brand: preset.brand, size: 38)
                                            Text(tr(preset.label))
                                                .font(.system(size: 16, weight: .medium))
                                                .foregroundStyle(DS.textPrimary)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 12, weight: .regular))
                                                .foregroundStyle(DS.textTertiary)
                                        }
                                        .padding(.horizontal, 18)
                                        .padding(.vertical, 12)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    if index < presets.count - 1 {
                                        Divider().overlay(DS.border.opacity(0.5)).padding(.leading, 70)
                                    }
                                }
                            }
                            .background(DS.panel)
                            .clipShape(RoundedRectangle(cornerRadius: DS.panelRadius, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, AccountForm.margin)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .background(DS.page)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }
}

struct AccountForm: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allAccounts: [Account]

    let account: Account?
    let preset: AccountTypePreset?
    let currentBalance: Decimal
    let onSaved: (() -> Void)?

    static var margin: CGFloat {
        #if os(iOS)
        DS.phoneMargin
        #else
        22
        #endif
    }

    private static var currencies: [String] {
        let first = ["CNY", "USD", "EUR", "HKD", "JPY", "GBP"]
        return first + Fmt.currencySymbols.keys.filter { !first.contains($0) }.sorted()
    }

    @State private var name: String
    @State private var group: AccountGroup
    @State private var cardNumber: String
    @State private var typeLabel: String
    @State private var limitText: String
    @State private var billingText: String
    @State private var repaymentText: String
    @State private var currency: String
    @State private var balanceText: String
    @State private var note: String
    @State private var counted: Bool
    @State private var archived: Bool

    init(account: Account?, preset: AccountTypePreset?, currentBalance: Decimal, onSaved: (() -> Void)? = nil) {
        self.onSaved = onSaved
        self.account = account
        self.preset = preset
        self.currentBalance = currentBalance
        let group = account?.group ?? preset?.group ?? .fund
        _name = State(initialValue: account?.name ?? "")
        _group = State(initialValue: group)
        _cardNumber = State(initialValue: account?.cardNumber ?? "")
        _typeLabel = State(initialValue: account?.typeLabel ?? preset.map { tr($0.label) } ?? "")
        _limitText = State(initialValue: account?.creditLimit.map { NSDecimalNumber(decimal: $0).stringValue } ?? "")
        _billingText = State(initialValue: account?.billingDay.map(String.init) ?? "")
        _repaymentText = State(initialValue: account?.repaymentDay.map(String.init) ?? "")
        _currency = State(initialValue: account?.currencyCode ?? "CNY")
        let owes = group == .credit || group == .payable
        let shown = (owes ? -currentBalance : currentBalance).rounded(2)
        _balanceText = State(initialValue: account == nil ? "" : NSDecimalNumber(decimal: shown).stringValue)
        _note = State(initialValue: account?.note ?? "")
        _counted = State(initialValue: account?.includeInNetWorth ?? true)
        _archived = State(initialValue: account?.isArchived ?? false)
    }

    private var owes: Bool { group == .credit || group == .payable }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var nameTaken: Bool {
        allAccounts.contains {
            $0.id != account?.id && $0.name.trimmingCharacters(in: .whitespaces).lowercased() == trimmedName.lowercased()
        }
    }

    private var resolvedKind: AccountKind {
        if let kind = preset?.kind { return kind }
        guard group == .fund else { return group.kind }
        let text = "\(name) \(typeLabel)".lowercased()
        if account?.kind == .cash || text.contains("cash") || text.contains("现金") { return .cash }
        return .payment
    }

    private var badge: AccountBrand {
        AccountBrand.match(name: trimmedName, typeLabel: typeLabel, currency: currency, isCash: resolvedKind == .cash)
            ?? preset?.brand ?? .symbol("building.columns.fill", color: 0x6B6C70)
    }

    private var balance: Decimal? {
        let text = balanceText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        if text.isEmpty { return 0 }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    private var canSave: Bool { !trimmedName.isEmpty && !nameTaken && balance != nil }

    private var showsCardNumber: Bool {
        preset?.asksCardNumber ?? true || !cardNumber.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: account == nil ? tr("Add account") : tr("Edit account"), back: account == nil) {
                Button { save() } label: {
                    Text(tr("Save"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(canSave ? DS.ink : DS.textTertiary)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(canSave ? DS.accent : DS.tile)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(spacing: 10) {
                        AccountBrandBadge(brand: badge, size: 64)
                        Text(typeLabel.isEmpty ? group.displayName : typeLabel)
                            .font(.system(size: 14))
                            .foregroundStyle(DS.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)

                    card {
                        textRow(tr("Name"), text: $name, prompt: tr("e.g. BOC, WeChat"))
                        divider
                        textRow(owes ? tr("Owed now") : tr("Balance"), text: $balanceText, prompt: "0.00", amount: true)
                        divider
                        HStack {
                            label(tr("Currency"))
                            Spacer()
                            Picker("", selection: $currency) {
                                ForEach(Self.currencies, id: \.self) { code in
                                    Text("\(code) \(Fmt.symbol(for: code).trimmingCharacters(in: .whitespaces))").tag(code)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .tint(DS.textSecondary)
                            .fixedSize()
                        }
                        .padding(.horizontal, 18)
                        .frame(minHeight: 54)
                    }
                    if nameTaken {
                        Text(tr("Another account already has this name."))
                            .font(.system(size: 13))
                            .foregroundStyle(FlowPalette.expense)
                            .padding(.leading, 18)
                    }

                    card {
                        if showsCardNumber {
                            textRow(tr("Card number"), text: $cardNumber, prompt: tr("Optional"))
                            divider
                        }
                        textRow(tr("Type"), text: $typeLabel, prompt: tr("Optional"))
                        divider
                        textRow(tr("Description"), text: $note, prompt: tr("Optional"))
                    }

                    if group == .credit {
                        card {
                            textRow(tr("Credit limit"), text: $limitText, prompt: tr("Optional"), amount: true)
                            divider
                            textRow(tr("Statement day"), text: $billingText, prompt: "1–31", amount: true)
                            divider
                            textRow(tr("Payment day"), text: $repaymentText, prompt: "1–31", amount: true)
                        }
                    }

                    card {
                        toggleRow(tr("Count in net worth"), isOn: $counted)
                        if account != nil {
                            divider
                            toggleRow(tr("Archived"), isOn: $archived)
                        }
                    }

                    if account != nil {
                        Text(tr("Changing this moves the opening balance; records stay as they are."))
                            .font(.system(size: 13))
                            .foregroundStyle(DS.textTertiary)
                            .padding(.horizontal, 18)
                    }
                }
                .padding(.horizontal, Self.margin)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .background(DS.page)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private var divider: some View {
        Divider().overlay(DS.border.opacity(0.5)).padding(.leading, 18)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(DS.panel)
            .clipShape(RoundedRectangle(cornerRadius: DS.panelRadius, style: .continuous))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16))
            .foregroundStyle(DS.textPrimary)
            .fixedSize()
    }

    private func textRow(_ title: String, text: Binding<String>, prompt: String, amount: Bool = false) -> some View {
        HStack(spacing: 14) {
            label(title)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(DS.textTertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .modifier(AmountField(on: amount))
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 54)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { label(title) }
            .toggleStyle(.switch)
            .tint(DS.accent)
            .padding(.horizontal, 18)
            .frame(minHeight: 54)
    }

    private func save() {
        guard canSave, let balance else { return }
        let target = account ?? Account(name: trimmedName, kind: resolvedKind, currencyCode: currency)
        target.name = trimmedName
        target.group = group
        target.kind = resolvedKind
        target.cardNumber = cardNumber.trimmingCharacters(in: .whitespaces)
        target.typeLabel = typeLabel.trimmingCharacters(in: .whitespaces)
        func day(_ text: String) -> Int? {
            Int(text.trimmingCharacters(in: .whitespaces)).flatMap { (1...31).contains($0) ? $0 : nil }
        }
        target.creditLimit = group == .credit
            ? Decimal(string: limitText.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX"))
            : nil
        target.billingDay = group == .credit ? day(billingText) : nil
        target.repaymentDay = group == .credit ? day(repaymentText) : nil
        target.currencyCode = currency
        target.note = note
        target.includeInNetWorth = counted
        target.isArchived = archived
        target.updatedAt = Date()
        let entered = owes ? -balance : balance
        target.openingBalance += entered - currentBalance.rounded(2)
        if account == nil { context.insert(target) }
        try? context.save()
        dismissAll()
    }

    private func dismissAll() {
        if let onSaved { onSaved() } else { dismiss() }
    }
}

private struct AmountField: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.signedAmountKeyboard() } else { content }
    }
}
