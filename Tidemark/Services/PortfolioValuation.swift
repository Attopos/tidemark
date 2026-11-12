import Foundation
import SwiftData

// MARK: - Portfolio valuation (pure)
//
// The one place that turns dated valuations into totals. A valuation is
// always "the whole portfolio at one moment": every holding contributes the
// last value recorded at or before that moment (carried forward, never
// interpolated), converted with the exchange rate of that moment. A holding
// that was sold carries an explicit zero from its closing date, so it stops
// counting instead of lingering at its last value.
//
// Inputs are plain values, so everything here is testable without SwiftData.

struct ValuationPoint {
    let date: Date
    /// Market value in the holding's own currency.
    let value: Decimal
    /// Unrealized profit as reported by the source, same currency.
    var unrealizedPL: Decimal? = nil
}

struct ValuationInput {
    let id: UUID
    var currency: String = "CNY"
    var exposure: Exposure = .other
    var isActive = true
    let points: [ValuationPoint]
}

struct PortfolioValuation {
    struct Position {
        let id: UUID
        let exposure: Exposure
        let currency: String
        let nativeValue: Decimal
        let baseValue: Decimal
        let basePL: Decimal?
        /// Date of the valuation this position is carried from.
        let date: Date
    }

    struct HistoryPoint: Identifiable {
        let date: Date
        let total: Decimal
        var id: Date { date }
    }

    struct Freshness {
        let oldest: Date?
        /// Share of total value whose valuation is older than the threshold.
        let staleShare: Double
    }

    /// Unrealized profit over the positions that report one. Cost is implied
    /// (value − profit), so it does not depend on how a source labels cost.
    struct ProfitSummary {
        let profit: Decimal
        let cost: Decimal
        /// Share of total value covered by positions that report a profit.
        let coverage: Double
        var rate: Double? { cost > 0 ? (profit / cost).doubleValue : nil }
    }

    /// Holdings that have a valuation at or before the moment.
    let positions: [Position]
    /// The moment exchange rates are taken at.
    let rateDate: Date
    private let byID: [UUID: Position]

    /// - Parameter asOf: the day to value the portfolio on; nil = the latest
    ///   valuation of every holding at today's rate.
    init(inputs: [ValuationInput], converter: CurrencyConverter,
         asOf: Date? = nil, calendar: Calendar = .current) {
        let cutoff = asOf.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }
        let rateDate = asOf ?? Date()
        var built: [Position] = []
        for input in inputs {
            let eligible: [ValuationPoint]
            if let cutoff {
                eligible = input.points.filter { $0.date < cutoff }
            } else {
                eligible = input.points
            }
            guard let latest = eligible.max(by: { $0.date < $1.date }) else { continue }
            built.append(Position(
                id: input.id,
                exposure: input.exposure,
                currency: input.currency,
                nativeValue: latest.value,
                baseValue: converter.toBase(latest.value, input.currency, at: rateDate),
                basePL: latest.unrealizedPL.map { converter.toBase($0, input.currency, at: rateDate) },
                date: latest.date))
        }
        self.positions = built
        self.rateDate = rateDate
        self.byID = Dictionary(built.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func position(_ id: UUID) -> Position? { byID[id] }

    var total: Decimal { positions.reduce(Decimal(0)) { $0 + $1.baseValue } }

    func freshness(staleAfterDays: Double = 7) -> Freshness {
        let valued = positions.filter { $0.baseValue > 0 }
        let total = valued.reduce(Decimal(0)) { $0 + $1.baseValue }
        guard total > 0 else { return Freshness(oldest: nil, staleShare: 0) }
        let stale = valued
            .filter { rateDate.timeIntervalSince($0.date) > staleAfterDays * 86_400 }
            .reduce(Decimal(0)) { $0 + $1.baseValue }
        return Freshness(oldest: valued.map(\.date).min(), staleShare: (stale / total).doubleValue)
    }

    var profit: ProfitSummary? {
        let covered = positions.filter { $0.basePL != nil && $0.baseValue > 0 }
        let total = self.total
        guard !covered.isEmpty, total > 0 else { return nil }
        let value = covered.reduce(Decimal(0)) { $0 + $1.baseValue }
        let profit = covered.reduce(Decimal(0)) { $0 + ($1.basePL ?? 0) }
        return ProfitSummary(profit: profit, cost: value - profit, coverage: (value / total).doubleValue)
    }

    /// One total per day on which anything was valued, oldest first.
    static func history(inputs: [ValuationInput], converter: CurrencyConverter,
                        calendar: Calendar = .current) -> [HistoryPoint] {
        let days = Set(inputs.flatMap { $0.points.map { calendar.startOfDay(for: $0.date) } }).sorted()
        return days.map { day in
            // End of the day, so a rate fetched that day is the one used.
            let moment = day.addingTimeInterval(86_399)
            let valuation = PortfolioValuation(inputs: inputs, converter: converter, asOf: moment, calendar: calendar)
            return HistoryPoint(date: day, total: valuation.total)
        }
    }
}

// MARK: - SwiftData bridge

extension Holding {
    var valuationInput: ValuationInput {
        ValuationInput(id: id,
                       currency: asset?.currencyCode ?? "CNY",
                       exposure: asset?.exposure ?? .other,
                       isActive: isActive,
                       points: snapshots.map {
                           ValuationPoint(date: $0.date, value: $0.marketValue, unrealizedPL: $0.unrealizedPL)
                       })
    }

    /// The position was sold: record a zero valuation on that day and take
    /// the holding off the board. Its history stays, so past totals are
    /// still right. A later import of the same asset reopens it.
    func close(on date: Date, source: DataSource, in context: ModelContext, calendar: Calendar = .current) {
        if let sameDay = snapshots.first(where: { calendar.isDate($0.date, inSameDayAs: date) }) {
            sameDay.marketValue = 0
            sameDay.quantity = 0
            sameDay.unrealizedPL = nil
            sameDay.returnRate = nil
            sameDay.sourceRaw = source.rawValue
        } else {
            context.insert(HoldingSnapshot(holding: self, date: date, marketValue: 0, quantity: 0, source: source))
        }
        quantity = 0
        isActive = false
        lastUpdated = Date()
    }
}
