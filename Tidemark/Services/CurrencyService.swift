import Foundation
import SwiftData

// MARK: - Currency conversion
//
// All stored rates pivot through CNY: one CurrencyRate row says
// "1 unit of CODE = rate CNY" at a date. Conversion to any base currency is
// rateToCNY(code) / rateToCNY(base). Dated rows are kept so historical
// conversions use the closest rate at-or-before the date (falling back to the
// earliest known rate). Codes with no rate at all convert 1:1 and are
// surfaced as a data-quality warning — never silently trusted.

struct CurrencyConverter {
    let base: String
    /// code -> sorted [(date, rate-to-CNY)]
    private let history: [String: [(date: Date, rate: Decimal)]]

    init(rates: [CurrencyRate], base: String) {
        self.base = base.uppercased()
        var map: [String: [(date: Date, rate: Decimal)]] = [:]
        for r in rates {
            map[r.code.uppercased(), default: []].append((r.date, r.rate))
        }
        for key in map.keys { map[key]?.sort { $0.date < $1.date } }
        self.history = map
    }

    /// 1 unit of `code` in CNY at `date`. CNY itself is always 1.
    func rateToCNY(_ code: String, at date: Date = Date()) -> Decimal? {
        let c = code.uppercased()
        if c == "CNY" { return 1 }
        guard let series = history[c], !series.isEmpty else { return nil }
        // Latest at-or-before date, else the earliest known.
        var best: Decimal = series[0].rate
        for point in series {
            if point.date <= date { best = point.rate } else { break }
        }
        return best
    }

    /// 1 unit of `code` in `base` at `date`; nil when either leg is unknown.
    func rate(_ code: String, at date: Date = Date()) -> Decimal? {
        guard let toCNY = rateToCNY(code, at: date),
              let baseToCNY = rateToCNY(base, at: date), baseToCNY != 0 else { return nil }
        return toCNY / baseToCNY
    }

    /// Convert to base currency. Unknown codes convert 1:1 (callers can check
    /// `knows(_:)` and surface the gap).
    func toBase(_ amount: Decimal, _ code: String, at date: Date = Date()) -> Decimal {
        guard let r = rate(code, at: date) else { return amount }
        return amount * r
    }

    func knows(_ code: String) -> Bool {
        code.uppercased() == "CNY" || history[code.uppercased()] != nil
    }

    var knownCodes: Set<String> { Set(history.keys).union(["CNY"]) }
}

// MARK: - Seeding & maintenance

enum CurrencyService {
    /// Offline-safe approximate anchors (editable in Data Sources → Market data;
    /// refreshable from the network when the user opts in). Dated far in the
    /// past so they act as the baseline for all history until real rates arrive.
    static let seedRates: [String: Decimal] = [
        "USD": 7.10, "EUR": 7.72, "GBP": 9.02, "JPY": 0.047, "HKD": 0.91,
        "THB": 0.205, "KRW": 0.0051, "VND": 0.00027, "TWD": 0.225,
        "SGD": 5.30, "AUD": 4.62, "CAD": 5.10, "CHF": 8.05, "GEL": 2.63,
        "TRY": 0.17, "EGP": 0.147, "MYR": 1.52, "USDT": 7.10, "USDC": 7.10,
    ]

    static let seedDate = DateComponents(calendar: .current, year: 2015, month: 1, day: 1).date ?? .distantPast

    /// Insert seed rates for any currency that has no rate rows yet.
    static func ensureSeeds(in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<CurrencyRate>())) ?? []
        let existingCodes = Set(existing.map { $0.code.uppercased() })
        var added = false
        for (code, rate) in seedRates where !existingCodes.contains(code) {
            context.insert(CurrencyRate(code: code, rate: rate, date: seedDate, source: .market, isSeeded: true))
            added = true
        }
        if added { try? context.save() }
    }

    /// Record a fresh rate (one row per code per day; same-day rows are updated).
    static func record(code: String, rate: Decimal, date: Date = Date(),
                       source: DataSource, in context: ModelContext) {
        let cal = Calendar.current
        let all = (try? context.fetch(FetchDescriptor<CurrencyRate>())) ?? []
        if let sameDay = all.first(where: {
            $0.code.uppercased() == code.uppercased() && cal.isDate($0.date, inSameDayAs: date) && !$0.isSeeded
        }) {
            sameDay.rate = rate
            sameDay.sourceRaw = source.rawValue
        } else {
            context.insert(CurrencyRate(code: code.uppercased(), rate: rate, date: date, source: source))
        }
    }

    // MARK: Live USD rate

    /// Fetch today's USD→CNY reference rate (ECB data via frankfurter.app; no
    /// key, nothing about the user is sent) when no fetched rate exists for
    /// today. Failures keep the last known rate. USDT/USDC follow USD.
    @MainActor
    static func refreshUSDIfStale(in context: ModelContext) async {
        let cal = Calendar.current
        let all = (try? context.fetch(FetchDescriptor<CurrencyRate>())) ?? []
        let hasToday = all.contains { $0.code.uppercased() == "USD" && !$0.isSeeded && cal.isDateInToday($0.date) }
        guard !hasToday, let url = URL(string: "https://api.frankfurter.app/latest?from=USD&to=CNY") else { return }
        struct Response: Decodable { let rates: [String: Double] }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            guard let cny = try JSONDecoder().decode(Response.self, from: data).rates["CNY"], cny > 1 else { return }
            let rate = Decimal(string: String(format: "%.4f", cny)) ?? Decimal(cny)
            for code in ["USD", "USDT", "USDC"] {
                record(code: code, rate: rate, source: .market, in: context)
            }
            try? context.save()
        } catch {
            // Offline: the latest stored rate stays in effect.
        }
    }
}
