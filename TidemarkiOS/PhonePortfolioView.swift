import SwiftUI
import SwiftData

struct PhonePortfolioView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query private var allHoldings: [Holding]
    @Query private var rates: [CurrencyRate]

    @State private var editingHolding: Holding?
    @State private var renaming: PortfolioRow?
    @State private var renameDraft = ""
    @State private var pendingDelete: Holding?
    @State private var restoring = false

    var body: some View {
        NavigationStack {
            Group {
                if app.portfolioLockEnabled && !app.portfolioUnlocked {
                    locked
                } else {
                    content
                }
            }
            .background(DS.page)
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(item: $editingHolding) { holding in
            BalanceSheet(holding: holding)
                .presentationDetents([.medium])
        }
        .alert(tr("Rename…"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("", text: $renameDraft)
            Button(tr("Cancel"), role: .cancel) { renaming = nil }
            Button(tr("Save")) {
                if let row = renaming { rename(row, to: renameDraft) }
                renaming = nil
            }
        }
        .confirmationDialog(trf("Delete “%@”?", pendingDelete?.asset?.displayName ?? ""),
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button(tr("Delete"), role: .destructive) {
                if let holding = pendingDelete {
                    context.delete(holding)
                    try? context.save()
                }
                pendingDelete = nil
            }
            Button(tr("Cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(tr("Its valuation history is removed too. To keep the history, use Mark as sold."))
        }
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { app.restoreBackup(from: url, into: context) }
        }
    }

    // MARK: Locked

    private var title: some View {
        PageTitle(title: tr("Portfolio")) {
            if !app.portfolioLockEnabled || app.portfolioUnlocked {
                RoundIconButton(symbol: "text.viewfinder") { app.ocrImportPresented = true }
                    .accessibilityLabel(tr("Import screenshot"))
            }
        }
    }

    private var locked: some View {
        VStack(spacing: 16) {
            title
                .padding(.horizontal, DS.phoneMargin)
                .padding(.top, 8)
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(DS.ink)
                .frame(width: 64, height: 64)
                .background(DS.accent)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(tr("Portfolio is locked"))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(DS.textPrimary)
            if let message = app.unlockMessage {
                Text(message)
                    .font(DS.caption)
                    .foregroundStyle(DS.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button(tr("Unlock")) { Task { await app.unlockPortfolio() } }
                .buttonStyle(AccentButtonStyle())
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await app.unlockPortfolio() }
    }

    // MARK: Content

    private var content: some View {
        let summary = PortfolioSummary(allHoldings: allHoldings, rates: rates, baseCurrency: app.baseCurrency)
        return ScrollView {
            VStack(spacing: 14) {
                title
                if summary.rows.isEmpty {
                    empty
                } else {
                    totalCard(summary)
                    exposureGrid(summary)
                    if summary.history.count >= 2 {
                        PhoneCard(title: tr("History"), icon: "chart.xyaxis.line") {
                            Text(trf("%d valuation days", summary.history.count))
                                .font(DS.caption)
                                .foregroundStyle(DS.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        } content: {
                            PortfolioHistoryChart(points: summary.history, currency: app.baseCurrency)
                        }
                    }
                    holdingsCard(summary)
                }
            }
            .padding(.horizontal, DS.phoneMargin)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
    }

    private var empty: some View {
        PhoneCard(title: tr("No holdings yet"), icon: "text.viewfinder") {
            VStack(alignment: .leading, spacing: 14) {
                Text(tr("Import a holdings screenshot to get started."))
                    .font(DS.body)
                    .foregroundStyle(DS.textSecondary)
                HStack(spacing: 10) {
                    Button(tr("Import screenshot")) { app.ocrImportPresented = true }
                        .buttonStyle(AccentButtonStyle())
                    Button(tr("Restore from backup…")) { restoring = true }
                        .buttonStyle(GhostButtonStyle())
                }
            }
        }
    }

    private func totalCard(_ summary: PortfolioSummary) -> some View {
        let code = app.baseCurrency
        let segments = summary.groups.filter { $0.baseValue > 0 }
        return PhoneCard(title: tr("Total value"), icon: "chart.pie.fill") {
            Spacer()
            PhoneChip(text: "\(Fmt.symbol(for: code)) \(code)") {
                let all = AppState.baseCurrencies
                app.baseCurrency = all[((all.firstIndex(of: code) ?? 0) + 1) % all.count]
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Fmt.money(summary.total, code))
                        .font(DS.money(34, weight: .semibold))
                        .foregroundStyle(DS.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    HStack(spacing: 6) {
                        Text(trf("%d assets", summary.valuedRows.count))
                        if let asOf = summary.asOf {
                            Text("· \(tr("As of")) \(Fmt.dateMedium.string(from: asOf))")
                        }
                    }
                    .font(DS.caption)
                    .foregroundStyle(DS.textSecondary)
                    if let stale = summary.staleNote {
                        Text(stale).font(DS.caption).foregroundStyle(DS.warning)
                    }
                }
                SegmentBar(segments: segments.map {
                    .init(id: $0.id, fraction: summary.share($0.baseValue), color: $0.exposure.color)
                })
                LazyVGrid(columns: PhoneCard<EmptyView, EmptyView>.twoColumns, alignment: .leading, spacing: 8) {
                    ForEach(summary.familyShares, id: \.family) { item in
                        HStack(spacing: 6) {
                            Circle().fill(item.family.color).frame(width: 8, height: 8)
                            Text(item.family.displayName).foregroundStyle(DS.textSecondary)
                            Text(Fmt.percent(item.share, showSign: false)).foregroundStyle(DS.textPrimary)
                        }
                        .font(.system(size: 13).monospacedDigit())
                    }
                }
                if let profit = summary.valuation.profit {
                    let color = profit.profit >= 0 ? DS.positive : DS.negative
                    HStack(spacing: 5) {
                        Text(tr("Unrealized P/L")).foregroundStyle(DS.textSecondary)
                        Text(Fmt.money(profit.profit, code, showSign: true)).foregroundStyle(color)
                        if let rate = profit.rate {
                            Text("(\(Fmt.percent(rate)))").foregroundStyle(color)
                        }
                    }
                    .font(.system(size: 13).monospacedDigit())
                    if profit.coverage < 0.995 {
                        Text(trf("covers %@ of value", Fmt.percent(profit.coverage, decimals: 0, showSign: false)))
                            .font(DS.caption)
                            .foregroundStyle(DS.textTertiary)
                    }
                }
                if let rate = summary.rateCaption {
                    Text(rate).font(DS.caption.monospacedDigit()).foregroundStyle(DS.textTertiary)
                }
            }
        }
    }

    private func exposureGrid(_ summary: PortfolioSummary) -> some View {
        LazyVGrid(columns: PhoneCard<EmptyView, EmptyView>.twoColumns, spacing: 10) {
            ForEach(summary.groups.filter { $0.baseValue > 0 }) { group in
                PortfolioView.ExposureCard(group: group, share: summary.share(group.baseValue),
                                           baseCurrency: app.baseCurrency)
            }
        }
    }

    private func holdingsCard(_ summary: PortfolioSummary) -> some View {
        PhoneCard(title: tr("Holdings"), icon: "list.bullet") {
            VStack(spacing: 12) {
                ForEach(summary.groups) { group in
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(group.exposure.markColor)
                                .frame(width: 12, height: 12)
                            Text(group.exposure.displayName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(DS.textPrimary)
                            Spacer()
                            Text(Fmt.percent(summary.share(group.baseValue), showSign: false))
                                .font(.system(size: 13).monospacedDigit())
                                .foregroundStyle(DS.textSecondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        ForEach(group.rows) { row in
                            Rectangle().fill(DS.border.opacity(0.6)).frame(height: 0.5).padding(.leading, 54)
                            Menu {
                                rowMenu(row)
                            } label: {
                                holdingRow(row, color: group.exposure.markColor, summary: summary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(DS.tile.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    private func holdingRow(_ row: PortfolioRow, color: Color, summary: PortfolioSummary) -> some View {
        HStack(spacing: 12) {
            AssetIcon(name: row.holding.asset?.name ?? row.name, symbol: row.holding.asset?.symbol ?? "",
                      color: color)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if !row.meta.isEmpty { Text(row.meta).lineLimit(1) }
                    if let updated = row.updated {
                        Text("·")
                        Text(Fmt.relative(updated)).foregroundStyle(row.isStale ? DS.warning : DS.textTertiary)
                    }
                }
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(DS.textTertiary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if let native = row.nativeValue {
                    MoneyText(row.baseValue, app.baseCurrency, font: DS.moneyTable)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if row.currency.uppercased() != app.baseCurrency.uppercased() {
                        Text(Fmt.money(native, row.currency) + " " + row.currency.uppercased())
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(DS.textTertiary)
                    } else {
                        Text(Fmt.percent(summary.share(row.baseValue), showSign: false))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(DS.textTertiary)
                    }
                } else {
                    Text(tr("no valuation")).font(DS.caption).foregroundStyle(DS.warning)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func rowMenu(_ row: PortfolioRow) -> some View {
        if let asset = row.holding.asset {
            Menu(tr("Exposure")) {
                ForEach(Exposure.allCases) { exposure in
                    Button {
                        asset.exposure = exposure
                        try? context.save()
                    } label: {
                        if asset.exposure == exposure {
                            Label(exposure.displayName, systemImage: "checkmark")
                        } else {
                            Text(exposure.displayName)
                        }
                    }
                }
                Divider()
                Button(tr("Automatic")) {
                    asset.exposureRaw = nil
                    try? context.save()
                }
            }
        }
        Button(tr("Rename…")) {
            renameDraft = row.name
            renaming = row
        }
        Button(tr("Update balance…")) { editingHolding = row.holding }
        Button(tr("Mark as sold")) {
            row.holding.close(on: Date(), source: .manual, in: context)
            try? context.save()
        }
        Divider()
        Button(tr("Delete holding"), role: .destructive) { pendingDelete = row.holding }
    }

    private func rename(_ row: PortfolioRow, to newName: String) {
        guard let asset = row.holding.asset else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        asset.customName = trimmed.isEmpty || trimmed == asset.name ? nil : trimmed
        try? context.save()
    }
}
