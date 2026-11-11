import SwiftUI
import SwiftData
import Charts

// MARK: - Portfolio — the app's single screen
//
// A total-value hero, an allocation donut by risk exposure, and a holdings
// table grouped two levels deep: exposure (US equity, crypto, gold…), then
// the individual holdings. Each holding keeps its own currency (a Binance
// coin in USD, an Alipay fund in CNY); totals, shares and the donut convert
// everything to the chosen display currency (CNY or USD) with the dated rate
// of today. Values come from the latest valuation snapshot — nothing is
// projected or fabricated; the numbers themselves are computed by
// PortfolioValuation. Right-click: exposure override, manual balance
// correction, mark as sold (history kept), delete.

struct PortfolioView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    /// Every holding, sold ones included: history needs them.
    @Query private var allHoldings: [Holding]
    private var holdings: [Holding] { allHoldings.filter(\.isActive) }
    @Query private var rates: [CurrencyRate]

    @State private var editingHolding: Holding?
    /// Holding whose name is being edited inline.
    @State private var renamingID: UUID?
    @State private var pendingDelete: Holding?
    @State private var deleteConfirmPresented = false

    private static let maxDonutSegments = 6

    private struct Row: Identifiable {
        let id: UUID
        let holding: Holding
        let name: String
        let meta: String
        let currency: String
        let nativeValue: Decimal?
        let baseValue: Decimal
        let updated: Date?
        let exposure: Exposure
    }

    private struct ExposureGroup: Identifiable {
        let exposure: Exposure
        let rows: [Row]
        var id: String { exposure.rawValue }
        var baseValue: Decimal { rows.filter { $0.nativeValue != nil }.reduce(0) { $0 + $1.baseValue } }
    }

    /// Latest valuation of every active holding, at today's rate.
    private var valuation: PortfolioValuation {
        PortfolioValuation(inputs: holdings.map(\.valuationInput),
                           converter: CurrencyConverter(rates: rates, base: app.baseCurrency))
    }

    /// One total per valuation day; sold holdings count until they were sold.
    private var history: [PortfolioValuation.HistoryPoint] {
        PortfolioValuation.history(inputs: allHoldings.map(\.valuationInput),
                                   converter: CurrencyConverter(rates: rates, base: app.baseCurrency))
    }

    private var rows: [Row] {
        let valuation = self.valuation
        var built: [Row] = holdings.map { holding in
            let position = valuation.position(holding.id)
            let currency = holding.asset?.currencyCode ?? "CNY"
            let meta = [holding.asset?.symbol, holding.account?.name]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " · ")
            return Row(id: holding.id,
                       holding: holding,
                       name: holding.asset?.displayName ?? "—",
                       meta: meta,
                       currency: currency,
                       nativeValue: position?.nativeValue,
                       baseValue: position?.baseValue ?? 0,
                       updated: position?.date,
                       exposure: holding.asset?.exposure ?? .other)
        }
        built.sort { lhs, rhs in
            if (lhs.nativeValue == nil) != (rhs.nativeValue == nil) { return rhs.nativeValue == nil }
            return lhs.baseValue > rhs.baseValue
        }
        return built
    }

    /// Level 1: exposures by value; level 2: holdings by value.
    private var groups: [ExposureGroup] {
        Dictionary(grouping: rows, by: \.exposure)
            .map { ExposureGroup(exposure: $0.key, rows: $0.value) }
            .sorted { $0.baseValue > $1.baseValue }
    }

    private var valuedRows: [Row] { rows.filter { $0.nativeValue != nil } }
    private var total: Decimal { valuedRows.reduce(0) { $0 + $1.baseValue } }
    private var asOf: Date? { valuedRows.compactMap(\.updated).max() }

    /// "1 USD = ¥7.12" for the hero, from the latest stored rate.
    private var rateCaption: String? {
        let converter = CurrencyConverter(rates: rates, base: "CNY")
        guard rows.contains(where: { $0.currency.uppercased() != "CNY" }) || app.baseCurrency != "CNY",
              let usd = converter.rateToCNY("USD") else { return nil }
        return "1 USD = ¥" + NSDecimalNumber(decimal: usd.rounded(4)).stringValue
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 760
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.gridGap) {
                    header(compact: compact)
                    if rows.isEmpty {
                        emptyState
                    } else {
                        overview(compact: compact) { id in
                            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .top) }
                        }
                        historyPanel
                        holdingsCard(compact: compact)
                    }
                }
                .padding(.horizontal, compact ? 20 : DS.pagePadding)
                .padding(.top, compact ? 24 : 38)
                .padding(.bottom, DS.pagePadding)
                .frame(maxWidth: 1080, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            }
        }
        .background(DS.page)
        .sheet(item: $editingHolding) { holding in
            BalanceSheet(holding: holding)
        }
        .confirmationDialog(
            trf("Delete “%@”?", pendingDelete?.asset?.displayName ?? ""),
            isPresented: $deleteConfirmPresented,
            titleVisibility: .visible
        ) {
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
    }

    // MARK: Header

    private func header(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Text(tr("Portfolio"))
                    .font(DS.title(compact ? 26 : 30))
                    .foregroundStyle(DS.textPrimary)
                Spacer()
                currencyPicker
                if !compact {
                    importButton
                }
                settingsButton
            }
            if compact {
                importButton
            }
        }
        .padding(.bottom, 6)
    }

    private var currencyPicker: some View {
        @Bindable var app = app
        return CapsuleSwitch(options: AppState.baseCurrencies, selection: $app.baseCurrency) { code in
            "\(Fmt.symbol(for: code)) \(code)"
        }
        .help(tr("Display currency for totals and allocation"))
    }

    private var importButton: some View {
        Button(tr("Import screenshot")) { app.ocrImportPresented = true }
            .buttonStyle(AccentButtonStyle())
    }

    private var settingsButton: some View {
        SettingsLink {
            Image(systemName: "gearshape")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DS.textSecondary)
                .frame(width: 31, height: 31)
                .background(DS.bgElevated)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(DS.border, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tr("Settings"))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(DS.textTertiary)
            Text(tr("No holdings yet"))
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(DS.textPrimary)
            Text(tr("Import a holdings screenshot to get started."))
                .font(DS.body)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            importButton
                .padding(.top, 4)
            // A new device starts empty: the backup is in iCloud Drive › Tidemark.
            Button(tr("Restore from backup…")) { app.restoreBackup(context) }
                .buttonStyle(GhostButtonStyle())
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(32)
    }

    // MARK: Overview
    //
    // A total card with the allocation as one segmented bar (colors = risk
    // family, see RiskFamily), then one solid card per exposure.

    private func overview(compact: Bool, jump: @escaping (String) -> Void) -> some View {
        VStack(spacing: 14) {
            totalPanel
            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 150 : 200), spacing: 14)], spacing: 14) {
                ForEach(groups.filter { $0.baseValue > 0 }) { group in
                    Button { jump(group.id) } label: {
                        ExposureCard(group: group,
                                     share: total > 0 ? (group.baseValue / total).doubleValue : 0,
                                     baseCurrency: app.baseCurrency,
                                     drift: drift(for: group))
                    }
                    .buttonStyle(.plain)
                    .help(tr("Show these holdings"))
                }
            }
        }
    }

    /// Actual weight against the target set in Settings, if there is one.
    private func drift(for group: ExposureGroup) -> AllocationDrift? {
        guard total > 0, let target = app.target(for: group.exposure) else { return nil }
        return AllocationDrift(target: target, actual: (group.baseValue / total).doubleValue)
    }

    /// "18% of value is older than 7 days": the total mixes valuation dates,
    /// so say how much of it is not fresh.
    private var staleNote: String? {
        let share = valuation.freshness().staleShare
        guard share >= 0.005 else { return nil }
        return trf("%@ of value is older than 7 days", Fmt.percent(share, decimals: 0, showSign: false))
    }

    @ViewBuilder
    private var historyPanel: some View {
        let points = history
        if points.count >= 2 {
            HistoryPanel(points: points, currency: app.baseCurrency)
        }
    }

    @ViewBuilder
    private var profitLine: some View {
        if let profit = valuation.profit {
            let color = profit.profit >= 0 ? DS.positive : DS.negative
            HStack(spacing: 5) {
                Text(tr("Unrealized P/L"))
                    .foregroundStyle(DS.textSecondary)
                Text(Fmt.money(profit.profit, app.baseCurrency, showSign: true))
                    .foregroundStyle(color)
                if let rate = profit.rate {
                    Text("(\(Fmt.percent(rate)))")
                        .foregroundStyle(color)
                }
                if profit.coverage < 0.995 {
                    Text("· " + trf("covers %@ of value", Fmt.percent(profit.coverage, decimals: 0, showSign: false)))
                        .foregroundStyle(DS.textTertiary)
                }
            }
            .font(.system(size: 13).monospacedDigit())
            .lineLimit(1)
            .help(tr("Profit reported by each source on its latest valuation; cost is value minus profit."))
        }
    }

    private var familyShares: [(family: RiskFamily, share: Double)] {
        guard total > 0 else { return [] }
        return RiskFamily.allCases.compactMap { family in
            let value = groups.filter { $0.exposure.family == family }.reduce(Decimal(0)) { $0 + $1.baseValue }
            return value > 0 ? (family, (value / total).doubleValue) : nil
        }
        .sorted { $0.share > $1.share }
    }

    private var totalPanel: some View {
        Panel(title: tr("Total value"), icon: "chart.pie.fill") {
            HStack(spacing: 10) {
                if let staleNote {
                    Text(staleNote)
                        .font(DS.caption)
                        .foregroundStyle(DS.warning)
                }
                if let asOf {
                    Text("\(tr("As of")) \(Fmt.dateMedium.string(from: asOf))")
                        .font(DS.caption)
                        .foregroundStyle(DS.textSecondary)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(Fmt.money(total, app.baseCurrency))
                        .font(DS.money(40, weight: .semibold))
                        .foregroundStyle(DS.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(trf("%d assets", valuedRows.count))
                        .font(DS.caption)
                        .foregroundStyle(DS.textSecondary)
                    Spacer()
                    if let rateCaption {
                        Text(rateCaption)
                            .font(DS.caption.monospacedDigit())
                            .foregroundStyle(DS.textSecondary)
                    }
                }
                SegmentBar(segments: groups.filter { $0.baseValue > 0 }.map {
                    .init(id: $0.id, fraction: total > 0 ? ($0.baseValue / total).doubleValue : 0,
                          color: $0.exposure.color)
                })
                HStack(spacing: 18) {
                    ForEach(familyShares, id: \.family) { item in
                        HStack(spacing: 6) {
                            Circle().fill(item.family.color).frame(width: 8, height: 8)
                            Text(item.family.displayName)
                                .foregroundStyle(DS.textSecondary)
                            Text(Fmt.percent(item.share, showSign: false))
                                .foregroundStyle(DS.textPrimary)
                        }
                        .font(.system(size: 13).monospacedDigit())
                    }
                    Spacer()
                    profitLine
                }
            }
        }
    }

    private struct ExposureCard: View {
        let group: ExposureGroup
        let share: Double
        let baseCurrency: String
        var drift: AllocationDrift? = nil

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Text(group.exposure.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(group.exposure.ink)
                    .lineLimit(2)
                Spacer(minLength: 22)
                Text("\(tr("Share")) \(Fmt.percent(share, showSign: false))")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(group.exposure.ink.opacity(0.65))
                if let drift {
                    // Target and distance from it; bold once outside the
                    // rebalancing band (see AllocationDrift).
                    HStack(spacing: 4) {
                        if drift.outOfBand {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 11))
                        }
                        Text("\(tr("Target")) \(Fmt.percent(drift.target, decimals: 0, showSign: false)) · \(String(format: "%+.1f", drift.drift * 100)) pt")
                    }
                    .font(.system(size: 12, weight: drift.outOfBand ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(group.exposure.ink.opacity(drift.outOfBand ? 1 : 0.65))
                    .padding(.top, 2)
                    .padding(.bottom, 3)
                }
                HStack(alignment: .bottom) {
                    Text(Fmt.moneyCompact(group.baseValue, baseCurrency))
                        .font(DS.money(26, weight: .bold))
                        .foregroundStyle(group.exposure.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 8)
                    ArrowBadge()
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(group.exposure.color)
            .clipShape(RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous))
        }
    }

    // MARK: Holdings
    //
    // One block per exposure (color square, name, total, share bar), rows
    // inside it. The value column is always the display currency so it lines
    // up; a holding recorded in another currency shows its own amount under
    // it. Freshness lives in the row's subtitle instead of its own column.

    private let valueWidth: CGFloat = 150
    private let shareWidth: CGFloat = 146


    private func holdingsCard(compact: Bool) -> some View {
        Panel(title: tr("Holdings"), icon: "list.bullet") {
            EmptyView()
        } content: {
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    columnHeader(tr("Asset"), width: nil, alignment: .leading)
                    columnHeader(tr("Value"), width: valueWidth, alignment: .trailing)
                    columnHeader(tr("Share"), width: shareWidth, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                ForEach(groups) { group in
                    ExposureBlock(group: group,
                                  share: total > 0 ? (group.baseValue / total).doubleValue : 0,
                                  total: total,
                                  baseCurrency: app.baseCurrency,
                                  valueWidth: valueWidth,
                                  shareWidth: shareWidth,
                                  renamingID: $renamingID,
                                  onRename: { row, newName in rename(row, to: newName) },
                                  menu: { rowMenu($0) })
                        .id(group.id)
                }
            }
        }
    }

    /// Empty or the recognized name again → back to the recognized name.
    private func rename(_ row: Row, to newName: String) {
        guard let asset = row.holding.asset else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        asset.customName = trimmed.isEmpty || trimmed == asset.name ? nil : trimmed
        try? context.save()
    }

    @ViewBuilder
    private func rowMenu(_ row: Row) -> some View {
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
        Button(tr("Rename…")) { renamingID = row.id }
        Button(tr("Update balance…")) { editingHolding = row.holding }
        Button(tr("Mark as sold")) {
            row.holding.close(on: Date(), source: .manual, in: context)
            try? context.save()
        }
        Divider()
        Button(tr("Delete holding"), role: .destructive) {
            pendingDelete = row.holding
            deleteConfirmPresented = true
        }
    }

    private struct ExposureBlock<Menu: View>: View {
        let group: ExposureGroup
        let share: Double
        let total: Decimal
        let baseCurrency: String
        let valueWidth: CGFloat
        let shareWidth: CGFloat
        @Binding var renamingID: UUID?
        let onRename: (Row, String) -> Void
        let menu: (Row) -> Menu

        private var groupRowMax: Double {
            guard total > 0 else { return 1 }
            return group.rows.filter { $0.nativeValue != nil }
                .map { ($0.baseValue / total).doubleValue }.max() ?? 1
        }

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(group.exposure.color)
                            .frame(width: 12, height: 12)
                        Text(group.exposure.displayName)
                            .font(DS.title(16))
                            .foregroundStyle(DS.textPrimary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // No group totals here: this is the detail list; totals
                    // live in the overview cards above.
                    }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)

                ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                    Rectangle().fill(DS.border.opacity(index == 0 ? 0.9 : 0.5)).frame(height: 1)
                        .padding(.leading, index == 0 ? 0 : 60)
                    HoldingLine(row: row,
                                share: total > 0 && row.nativeValue != nil ? (row.baseValue / total).doubleValue : nil,
                                color: group.exposure.color,
                                // Bars compare holdings within their exposure: the
                                // largest in the group fills the bar.
                                scale: groupRowMax,
                                baseCurrency: baseCurrency,
                                valueWidth: valueWidth,
                                shareWidth: shareWidth,
                                renaming: renamingID == row.id,
                                startRename: { renamingID = row.id },
                                finishRename: { newName in
                                    if let newName { onRename(row, newName) }
                                    renamingID = nil
                                })
                        .contextMenu { menu(row) }
                }
            }
            .background(DS.tile.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    /// Bar length proportional to share / scale (the group's largest share);
    /// at least 1pt so a nonzero share is still visible.
    static func barLength(share: Double, scale: Double, width: CGFloat) -> CGFloat {
        guard share > 0, scale > 0 else { return 0 }
        return max(1, width * CGFloat(min(share / scale, 1)))
    }

    /// "29.7%" with a bar. The bar is scaled to `scale` (the largest share
    /// among its peers), so the biggest holding fills it and the rest are
    /// visibly proportional — raw shares of ~30% max would all look tiny.
    private struct ShareCell: View {
        let share: Double?
        let color: Color
        var scale: Double = 1
        var bold = false
        private let barWidth: CGFloat = 80

        var body: some View {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if let share {
                    // Square-ended bars: rounded caps eat visible length on
                    // short bars (a 16pt capsule reads well under 1/4 of 64pt).
                    // No minimum length, so 0.1% and 0.2% stay distinguishable.
                    RoundedRectangle(cornerRadius: 1.5).fill(DS.panel)
                        .frame(width: barWidth, height: 6)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5).fill(color)
                                .frame(width: PortfolioView.barLength(share: share, scale: scale, width: barWidth),
                                       height: 6)
                        }
                    Text(Fmt.percent(share, showSign: false))
                        .font(.system(size: 13.5, weight: bold ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(bold ? DS.textPrimary : DS.textSecondary)
                        .frame(width: 46, alignment: .trailing)
                } else {
                    Text("—").foregroundStyle(DS.textTertiary)
                }
            }
        }
    }

    private struct HoldingLine: View {
        let row: PortfolioView.Row
        let share: Double?
        let color: Color
        let scale: Double
        let baseCurrency: String
        let valueWidth: CGFloat
        let shareWidth: CGFloat
        let renaming: Bool
        let startRename: () -> Void
        let finishRename: (String?) -> Void
        @State private var hovering = false
        @State private var draft = ""
        @FocusState private var focused: Bool

        private var stale: Bool {
            guard let updated = row.updated else { return true }
            return Date().timeIntervalSince(updated) > 7 * 86_400
        }

        var body: some View {
            HStack(spacing: 14) {
                AssetIcon(name: row.holding.asset?.name ?? row.name,
                          symbol: row.holding.asset?.symbol ?? "",
                          color: color)
                VStack(alignment: .leading, spacing: 3) {
                    if renaming {
                        TextField("", text: $draft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(DS.textPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DS.panel)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.accent, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .focused($focused)
                            .onAppear { draft = row.name; focused = true }
                            .onSubmit { finishRename(draft) }
                            .onExitCommand { finishRename(nil) }
                            .onChange(of: focused) { _, isFocused in
                                if !isFocused && renaming { finishRename(draft) }
                            }
                    } else {
                        Text(row.name)
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(DS.textPrimary)
                            .lineLimit(1)
                            .onTapGesture(count: 2) { startRename() }
                            .help(tr("Double-click to rename"))
                    }
                    HStack(spacing: 5) {
                        if !row.meta.isEmpty { Text(row.meta) }
                        if let updated = row.updated {
                            Text("·")
                            Text(Fmt.relative(updated))
                                .foregroundStyle(stale ? DS.violetSoft : DS.textTertiary)
                        }
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 3) {
                    if let native = row.nativeValue {
                        MoneyText(row.baseValue, baseCurrency, font: DS.moneyTable)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        if row.currency.uppercased() != baseCurrency.uppercased() {
                            Text(Fmt.money(native, row.currency) + " " + row.currency.uppercased())
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(DS.textTertiary)
                        }
                    } else {
                        Text(tr("no valuation"))
                            .font(DS.caption)
                            .foregroundStyle(DS.violetSoft)
                    }
                }
                .frame(width: valueWidth, alignment: .trailing)

                ShareCell(share: share, color: color.opacity(0.75), scale: scale)
                    .frame(width: shareWidth)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(hovering ? Color.white.opacity(0.03) : .clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
    }

    private func columnHeader(_ text: String, width: CGFloat?, alignment: Alignment) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1)
            .foregroundStyle(DS.textTertiary)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
            .frame(width: width, alignment: alignment)
    }
}

// MARK: - Manual balance correction

private struct BalanceSheet: View {
    let holding: Holding
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var amountText: String
    @State private var date = Date()

    init(holding: Holding) {
        self.holding = holding
        let latest = holding.snapshots.max(by: { $0.date < $1.date })?.marketValue
        _amountText = State(initialValue: latest.map { NSDecimalNumber(decimal: $0.rounded(2)).stringValue } ?? "")
    }

    private var parsedAmount: Decimal? {
        AlipayScreenshotParser.extractNumber(amountText)?.value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Update balance"))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(DS.textPrimary)
            Text(holding.asset?.displayName ?? "—")
                .font(DS.body)
                .foregroundStyle(DS.textSecondary)
            HStack(spacing: 10) {
                Text("\(tr("Amount")) (\(Fmt.symbol(for: holding.asset?.currencyCode ?? "CNY")))")
                    .font(DS.caption)
                    .foregroundStyle(DS.textSecondary)
                TextField("0.00", text: $amountText)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.moneySmall)
                    .frame(width: 150)
            }
            DatePicker(tr("Valuation date"), selection: $date, displayedComponents: .date)
                .font(DS.caption)
            HStack {
                Spacer()
                Button(tr("Cancel")) { dismiss() }
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(tr("Save")) { save() }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(parsedAmount == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 400)
        .background(DS.bgSecondary)
    }

    private func save() {
        guard let value = parsedAmount else { return }
        let calendar = Calendar.current
        if let sameDay = holding.snapshots.first(where: { calendar.isDate($0.date, inSameDayAs: date) }) {
            sameDay.marketValue = value
            sameDay.sourceRaw = DataSource.manual.rawValue
        } else {
            context.insert(HoldingSnapshot(holding: holding, date: date, marketValue: value, source: .manual))
        }
        holding.lastUpdated = Date()
        try? context.save()
        dismiss()
    }
}

// MARK: - History
//
// Total value on every day something was valued. Points are the recorded
// days; the line between them only joins them.

private struct HistoryPanel: View {
    let points: [PortfolioValuation.HistoryPoint]
    let currency: String

    private var domain: ClosedRange<Double> {
        let values = points.map { $0.total.doubleValue }
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let pad = max((high - low) * 0.15, high * 0.01, 1)
        return max(0, low - pad)...(high + pad)
    }

    var body: some View {
        let domain = self.domain
        Panel(title: tr("History"), icon: "chart.xyaxis.line") {
            Text(trf("%d valuation days", points.count))
                .font(DS.caption)
                .foregroundStyle(DS.textSecondary)
        } content: {
            Chart(points) { point in
                AreaMark(x: .value("Date", point.date),
                         yStart: .value("Base", domain.lowerBound),
                         yEnd: .value("Value", point.total.doubleValue))
                    .foregroundStyle(LinearGradient(colors: [DS.accent.opacity(0.22), DS.accent.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Date", point.date),
                         y: .value("Value", point.total.doubleValue))
                    .foregroundStyle(DS.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("Date", point.date),
                          y: .value("Value", point.total.doubleValue))
                    .foregroundStyle(DS.accent)
                    .symbolSize(22)
            }
            .chartYScale(domain: domain)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(DS.border)
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(Fmt.moneyCompact(Decimal(amount), currency))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(DS.textTertiary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: 11))
                        .foregroundStyle(DS.textTertiary)
                }
            }
            .frame(height: 170)
        }
    }
}
