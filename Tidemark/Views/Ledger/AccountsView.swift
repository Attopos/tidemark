import SwiftUI
import SwiftData

struct AccountsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @State private var feeds = LedgerFeeds()
    private var transactions: [Transaction] { feeds.records.rows(context) }
    private var accounts: [Account] { feeds.accounts.rows(context) }
    private var rates: [CurrencyRate] { feeds.rates.rows(context) }

    @State private var selectedID: UUID?
    @State private var editingAccount: Account?
    @State private var creating = false
    @State private var editingRecord: Transaction?
    @State private var showArchived = false
    @State private var reconciling = false
    @AppStorage("collapsedAccountGroups") private var collapsedRaw = ""

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }

    private func toggle(_ group: AccountGroup) {
        var set = collapsed
        if set.contains(group.rawValue) { set.remove(group.rawValue) } else { set.insert(group.rawValue) }
        collapsedRaw = set.sorted().joined(separator: ",")
    }

    var body: some View { page.ledgerFeeds(feeds, app: app, section: .accounts) }

    @ViewBuilder private var page: some View {
        let snapshot = feeds.derived(app.baseCurrency) {
            PerfLog.time("accounts.snapshot") {
                LedgerSnapshot(transactions: transactions, accounts: accounts, rates: rates, code: app.baseCurrency)
            }
        }
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
                .padding(.horizontal, wide ? DS.pagePadding : DS.phoneMargin)
                .padding(.top, wide ? 38 : PageTitle<EmptyView>.pageTop)
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
        #if os(iOS) && DEBUG
        .onReceive(NotificationCenter.default.publisher(for: PerfProbe.openAccountEditor)) { _ in creating = true }
        #endif
        .sheet(isPresented: $reconciling) {
            ReconcileSheet(accounts: snapshot.accounts, balances: snapshot.balances)
        }
        .sheet(item: $editingRecord) { RecordDetailView(transaction: $0) }
        #if os(iOS)
        .sheet(item: Binding(get: { snapshot.accounts.first { $0.id == selectedID } },
                             set: { selectedID = $0?.id })) { account in
            ScrollView { accountDetail(account, snapshot: snapshot).padding(16) }
                .background(DS.page)
                .presentationDetents([.medium, .large])
        }
        #endif
    }

    private var header: some View {
        @Bindable var app = app
        return PageTitle(title: tr("Assets")) {
            Menu {
                Button(tr("Reconcile…")) { reconciling = true }
                Toggle(tr("Show archived"), isOn: $showArchived)
            } label: {
                RoundIcon(symbol: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button { creating = true } label: {
                RoundIcon(symbol: "plus", active: true)
            }
            .buttonStyle(.plain)
            .help(tr("Add account"))
        }
        .padding(.bottom, 4)
    }

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
        return VStack(spacing: TS.cardSpacing) {
            HeroCard(label: tr("Net Assets"), value: Fmt.money(net.assets - net.debts, snapshot.code)) {
                InlineFigure(label: tr("Total"), value: Fmt.money(net.assets, snapshot.code))
                InlineFigure(label: tr("Debts"), value: Fmt.money(net.debts, snapshot.code))
            }
            HStack(spacing: TS.cardSpacing) {
                smallCard(tr("Total Borrowing"), Fmt.money(Swift.max(0, borrowed), snapshot.code),
                          icon: "arrow.down", tint: DS.textTertiary)
                smallCard(tr("Total Lending"), Fmt.money(Swift.max(0, lent), snapshot.code),
                          icon: "arrow.up", tint: DS.lime)
            }
        }
    }

    private func smallCard(_ title: String, _ value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.ink)
                .frame(width: 26, height: 26)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TS.caption)
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
                Text(value)
                    .font(TS.rowFigure)
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TS.rowInsetH - 2)
        .padding(.vertical, TS.rowInsetV)
        .frame(maxWidth: .infinity)
        .background(DS.panel)
        .clipShape(RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous))
    }

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
                                .font(TS.title.weight(.medium))
                                .foregroundStyle(DS.textPrimary)
                            Text("(\(members.count))")
                                .font(TS.label)
                                .foregroundStyle(DS.textTertiary)
                            Spacer(minLength: 8)
                            Text("\(tr("Balance")): \(Fmt.money(total, snapshot.code))")
                                .font(TS.label)
                                .foregroundStyle(DS.textTertiary)
                                .lineLimit(1)
                            Image(systemName: folded ? "chevron.right" : "chevron.down")
                                .font(.system(size: 11))
                                .foregroundStyle(DS.textTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if !folded {
                        VStack(spacing: 0) {
                            ForEach(Array(members.enumerated()), id: \.element.id) { index, account in
                                accountRow(account, snapshot: snapshot)
                                if index < members.count - 1 {
                                    Divider().overlay(DS.border.opacity(0.5)).padding(.leading, TS.rowInsetH + TS.rowIcon + 12)
                                }
                            }
                        }
                        .background(DS.panel)
                        .clipShape(RoundedRectangle(cornerRadius: TS.cardRadius, style: .continuous))
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
                AccountIcon(account: account, size: TS.rowIcon)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.name)
                            .font(TS.title)
                            .foregroundStyle(DS.textPrimary)
                            .lineLimit(1)
                        if !account.includeInNetWorth { TagChip(text: tr("Not counted"), color: DS.textSecondary) }
                        if account.isArchived { TagChip(text: tr("Archived"), color: DS.textSecondary) }
                    }
                    ForEach(subtitleLines(account), id: \.self) { line in
                        Text(line)
                            .font(TS.caption)
                            .foregroundStyle(DS.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.money(isCredit ? owed : balance, account.currencyCode))
                        .font(TS.rowFigure)
                        .foregroundStyle(!isCredit && balance < 0 ? FlowPalette.expense : DS.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                    if isCredit, let limit = account.creditLimit {
                        Text("\(tr("Avl Credit")): \(Fmt.money(limit - owed, account.currencyCode))")
                            .font(TS.caption)
                            .foregroundStyle(DS.textTertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, TS.rowInsetH)
            .padding(.vertical, TS.rowInsetV)
            .background(selected ? DS.tile : Color.clear)
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
        if let brand = account.brand {
            AccountBrandBadge(brand: brand, size: size)
        } else {
            Text(String(account.name.prefix(1)).uppercased())
                .font(.system(size: size * 0.4, weight: .medium).monospacedDigit())
                .foregroundStyle(account.group == .payable ? Color.white : DS.ink)
                .frame(width: size, height: size)
                .background(tint)
                .clipShape(Circle())
        }
    }
}

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
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(accounts) { account in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(account.name) · \(account.currencyCode)")
                                .font(.system(size: 14, weight: .regular).monospacedDigit())
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
                                    .font(.system(size: 12.5).monospacedDigit())
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
