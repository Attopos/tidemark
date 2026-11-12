import SwiftUI
import SwiftData

// MARK: - Accounts — where the cash is
//
// Cash-side accounts grouped by kind, each with its balance in its own
// currency. A balance is the opening balance plus every record that touched
// the account; "Set balance" re-anchors the opening balance so the computed
// figure matches what the bank shows today. Investment and crypto accounts
// are valued on the Portfolio page and appear here only as one line, so the
// two halves add up to a total net worth without double counting.

struct AccountsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query private var rates: [CurrencyRate]
    @Query private var holdings: [Holding]

    @State private var selectedID: UUID?
    @State private var editingAccount: Account?
    @State private var creating = false
    @State private var editingRecord: Transaction?
    @State private var showArchived = false
    @State private var reconciling = false

    private var portfolioVisible: Bool {
        #if os(macOS)
        app.portfolioUnlocked
        #else
        true
        #endif
    }

    private static let kindOrder: [AccountKind] = [.payment, .cash, .liability, .other]

    var body: some View {
        let snapshot = LedgerSnapshot(transactions: transactions, accounts: accounts, rates: rates,
                                      code: app.baseCurrency)
        let net = snapshot.netAssets
        let portfolio = PortfolioValuation(inputs: holdings.filter(\.isActive).map(\.valuationInput),
                                           converter: snapshot.converter).total
        let visible = snapshot.accounts.filter { showArchived || !$0.isArchived }

        GeometryReader { geometry in
            let wide = geometry.size.width >= 900
            ScrollView {
                VStack(alignment: .leading, spacing: DS.gridGap) {
                    header
                    HStack(alignment: .top, spacing: DS.gridGap) {
                        if portfolioVisible {
                            HeroFigure(title: tr("Net worth"), value: net.assets - net.debts + portfolio,
                                       code: snapshot.code,
                                       details: [(tr("Cash"), Fmt.money(net.assets - net.debts, snapshot.code)),
                                                 (tr("Portfolio"), Fmt.money(portfolio, snapshot.code))])
                        } else {
                            // The portfolio is locked: its value is not shown here either.
                            HeroFigure(title: tr("Net worth"), value: nil, code: snapshot.code,
                                       details: [(tr("Cash"), Fmt.money(net.assets - net.debts, snapshot.code)),
                                                 (tr("Portfolio"), Fmt.privacyMask)])
                        }
                        if wide {
                            HeroFigure(title: tr("Cash net assets"), value: net.assets - net.debts,
                                       code: snapshot.code,
                                       details: [(tr("Assets"), Fmt.money(net.assets, snapshot.code)), (tr("Debts"), Fmt.money(net.debts, snapshot.code))])
                        }
                    }
                    if visible.isEmpty {
                        Panel {
                            Text(tr("No accounts yet. They are created when you import records, or add one here."))
                                .font(DS.body)
                                .foregroundStyle(DS.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        }
                    } else if wide {
                        HStack(alignment: .top, spacing: DS.gridGap) {
                            accountList(visible, snapshot: snapshot)
                            detail(snapshot: snapshot)
                        }
                    } else {
                        accountList(visible, snapshot: snapshot)
                        detail(snapshot: snapshot)
                    }
                }
                .padding(.horizontal, wide ? DS.pagePadding : 20)
                .padding(.top, wide ? 38 : 24)
                .padding(.bottom, DS.pagePadding)
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
    }

    private var header: some View {
        let title = Text(tr("Accounts"))
            .font(DS.title(30))
            .foregroundStyle(DS.textPrimary)
            .lineLimit(1)
            .fixedSize()
        let controls = HStack(spacing: 12) {
            Toggle(tr("Show archived"), isOn: $showArchived)
                .toggleStyle(LimeCheckboxStyle())
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
                .fixedSize()
            Button(tr("Reconcile…")) { reconciling = true }
                .buttonStyle(GhostButtonStyle())
                .fixedSize()
            Button { creating = true } label: { Label(tr("Add account"), systemImage: "plus") }
                .buttonStyle(AccentButtonStyle())
                .fixedSize()
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { title; Spacer(minLength: 12); controls }
            VStack(alignment: .leading, spacing: 12) {
                title
                ScrollView(.horizontal, showsIndicators: false) { controls }
            }
        }
        .padding(.bottom, 6)
    }

    private func accountList(_ visible: [Account], snapshot: LedgerSnapshot) -> some View {
        VStack(spacing: DS.gridGap) {
            ForEach(Self.kindOrder, id: \.self) { kind in
                let group = visible.filter { $0.kind == kind }
                    .sorted { abs(baseValue($0, snapshot)) > abs(baseValue($1, snapshot)) }
                if !group.isEmpty {
                    let total = group.filter { $0.includeInNetWorth && !$0.isArchived }
                        .reduce(Decimal(0)) { $0 + baseValue($1, snapshot) }
                    Panel(title: "\(kind.displayName) (\(group.count))", accessory: {
                        Text(Fmt.money(total, snapshot.code))
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(DS.textSecondary)
                    }) {
                        VStack(spacing: 2) {
                            ForEach(group) { account in
                                accountRow(account, snapshot: snapshot)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func baseValue(_ account: Account, _ snapshot: LedgerSnapshot) -> Decimal {
        snapshot.converter.toBase(snapshot.balances[account.id] ?? 0, account.currencyCode)
    }

    private func accountRow(_ account: Account, snapshot: LedgerSnapshot) -> some View {
        let selected = selectedID == account.id
        let balance = snapshot.balances[account.id] ?? 0
        return Button { selectedID = selected ? nil : account.id } label: {
            HStack(spacing: 12) {
                Text(String(account.name.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DS.ink)
                    .frame(width: 32, height: 32)
                    .background(account.kind == .liability ? DS.violet : DS.lime)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.name)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(DS.textPrimary)
                            .lineLimit(1)
                        if !account.includeInNetWorth { TagChip(text: tr("Not counted"), color: DS.textSecondary) }
                        if account.isArchived { TagChip(text: tr("Archived"), color: DS.textSecondary) }
                    }
                    Text(account.note.isEmpty ? account.currencyCode : "\(account.currencyCode) · \(account.note)")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(Fmt.money(balance, account.currencyCode))
                    .font(DS.money(15, weight: .semibold))
                    .foregroundStyle(balance < 0 ? FlowPalette.expense : DS.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(selected ? DS.tile : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(tr("Edit…")) { editingAccount = account }
        }
    }

    @ViewBuilder
    private func detail(snapshot: LedgerSnapshot) -> some View {
        if let account = snapshot.accounts.first(where: { $0.id == selectedID }) {
            let records = transactions.filter { $0.account?.id == account.id || $0.transferAccount?.id == account.id }
            Panel(title: account.name, accessory: {
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
            .frame(maxWidth: .infinity)
        } else {
            Panel {
                Text(tr("Select an account to see its records"))
                    .font(DS.body)
                    .foregroundStyle(DS.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Account editor

struct AccountEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let account: Account?
    /// Balance computed from the ledger when the sheet opened.
    let currentBalance: Decimal

    private static let kinds: [AccountKind] = [.payment, .cash, .liability, .other]

    @State private var name: String
    @State private var kind: AccountKind
    @State private var currency: String
    @State private var balanceText: String
    @State private var note: String
    @State private var counted: Bool
    @State private var archived: Bool

    init(account: Account?, currentBalance: Decimal) {
        self.account = account
        self.currentBalance = currentBalance
        _name = State(initialValue: account?.name ?? "")
        _kind = State(initialValue: account?.kind ?? .payment)
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
            CapsuleSwitch(options: Self.kinds, selection: $kind) { $0.displayName }
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
                row(tr("Note")) { field($note) }
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
        let target = account ?? Account(name: name, kind: kind, currencyCode: code)
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.kind = kind
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
