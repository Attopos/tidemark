import Foundation
import SwiftData

// MARK: - Recurring records and instalments
//
// A scheduled preset writes one ledger record per due date: occurrence n
// falls on start + n × frequency (n = 0, 1, …), stops at the end date or the
// occurrence limit, and is written once. Each device runs this on its own;
// a record's fingerprint is "preset:<id>:<n>", so when both devices write
// the same occurrence, sync sees one record and keeps one. `generatedThrough`
// remembers the last occurrence written, so a generated record the user
// deletes is not written again.

enum PresetScheduler {
    /// Date of occurrence `index`, nil past the end or the limit.
    static func occurrence(_ index: Int, start: Date, frequency: Frequency, endDate: Date?, limit: Int?,
                           calendar: Calendar = .current) -> Date? {
        if let limit, index >= limit { return nil }
        var date = start
        for _ in 0..<index { date = frequency.next(after: date, calendar: calendar) }
        // Monthly steps from the 31st drift to the 28th; recompute from the start instead.
        if frequency == .monthly || frequency == .quarterly || frequency == .semiannual || frequency == .yearly {
            let months: Int
            switch frequency {
            case .monthly: months = index
            case .quarterly: months = index * 3
            case .semiannual: months = index * 6
            default: months = index * 12
            }
            date = calendar.date(byAdding: .month, value: months, to: start) ?? date
        }
        if let endDate, date > endDate { return nil }
        return date
    }

    /// Occurrences after `generatedThrough` that are due by `now`.
    static func due(start: Date, frequency: Frequency, endDate: Date?, limit: Int?, generatedThrough: Int,
                    now: Date, calendar: Calendar = .current) -> [(index: Int, date: Date)] {
        var result: [(Int, Date)] = []
        var index = generatedThrough + 1
        while let date = occurrence(index, start: start, frequency: frequency, endDate: endDate, limit: limit,
                                    calendar: calendar), date <= now {
            result.append((index, date))
            index += 1
            if result.count > 2_000 { break }
        }
        return result
    }

    static func fingerprint(preset: UUID, index: Int) -> String { "preset:\(preset.uuidString):\(index)" }

    /// Write every due record. Returns how many were added.
    @MainActor
    @discardableResult
    static func run(in context: ModelContext, now: Date = Date()) -> Int {
        guard let presets = try? context.fetch(FetchDescriptor<RecordPreset>()) else { return 0 }
        let scheduled = presets.filter { $0.isActive && $0.schedule != nil }
        guard !scheduled.isEmpty else { return 0 }
        let accounts = Dictionary(((try? context.fetch(FetchDescriptor<Account>())) ?? []).map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        let existing = Set(((try? context.fetch(FetchDescriptor<Transaction>())) ?? []).map(\.fingerprint))
        var added = 0
        for preset in scheduled {
            guard let frequency = preset.schedule else { continue }
            let due = due(start: preset.startDate, frequency: frequency, endDate: preset.endDate,
                          limit: preset.occurrenceLimit, generatedThrough: preset.generatedThrough, now: now)
            for (index, date) in due {
                let print = fingerprint(preset: preset.id, index: index)
                if !existing.contains(print) {
                    let record = makeRecord(from: preset, date: date, accounts: accounts, fingerprint: print)
                    if let limit = preset.occurrenceLimit, preset.note.isEmpty {
                        record.note = "\(index + 1)/\(limit)"
                    }
                    context.insert(record)
                    added += 1
                }
                preset.generatedThrough = index
                preset.updatedAt = now
            }
            if let limit = preset.occurrenceLimit, preset.generatedThrough >= limit - 1 { preset.isActive = false }
        }
        if added > 0 || scheduled.contains(where: { $0.updatedAt == now }) { try? context.save() }
        return added
    }

    /// A record filled from a preset (also used by templates in the editor).
    static func makeRecord(from preset: RecordPreset, date: Date, accounts: [UUID: Account],
                           fingerprint: String? = nil) -> Transaction {
        let record = Transaction(date: date, kind: preset.kind, amount: preset.amount,
                                 currencyCode: preset.currencyCode, category: preset.category,
                                 subcategory: preset.subcategory, note: preset.note, tags: preset.tags,
                                 account: preset.accountID.flatMap { accounts[$0] },
                                 transferAccount: preset.transferAccountID.flatMap { accounts[$0] },
                                 fingerprint: fingerprint)
        record.presetID = preset.id
        return record
    }
}
