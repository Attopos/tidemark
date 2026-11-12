import SwiftUI
import SwiftData

// MARK: - Accounts — where the cash is
//
// Laid out like a bookkeeping app's asset page: net assets on top (what you
// hold minus what you owe), money lent out and borrowed beside it, then the
// accounts in groups — funds, credit cards, prepaid cards, money owed to you,
// money you owe — each with its own total and collapsible. A row shows the
// account's description, card number and type; a credit card shows what is
// owed, the credit left and the days to its statement. Balances are the
// opening balance plus every record that touched the account; Reconcile sets
// them to what the bank shows. Investment and crypto accounts live on the
// Portfolio page, not here.

struct AccountsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query private var rates: [CurrencyRate]

    @State private var selectedID: UUID?
    @State private var editingAccount: Account?
    @State private var creating = false
    @State private var editingRecord: Transaction?
    @State private var showArchived = false
    @State private var reconciling = false
    /// Groups folded shut (remembered).
    @AppStorage("collapsedAccountGroups") private var collapsedRaw = ""

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }

    private func toggle(_ group: AccountGroup) {
        var set = collapsed
        if set.contains(group.rawValue) { set.remove(group.rawValue) } else { set.insert(group.rawValue) }
        collapsedRaw = set.sorted().joined(separator: ",")
    }

    var body: some View {
        let snapshot = LedgerSnapshot(transactions: transactions, accounts: accounts, rates: rates,
                                      code: app.baseCurrency)
        let visible = snapshot.accounts.filter { showArchived || !$0.isArchived }

        GeometryReader { geometry in
            let wide = geometry.size.width >= 900
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if wide {
                        HStack(alignment: .top, spacing: DS.gridGap) {
                            VStack(spacing: 12) {
                                summary(snapshot)
                                groups(visible, snapshot: snapshot)
                            }
                            .frame(maxWidth: 560)
                            detail(snapshot: snapshot)
                        }
                    } else {
                        summary(snapshot)
                        groups(visible, snapshot: snapshot)
                    }
                }
                .padding(.horizontal, wide ? DS.pagePadding : 16)
                .padding(.top, wide ? 38 : 12)
                .padding(.bottom, 110)
                .frame(maxWidth: 1300, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(DS.page)
        .sheet(item: $editingAccount) { account in
            AccountEditor(account: account, currentBalance: snapshot.balances[account.id] ?? account.openingBalance)
        }
        .sheet(isPresented: $creating) { AccountEditor(account: nil, currentBalance: 0) }
        .sheet(isPresented: $reconciling) {
            ReconcileSheet(accounts: snapshot.accounts, balances: snapshot.balances)
        }
        .sheet(item: $editingRecord) { TransactionEditor(transaction: $0) }
        #if os(iOS)
        // On the phone an account opens as its own sheet.
        .sheet(item: Binding(get: { snapshot.accounts.first { $0.id == selectedID } },
                             set: { selectedID = $0?.id })) { account in
            ScrollView { accountDetail(account, snapshot: snapshot).padding(16) }
                .background(DS.page)
                .presentationDetents([.medium, .large])
        }
        #endif
    }

    // MARK: Header

    private var header: some View {
        @Bindable var app = app
        return HStack(spacing: 10) {
            Text(tr("Accounts"))
                .font(DS.title(30))
                .foregroundStyle(DS.textPrimary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 8)
            Menu {
                Button(tr("Reconcile…")) { reconciling = true }
                Toggle(tr("Show archived"), isOn: $showArchived)
            } label: {
                Text(tr("More"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(DS.tile)
                    .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button { creating = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DS.ink)
                    .frame(width: 30, height: 30)
                    .background(DS.accent)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(tr("Add account"))
        }
        .padding(.bottom, 4)
    }

    // MARK: Summary

    private func summary(_ snapshot: LedgerSnapshot) -> some View {
        @Bindable var app = app
        let net = snapshot.netAssets
        var lent: Decimal = 0
        var borrowed: Decimal = 0
        for account in snapshot.accounts where account.includeInNetWorth && !account.isArchived {
            let value = snapshot.converter.toBase(snapshot.balances[account.id] ?? 0, account.currencyCode)
            if account.group == .receivable { lent += value }
            if account.group == .payable { borrowed += -value }
        }
        return VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(tr("Net Assets"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.textSecondary)
                    Button { app.amountsHidden.toggle() } label: {
                        Image(systemName: app.amountsHidden ? "eye.slash" : "eye")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DS.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                Text(Fmt.money(net.assets - net.debts, snapshot.code))
                    .font(DS.money(30, weight: .bold))
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                HStack(spacing: 16) {
                    figure(tr("Total"), Fmt.money(net.assets, snapshot.code))
                    figure(tr("Debts"), Fmt.money(net.debts, snapshot.code))
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.panel)
            .clipShape(RoundedRectangle(cornerRadius: DS.panelRadius, style: .continuous))
            HStack(spacing: 10) {
                smallCard(tr("Total Borrowing"), Fmt.money(Swift.max(0, borrowed), snapshot.code),
                          icon: "arrow.down", tint: DS.textTertiary)
                smallCard(tr("Total Lending"), Fmt.money(Swift.max(0, lent), snapshot.code),
                          icon: "arrow.up", tint: DS.lime)
            }
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(DS.textTertiary)
            Text(value).foregroundStyle(DS.textSecondary)
        }
        .font(.system(size: 13).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private func smallCard(_ title: String, _ value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(DS.ink)
                .frame(width: 28, height: 28)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
                Text(value)
                    .font(DS.money(15, weight: .semibold))
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(DS.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Groups

    private func baseValue(_ account: Account, _ snapshot: LedgerSnapshot) -> Decimal {
        snapshot.converter.toBase(snapshot.balances[account.id] ?? 0, account.currencyCode)
    }

    @ViewBuilder
    private func groups(_ visible: [Account], snapshot: LedgerSnapshot) -> some View {
        if visible.isEmpty {
            Text(tr("No accounts yet. They are created when you import records, or add one here."))
                .font(DS.body)
                .foregroundStyle(DS.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        }
        ForEach(AccountGroup.allCases) { group in
            let members = visible.filter { $0.group == group }
                .sorted { Swift.abs(baseValue($0, snapshot).doubleValue) > Swift.abs(baseValue($1, snapshot).doubleValue) }
            if !members.isEmpty {
                let total = members.filter { $0.includeInNetWorth && !$0.isArchived }
                    .reduce(Decimal(0)) { $0 + baseValue($1, snapshot) }
                let folded = collapsed.contains(group.rawValue)
                VStack(alignment: .leading, spacing: 8) {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { toggle(group) } } label: {
                        HStack(spacing: 4) {
                            Text(group.displayName)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(DS.textPrimary)
                            Text("(\(members.count))")
                                .font(.system(size: 12.5))
                                .foregroundStyle(DS.textTertiary)
                            Spacer(minLength: 8)
                            Text("\(tr("Balance")): \(Fmt.money(total, snapshot.code))")
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(DS.textTertiary)
                                .lineLimit(1)
                            Image(systemName: folded ? "chevron.right" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DS.textTertiary)
                        }
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if !folded {
                        VStack(spacing: 0) {
                            ForEach(Array(members.enumerated()), id: \.element.id) { index, account in
                                accountRow(account, snapshot: snapshot)
                                if index < members.count - 1 {
                                    Divider().overlay(DS.border.opacity(0.5)).padding(.leading, 60)
                                }
                            }
                        }
                        .background(DS.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func subtitleLines(_ account: Account) -> [String] {
        var lines: [String] = []
        if !account.note.isEmpty { lines.append(account.note) }
        if !account.cardNumber.isEmpty { lines.append(account.cardNumber) }
        var type = account.typeLabel.isEmpty ? account.guessedTypeLabel : account.typeLabel
        if account.group == .credit, let days = account.daysToBilling() {
            type = "\(type.isEmpty ? "" : "[\(type)] ")\(trf("Billing in %d days", days))"
        }
        if !type.isEmpty { lines.append(type) }
        return lines
    }

    private func accountRow(_ account: Account, snapshot: LedgerSnapshot) -> some View {
        let selected = selectedID == account.id
        let balance = snapshot.balances[account.id] ?? 0
        let isCredit = account.group == .credit
        let owed = Swift.max(0, -balance)
        return Button { selectedID = selected ? nil : account.id } label: {
            HStack(alignment: .center, spacing: 12) {
                AccountIcon(account: account)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.name)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(DS.textPrimary)
                            .lineLimit(1)
                        if !account.includeInNetWorth { TagChip(text: tr("Not counted"), color: DS.textSecondary) }
                        if account.isArchived { TagChip(text: tr("Archived"), color: DS.textSecondary) }
                    }
                    ForEach(subtitleLines(account), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 12))
                            .foregroundStyle(DS.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.money(isCredit ? owed : balance, account.currencyCode))
                        .font(DS.money(15, weight: .semibold))
                        .foregroundStyle(!isCredit && balance < 0 ? FlowPalette.expense : DS.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                    if isCredit, let limit = account.creditLimit {
                        Text("\(tr("Avl Credit")): \(Fmt.money(limit - owed, account.currencyCode))")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(DS.textTertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(selected ? DS.tile : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(tr("Edit…")) { editingAccount = account }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(snapshot: LedgerSnapshot) -> some View {
        if let account = snapshot.accounts.first(where: { $0.id == selectedID }) {
            accountDetail(account, snapshot: snapshot)
                .frame(maxWidth: .infinity)
        } else {
            Text(tr("Select an account to see its records"))
                .font(DS.body)
                .foregroundStyle(DS.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    private func accountDetail(_ account: Account, snapshot: LedgerSnapshot) -> some View {
        let records = transactions.filter { $0.account?.id == account.id || $0.transferAccount?.id == account.id }
        return Panel(title: account.name, accessory: {
            Button(tr("Edit…")) { editingAccount = account }
                .buttonStyle(GhostButtonStyle())
        }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    StatTile(title: tr("Balance"), value: snapshot.balances[account.id] ?? 0,
                             code: account.currencyCode)
                    StatTile(title: tr("Records"), value: Decimal(records.count), code: "", isCount: true)
                }
                RecordList(transactions: records, showsDate: true, editing: $editingRecord)
            }
        }
    }
}

/// Round account badge: the first letter on the group's color.
struct AccountIcon: View {
    let account: Account
    var size: CGFloat = 36

    private var tint: Color {
        switch account.group {
        case .fund: return DS.lime
        case .credit: return DS.violet
        case .recharge: return DS.violetSoft
        case .receivable: return DS.limeSoft
        case .payable: return DS.violetDeep
        }
    }

    var body: some View {
        Text(String(account.name.prefix(1)).uppercased())
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(account.group == .payable ? Color.white : DS.ink)
            .frame(width: size, height: size)
            .background(tint)
            .clipShape(Circle())
    }
}

// MARK: - Account editor

struct AccountEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let account: Account?
    /// Balance computed from the ledger when the sheet opened.
    let currentBalance: Decimal

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

    init(account: Account?, currentBalance: Decimal) {
        self.account = account
        self.currentBalance = currentBalance
        _name = State(initialValue: account?.name ?? "")
        _group = State(initialValue: account?.group ?? .fund)
        _cardNumber = State(initialValue: account?.cardNumber ?? "")
        _typeLabel = State(initialValue: account?.typeLabel ?? "")
        _limitText = State(initialValue: account?.creditLimit.map { NSDecimalNumber(decimal: $0).stringValue } ?? "")
        _billingText = State(initialValue: account?.billingDay.map(String.init) ?? "")
        _repaymentText = State(initialValue: account?.repaymentDay.map(String.init) ?? "")
        _currency = State(initialValue: account?.currencyCode ?? "CNY")
        _balanceText = State(initialValue: NSDecimalNumber(decimal: currentBalance.rounded(2)).stringValue)
        _note = State(initialValue: account?.note ?? "")
        _counted = State(initialValue: account?.includeInNetWorth ?? true)
        _archived = State(initialValue: account?.isArchived ?? false)
    }

    private var balance: Decimal? {
        Decimal(string: balanceText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ""),
                locale: Locale(identifier: "en_US_POSIX"))
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && balance != nil
            && currency.trimmingCharacters(in: .whitespaces).count >= 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(account == nil ? tr("Add account") : tr("Edit account"))
                .font(DS.title(20))
                .foregroundStyle(DS.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                CapsuleSwitch(options: AccountGroup.allCases, selection: $group) { $0.shortName }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                row(tr("Name")) { field($name) }
                row(tr("Currency")) { field($currency).frame(width: 90) }
                row(tr("Balance now")) {
                    VStack(alignment: .leading, spacing: 4) {
                        field($balanceText).signedAmountKeyboard()
                        Text(tr("Changing this moves the opening balance; records stay as they are."))
                            .font(.system(size: 11.5))
                            .foregroundStyle(DS.textTertiary)
                    }
                }
                row(tr("Description")) { field($note) }
                row(tr("Card number")) { field($cardNumber) }
                row(tr("Type")) { field($typeLabel) }
                if group == .credit {
                    row(tr("Credit limit")) { field($limitText).amountKeyboard() }
                    row(tr("Statement day")) { field($billingText).frame(width: 70) }
                    row(tr("Payment day")) { field($repaymentText).frame(width: 70) }
                }
                row("") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(tr("Count in net worth"), isOn: $counted)
                        Toggle(tr("Archived"), isOn: $archived)
                    }
                    .toggleStyle(LimeCheckboxStyle())
                    .foregroundStyle(DS.textSecondary)
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
        .editorSheet(width: 440)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow(alignment: .top) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(DS.textSecondary)
                .frame(width: 96, alignment: .leading)
                .padding(.top, 6)
            content()
        }
    }

    private func field(_ text: Binding<String>) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(DS.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(DS.tile)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func save() {
        guard let balance else { return }
        let code = currency.trimmingCharacters(in: .whitespaces).uppercased()
        let target = account ?? Account(name: name, kind: group.kind, currencyCode: code)
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.group = group
        target.kind = group == .fund && account?.kind == .cash ? .cash : group.kind
        target.cardNumber = cardNumber.trimmingCharacters(in: .whitespaces)
        target.typeLabel = typeLabel.trimmingCharacters(in: .whitespaces)
        func day(_ text: String) -> Int? { Int(text.trimmingCharacters(in: .whitespaces)).flatMap { (1...31).contains($0) ? $0 : nil } }
        target.creditLimit = group == .credit
            ? Decimal(string: limitText.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX"))
            : nil
        target.billingDay = group == .credit ? day(billingText) : nil
        target.repaymentDay = group == .credit ? day(repaymentText) : nil
        target.currencyCode = code
        target.note = note
        target.includeInNetWorth = counted
        target.isArchived = archived
        target.updatedAt = Date()
        // Opening balance absorbs the difference, so the ledger keeps adding up.
        target.openingBalance += balance - currentBalance.rounded(2)
        if account == nil { context.insert(target) }
        try? context.save()
        dismiss()
    }
}

// MARK: - Reconcile
//
// All accounts in one table: type the balance each one really has today and
// tick the ones that no longer exist. Used once after importing records from
// another app (an export carries the records but not the balances), and
// whenever the ledger has drifted from the bank.

struct ReconcileSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let accounts: [Account]
    let balances: [UUID: Decimal]

    @State private var texts: [UUID: String] = [:]
    @State private var archived: Set<UUID> = []

    private static func parse(_ text: String) -> Decimal? {
        Decimal(string: text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ""),
                locale: Locale(identifier: "en_US_POSIX"))
    }

    private func computed(_ account: Account) -> Decimal { (balances[account.id] ?? 0).rounded(2) }

    private var valid: Bool {
        accounts.allSatisfy { Self.parse(texts[$0.id] ?? "") != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Reconcile accounts"))
                .font(DS.title(20))
                .foregroundStyle(DS.textPrimary)
            Text(tr("Enter what each account really holds today. The difference goes into its opening balance; records are not touched. Archived accounts leave the totals but keep their records."))
                .font(DS.caption)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                // Name on its own line, so long account names are never cut
                // to make room for the figures (the sheet is narrow on a phone).
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(accounts) { account in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(account.name) · \(account.currencyCode)")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(DS.textPrimary)
                                .lineLimit(1)
                            HStack(spacing: 10) {
                                Text("\(tr("Ledger says")) \(Fmt.money(computed(account), account.currencyCode))")
                                    .font(.system(size: 12.5).monospacedDigit())
                                    .foregroundStyle(DS.textSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                Spacer(minLength: 4)
                                TextField("", text: Binding(get: { texts[account.id] ?? "" },
                                                            set: { texts[account.id] = $0 }))
                                    .textFieldStyle(.plain)
                                    .signedAmountKeyboard()
                                    .font(.system(size: 14).monospacedDigit())
                                    .foregroundStyle(DS.textPrimary)
                                    .padding(.horizontal, 9)
                                    .frame(width: 120, height: 30)
                                    .background(DS.tile)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                Toggle(tr("Archived"), isOn: Binding(
                                    get: { archived.contains(account.id) },
                                    set: { if $0 { archived.insert(account.id) } else { archived.remove(account.id) } }))
                                    .toggleStyle(LimeCheckboxStyle())
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(DS.textSecondary)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(maxHeight: 460)
            HStack {
                Spacer()
                Button(tr("Cancel")) { dismiss() }
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(tr("Save")) { save() }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
                    .opacity(valid ? 1 : 0.45)
            }
        }
        .editorSheet(width: 600)
        .onAppear {
            for account in accounts {
                texts[account.id] = NSDecimalNumber(decimal: computed(account)).stringValue
                if account.isArchived { archived.insert(account.id) }
            }
        }
    }

    private func save() {
        for account in accounts {
            guard let actual = Self.parse(texts[account.id] ?? "") else { continue }
            let difference = actual - computed(account)
            let isArchived = archived.contains(account.id)
            guard difference != 0 || isArchived != account.isArchived else { continue }
            account.openingBalance += difference
            account.isArchived = isArchived
            account.updatedAt = Date()
        }
        try? context.save()
        dismiss()
    }
}
