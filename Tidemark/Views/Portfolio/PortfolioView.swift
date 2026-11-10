import SwiftUI
import SwiftData

// MARK: - Portfolio — the app's single screen
//
// A total-value hero, an allocation donut by risk exposure, and a holdings
// table grouped two levels deep: exposure (US equity, crypto, gold…), then
// the individual holdings. Each holding keeps its own currency (a Binance
// coin in USD, an Alipay fund in CNY); totals, shares and the donut convert
// everything to the chosen display currency (CNY or USD) with the dated rate
// of each valuation. Values come from the latest valuation snapshot — nothing
// is projected or fabricated. Right-click: exposure override, manual balance
// correction, delete.

struct PortfolioView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Holding> { $0.isActive }) private var holdings: [Holding]
    @Query private var rates: [CurrencyRate]

    @State private var editingHolding: Holding?
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
        var color: Color { exposure.color }
    }

    private struct ExposureGroup: Identifiable {
        let exposure: Exposure
        let rows: [Row]
        var id: String { exposure.rawValue }
        var baseValue: Decimal { rows.filter { $0.nativeValue != nil }.reduce(0) { $0 + $1.baseValue } }
    }

    private var rows: [Row] {
        let converter = CurrencyConverter(rates: rates, base: app.baseCurrency)
        var built: [Row] = holdings.map { holding in
            let latest = holding.snapshots.max(by: { $0.date < $1.date })
            let currency = holding.asset?.currencyCode ?? "CNY"
            let meta = [holding.asset?.symbol, holding.account?.name]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " · ")
            return Row(id: holding.id,
                       holding: holding,
                       name: holding.asset?.name ?? "—",
                       meta: meta,
                       currency: currency,
                       nativeValue: latest?.marketValue,
                       baseValue: latest.map { converter.toBase($0.marketValue, currency, at: $0.date) } ?? 0,
                       updated: latest?.date,
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

    private var donutSlices: [AllocationSlice] {
        groups.filter { $0.baseValue > 0 }
            .map { AllocationSlice(label: $0.exposure.displayName, value: $0.baseValue, color: $0.exposure.color) }
    }

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
            ScrollView {
                VStack(alignment: .leading, spacing: DS.gridGap) {
                    header(compact: compact)
                    if rows.isEmpty {
                        emptyState
                    } else {
                        if compact {
                            hero
                            allocationCard
                        } else {
                            // One row: total on the left, allocation on the right.
                            HStack(alignment: .top, spacing: DS.gridGap) {
                                hero.frame(width: 340)
                                allocationCard
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
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
        .background(DS.bgPrimary)
        .sheet(item: $editingHolding) { holding in
            BalanceSheet(holding: holding)
        }
        .confirmationDialog(
            trf("Delete “%@”?", pendingDelete?.asset?.name ?? ""),
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
            Text(tr("Its valuation history is removed too."))
        }
    }

    // MARK: Header

    private func header(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Text(tr("Portfolio"))
                    .font(DS.editorial(compact ? 34 : 40))
                    .foregroundStyle(DS.textPrimary)
                    .kerning(-0.6)
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
        return Picker("", selection: $app.baseCurrency) {
            ForEach(AppState.baseCurrencies, id: \.self) { code in
                Text("\(Fmt.symbol(for: code)) \(code)").tag(code)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
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
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(32)
    }

    @ViewBuilder
    private var allocationCard: some View {
        if donutSlices.count > 1 {
            Card(title: tr("Allocation"), fillHeight: true) {
                AllocationDonut(slices: donutSlices, code: app.baseCurrency,
                                centerLabel: tr("Total"), diameter: 170)
            }
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tr("TOTAL VALUE"))
                    .font(DS.label)
                    .tracking(1.4)
                    .foregroundStyle(DS.heroInkSecondary)
                Spacer()
                if let asOf {
                    Text("\(tr("As of")) \(Fmt.dateMedium.string(from: asOf))")
                        .font(DS.caption)
                        .foregroundStyle(DS.heroInkSecondary)
                }
            }
            Spacer(minLength: 12)
            Text(Fmt.money(total, app.baseCurrency))
                .font(DS.money(44, weight: .bold))
                .foregroundStyle(DS.heroInk)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            HStack(spacing: 10) {
                Text(trf("%d assets", valuedRows.count))
                if let rateCaption {
                    Text("·")
                    Text(rateCaption)
                }
            }
            .font(DS.caption)
            .foregroundStyle(DS.heroInkSecondary)
            .padding(.top, 6)
            // Equal space above and below: the figure sits mid-card when the
            // hero is stretched to the allocation card's height.
            Spacer(minLength: 12)
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 150, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.heroGradient)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: Holdings table

    private let valueWidth: CGFloat = 170
    private let shareWidth: CGFloat = 64
    private let updatedWidth: CGFloat = 148

    private func holdingsCard(compact: Bool) -> some View {
        Card(title: tr("Holdings")) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Spacer()
                    columnHeader(tr("Value"), width: compact ? 148 : valueWidth)
                    columnHeader(tr("Share"), width: shareWidth)
                    if !compact {
                        columnHeader(tr("Updated"), width: updatedWidth)
                    }
                }
                .padding(.bottom, 4)
                ForEach(groups) { group in
                    ExposureHeader(group: group,
                                   share: total > 0 ? (group.baseValue / total).doubleValue : nil,
                                   baseCurrency: app.baseCurrency,
                                   valueWidth: compact ? 148 : valueWidth,
                                   shareWidth: shareWidth,
                                   updatedWidth: compact ? 0 : updatedWidth)
                    ForEach(group.rows) { row in
                        HoldingRow(row: row,
                                   share: total > 0 && row.nativeValue != nil
                                       ? (row.baseValue / total).doubleValue : nil,
                                   baseCurrency: app.baseCurrency,
                                   compact: compact,
                                   valueWidth: compact ? 148 : valueWidth,
                                   shareWidth: shareWidth, updatedWidth: updatedWidth)
                            .padding(.leading, 14)
                            .contextMenu { rowMenu(row) }
                        Divider().overlay(DS.border.opacity(0.4)).padding(.leading, 14)
                    }
                }
                HStack(spacing: 12) {
                    Text(tr("Total"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.textPrimary)
                    Spacer()
                    MoneyText(total, app.baseCurrency, font: DS.money(16, weight: .bold))
                        .frame(width: compact ? 148 : valueWidth, alignment: .trailing)
                    Color.clear.frame(width: shareWidth, height: 1)
                    if !compact {
                        Color.clear.frame(width: updatedWidth, height: 1)
                    }
                }
                .padding(.vertical, 11)
            }
        }
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
        Button(tr("Update balance…")) { editingHolding = row.holding }
        Divider()
        Button(tr("Delete holding"), role: .destructive) {
            pendingDelete = row.holding
            deleteConfirmPresented = true
        }
    }

    private struct ExposureHeader: View {
        let group: ExposureGroup
        let share: Double?
        let baseCurrency: String
        let valueWidth: CGFloat
        let shareWidth: CGFloat
        let updatedWidth: CGFloat

        var body: some View {
            HStack(spacing: 12) {
                Circle().fill(group.exposure.color).frame(width: 9, height: 9)
                Text(group.exposure.displayName)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(DS.textPrimary)
                Text("\(group.rows.count)")
                    .font(DS.caption)
                    .foregroundStyle(DS.textTertiary)
                Spacer()
                MoneyText(group.baseValue, baseCurrency, font: DS.money(15, weight: .semibold))
                    .frame(width: valueWidth, alignment: .trailing)
                Text(share.map { Fmt.percent($0, showSign: false) } ?? "—")
                    .font(DS.moneySmall.weight(.semibold))
                    .foregroundStyle(DS.textPrimary)
                    .frame(width: shareWidth, alignment: .trailing)
                if updatedWidth > 0 {
                    Color.clear.frame(width: updatedWidth, height: 1)
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 6)
            .padding(.horizontal, 4)
        }
    }

    private func columnHeader(_ text: String, width: CGFloat) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11.5, weight: .semibold))
            .tracking(1)
            .foregroundStyle(DS.textTertiary)
            .frame(width: width, alignment: .trailing)
    }

    private struct HoldingRow: View {
        let row: PortfolioView.Row
        let share: Double?
        let baseCurrency: String
        let compact: Bool
        let valueWidth: CGFloat
        let shareWidth: CGFloat
        let updatedWidth: CGFloat
        @State private var hovering = false

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(row.color.opacity(0.55))
                        .frame(width: 3, height: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(DS.textPrimary)
                            .lineLimit(compact ? 2 : 1)
                        if !row.meta.isEmpty {
                            Text(row.meta)
                                .font(.system(size: 12.5).monospacedDigit())
                                .foregroundStyle(DS.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: compact ? 0 : 12)
                    VStack(alignment: .trailing, spacing: 2) {
                        if let native = row.nativeValue {
                            // Recorded currency first; the converted figure below.
                            MoneyText(native, row.currency, font: DS.moneyTable)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            if row.currency.uppercased() != baseCurrency.uppercased() {
                                Text("≈ " + Fmt.money(row.baseValue, baseCurrency))
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
                    Text(share.map { Fmt.percent($0, showSign: false) } ?? "—")
                        .font(DS.moneySmall)
                        .foregroundStyle(DS.textSecondary)
                        .frame(width: shareWidth, alignment: .trailing)
                    if !compact {
                        FreshnessLabel(date: row.updated)
                            .frame(width: updatedWidth, alignment: .trailing)
                    }
                }
                if compact {
                    FreshnessLabel(date: row.updated)
                        .padding(.leading, 16)
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 4)
            .background(hovering ? DS.bgElevated.opacity(0.55) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
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
            Text(holding.asset?.name ?? "—")
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
