import SwiftUI
import Charts

// MARK: - Allocation donut
//
// Categorical identity comes from DS.categorical in fixed rank order; anything
// beyond the ramp folds into a gray "Others" slice. Hover highlights a slice
// and swaps the center figure; the legend keeps identity from being color-alone.

struct AllocationSlice: Identifiable {
    let label: String
    let value: Decimal
    let color: Color
    var id: String { label }
}

struct AllocationDonut: View {
    let slices: [AllocationSlice]
    let code: String
    var centerLabel = "Total"
    var diameter: CGFloat = 170

    @State private var hoverAngle: Double?

    private var total: Decimal { slices.reduce(0) { $0 + $1.value } }

    private var hoveredSlice: AllocationSlice? {
        guard let hoverAngle, total > 0 else { return nil }
        var cumulative: Double = 0
        for slice in slices {
            cumulative += (slice.value / total).doubleValue * 360
            if hoverAngle <= cumulative { return slice }
        }
        return slices.last
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                Chart(slices) { slice in
                    SectorMark(angle: .value(tr("Value"), slice.value.doubleValue),
                               innerRadius: .ratio(0.66),
                               angularInset: 1.4)
                        .foregroundStyle(slice.color)
                        .cornerRadius(3)
                        .opacity(hoveredSlice == nil || hoveredSlice?.id == slice.id ? 1 : 0.38)
                }
                .chartLegend(.hidden)
                .chartAngleSelection(value: $hoverAngle)
                VStack(spacing: 2) {
                    if let hovered = hoveredSlice {
                        Text(hovered.label)
                            .font(DS.caption)
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                        MoneyText(hovered.value, code, font: DS.money(17, weight: .bold), compact: true)
                        if total > 0 {
                            Text(Fmt.percent((hovered.value / total).doubleValue, showSign: false))
                                .font(DS.caption)
                                .foregroundStyle(DS.textTertiary)
                        }
                    } else {
                        Text(centerLabel.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(1)
                            .foregroundStyle(DS.textTertiary)
                        MoneyText(total, code, font: DS.money(17, weight: .bold), compact: true)
                    }
                }
                .frame(width: diameter * 0.52)
            }
            .frame(width: diameter, height: diameter)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(slices) { slice in
                    LegendRow(color: slice.color,
                              label: slice.label,
                              value: Fmt.moneyCompact(slice.value, code),
                              share: total > 0 ? Fmt.percent((slice.value / total).doubleValue, showSign: false) : nil,
                              dimmed: hoveredSlice != nil && hoveredSlice?.id != slice.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
