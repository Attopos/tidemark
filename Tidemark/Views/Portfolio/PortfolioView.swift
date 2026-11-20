import SwiftUI
import SwiftData
import Charts

struct PortfolioView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query private var allHoldings: [Holding]
    private var holdings: [Holding] { allHoldings.filter(\.isActive) }
    @Query private var rates: [CurrencyRate]

    @State private var editingHolding: Holding?
    @State private var renamingID: UUID?
    @State private var pendingDelete: Holding?
    @State private var deleteConfirmPresented = false

    private static let maxDonutSegments = 6

    typealias Row = PortfolioRow
    typealias ExposureGroup = PortfolioExposureGroup

    private var summary: PortfolioSummary {
        PortfolioSummary(allHoldings: allHoldings, rates: rates, baseCurrency: app.baseCurrency)
    }
    private var valuation: PortfolioValuation { summary.valuation }
    private var history: [PortfolioValuation.HistoryPoint] { summary.history }
    private var rows: [Row] { summary.rows }
    private var groups: [ExposureGroup] { summary.groups }
    private var valuedRows: [Row] { summary.valuedRows }
    private var total: Decimal { summary.total }
    private var asOf: Date? { summary.asOf }
    private var rateCaption: String? { summary.rateCaption }

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
        Button { app.section = .settings } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14, weight: .regular).monospacedDigit())
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
                .font(.system(size: 36, weight: .light).monospacedDigit())
                .foregroundStyle(DS.textTertiary)
            Text(tr("No holdings yet"))
                .font(.system(size: 19, weight: .regular).monospacedDigit())
                .foregroundStyle(DS.textPrimary)
            Text(tr("Import a holdings screenshot to get started."))
                .font(DS.body)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            importButton
                .padding(.top, 4)
            #if os(macOS)
            Button(tr("Restore from backup…")) { app.restoreBackup(context) }
                .buttonStyle(GhostButtonStyle())
            #endif
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(32)
    }

    private func overview(compact: Bool, jump: @escaping (String) -> Void) -> some View {
        VStack(spacing: 14) {
            totalPanel
            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 150 : 200), spacing: 14)], spacing: 14) {
                ForEach(groups.filter { $0.baseValue > 0 }) { group in
                    Button { jump(group.id) } label: {
                        ExposureCard(group: group,
                                     share: total > 0 ? (group.baseValue / total).doubleValue : 0,
                                     baseCurrency: app.baseCurrency)
                    }
                    .buttonStyle(.plain)
                    .help(tr("Show these holdings"))
                }
            }
        }
    }

    private var staleNote: String? { summary.staleNote }

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

    private var familyShares: [(family: RiskFamily, share: Double)] { summary.familyShares }

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
                        .font(DS.money(40))
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

    struct ExposureCard: View {
        let group: ExposureGroup
        let share: Double
        let baseCurrency: String

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Text(group.exposure.displayName)
                    .font(TS.title)
                    .foregroundStyle(group.exposure.ink)
                    .lineLimit(2)
                Spacer(minLength: 16)
                Text("\(tr("Share")) \(Fmt.percent(share, showSign: false))")
                    .font(TS.caption)
                    .foregroundStyle(group.exposure.ink.opacity(0.65))
                Text(Fmt.money(group.baseValue, baseCurrency))
                    .font(TS.figure)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(group.exposure.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(TS.cardPadding + 1.5)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(group.exposure.color)
            .clipShape(RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous))
        }
    }

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
                            .fill(group.exposure.markColor)
                            .frame(width: 12, height: 12)
                        Text(group.exposure.displayName)
                            .font(DS.title(16))
                            .foregroundStyle(DS.textPrimary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)

                ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                    Rectangle().fill(DS.border.opacity(index == 0 ? 0.9 : 0.5)).frame(height: 1)
                        .padding(.leading, index == 0 ? 0 : 60)
                    HoldingLine(row: row,
                                share: total > 0 && row.nativeValue != nil ? (row.baseValue / total).doubleValue : nil,
                                color: group.exposure.markColor,
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

    static func barLength(share: Double, scale: Double, width: CGFloat) -> CGFloat {
        guard share > 0, scale > 0 else { return 0 }
        return max(1, width * CGFloat(min(share / scale, 1)))
    }

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
                    RoundedRectangle(cornerRadius: 1.5).fill(DS.panel)
                        .frame(width: barWidth, height: 6)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5).fill(color)
                                .frame(width: PortfolioView.barLength(share: share, scale: scale, width: barWidth),
                                       height: 6)
                        }
                    Text(Fmt.percent(share, showSign: false))
                        .font(.system(size: 13.5, weight: bold ? .medium : .regular).monospacedDigit())
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
                            .font(.system(size: 14.5, weight: .regular).monospacedDigit())
                            .foregroundStyle(DS.textPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DS.panel)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.accent, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .focused($focused)
                            .onAppear { draft = row.name; focused = true }
                            .onSubmit { finishRename(draft) }
                            #if os(macOS)
                            .onExitCommand { finishRename(nil) }
                            #endif
                            .onChange(of: focused) { _, isFocused in
                                if !isFocused && renaming { finishRename(draft) }
                            }
                    } else {
                        Text(row.name)
                            .font(.system(size: 14.5, weight: .regular).monospacedDigit())
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
                                .foregroundStyle(stale ? DS.warning : DS.textTertiary)
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
                            .foregroundStyle(DS.warning)
                    }
                }
                .frame(width: valueWidth, alignment: .trailing)

                ShareCell(share: share, color: color.opacity(0.75), scale: scale)
                    .frame(width: shareWidth)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(hovering ? DS.textPrimary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
    }

    private func columnHeader(_ text: String, width: CGFloat?, alignment: Alignment) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .regular).monospacedDigit())
            .tracking(1)
            .foregroundStyle(DS.textTertiary)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
            .frame(width: width, alignment: alignment)
    }
}

struct BalanceSheet: View {
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
                .font(.system(size: 17, weight: .medium).monospacedDigit())
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
        #if os(macOS)
        .padding(22)
        .frame(width: 400)
        #else
        .padding(.horizontal, DS.phoneMargin)
        .padding(.vertical, 22)
        #endif
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

private struct HistoryPanel: View {
    let points: [PortfolioValuation.HistoryPoint]
    let currency: String

    var body: some View {
        Panel(title: tr("History"), icon: "chart.xyaxis.line") {
            Text(trf("%d valuation days", points.count))
                .font(DS.caption)
                .foregroundStyle(DS.textSecondary)
        } content: {
            PortfolioHistoryChart(points: points, currency: currency)
        }
    }
}

struct PortfolioHistoryChart: View {
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
            Chart(points) { point in
                AreaMark(x: .value("Date", point.date),
                         yStart: .value("Base", domain.lowerBound),
                         yEnd: .value("Value", point.total.doubleValue))
                    .foregroundStyle(LinearGradient(colors: [DS.accent.opacity(0.22), DS.accent.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Date", point.date),
                         y: .value("Value", point.total.doubleValue))
                    .foregroundStyle(DS.accentText)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("Date", point.date),
                          y: .value("Value", point.total.doubleValue))
                    .foregroundStyle(DS.accentText)
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
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(DS.textTertiary)
                }
            }
            .frame(height: 170)
    }
}

struct PortfolioRow: Identifiable {
    let id: UUID
    let holding: Holding
    let name: String
    let meta: String
    let currency: String
    let nativeValue: Decimal?
    let baseValue: Decimal
    let updated: Date?
    let exposure: Exposure

    var isStale: Bool {
        guard let updated else { return true }
        return Date().timeIntervalSince(updated) > 7 * 86_400
    }
}

struct PortfolioExposureGroup: Identifiable {
    let exposure: Exposure
    let rows: [PortfolioRow]
    var id: String { exposure.rawValue }
    var baseValue: Decimal { rows.filter { $0.nativeValue != nil }.reduce(0) { $0 + $1.baseValue } }
}

struct PortfolioSummary {
    let valuation: PortfolioValuation
    let history: [PortfolioValuation.HistoryPoint]
    let rows: [PortfolioRow]
    let groups: [PortfolioExposureGroup]
    let rateCaption: String?

    init(allHoldings: [Holding], rates: [CurrencyRate], baseCurrency: String) {
        let holdings = allHoldings.filter(\.isActive)
        let converter = CurrencyConverter(rates: rates, base: baseCurrency)
        let valuation = PortfolioValuation(inputs: holdings.map(\.valuationInput), converter: converter)
        self.valuation = valuation
        history = PortfolioValuation.history(inputs: allHoldings.map(\.valuationInput), converter: converter)
        var built: [PortfolioRow] = holdings.map { holding in
            let position = valuation.position(holding.id)
            let meta = [holding.asset?.symbol, holding.account?.name]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " · ")
            return PortfolioRow(id: holding.id,
                                holding: holding,
                                name: holding.asset?.displayName ?? "—",
                                meta: meta,
                                currency: holding.asset?.currencyCode ?? "CNY",
                                nativeValue: position?.nativeValue,
                                baseValue: position?.baseValue ?? 0,
                                updated: position?.date,
                                exposure: holding.asset?.exposure ?? .other)
        }
        built.sort { lhs, rhs in
            if (lhs.nativeValue == nil) != (rhs.nativeValue == nil) { return rhs.nativeValue == nil }
            return lhs.baseValue > rhs.baseValue
        }
        rows = built
        groups = Dictionary(grouping: built, by: \.exposure)
            .map { PortfolioExposureGroup(exposure: $0.key, rows: $0.value) }
            .sorted { $0.baseValue > $1.baseValue }
        let cny = CurrencyConverter(rates: rates, base: "CNY")
        if built.contains(where: { $0.currency.uppercased() != "CNY" }) || baseCurrency != "CNY",
           let usd = cny.rateToCNY("USD") {
            rateCaption = "1 USD = ¥" + NSDecimalNumber(decimal: usd.rounded(4)).stringValue
        } else {
            rateCaption = nil
        }
    }

    var valuedRows: [PortfolioRow] { rows.filter { $0.nativeValue != nil } }
    var total: Decimal { valuedRows.reduce(0) { $0 + $1.baseValue } }
    var asOf: Date? { valuedRows.compactMap(\.updated).max() }

    func share(_ value: Decimal) -> Double { total > 0 ? (value / total).doubleValue : 0 }

    var staleNote: String? {
        let share = valuation.freshness().staleShare
        guard share >= 0.005 else { return nil }
        return trf("%@ of value is older than 7 days", Fmt.percent(share, decimals: 0, showSign: false))
    }

    var familyShares: [(family: RiskFamily, share: Double)] {
        let total = self.total
        guard total > 0 else { return [] }
        return RiskFamily.allCases.compactMap { family in
            let value = groups.filter { $0.exposure.family == family }.reduce(Decimal(0)) { $0 + $1.baseValue }
            return value > 0 ? (family, (value / total).doubleValue) : nil
        }
        .sorted { $0.share > $1.share }
    }
}
