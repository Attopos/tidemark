import SwiftUI
import SwiftData

/// Rows of one model for a page that stays alive while hidden (a tab). Unlike
/// @Query it does not redraw the page on every save while the page is off
/// screen: with every tab visited, one new record cost seconds of main
/// thread. Hidden changes are picked up when the page appears again.
@MainActor
@Observable
final class ModelFeed<Model: PersistentModel> {
    private var version = 0
    @ObservationIgnored private let sort: [SortDescriptor<Model>]
    @ObservationIgnored private var cache: [Model]?
    @ObservationIgnored private var stale = false
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored var isVisible: () -> Bool = { true }

    init(sort: [SortDescriptor<Model>] = []) { self.sort = sort }

    func rows(_ context: ModelContext) -> [Model] {
        _ = version
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed() }
            }
        }
        if cache == nil { cache = (try? context.fetch(FetchDescriptor<Model>(sortBy: sort))) ?? [] }
        guard let cache else { return [] }
        return stale ? cache.filter { !$0.isDeleted && $0.modelContext != nil } : cache
    }

    var stamp: Int { version }

    func becameVisible() {
        if stale { refresh() }
    }

    private func changed() {
        if isVisible() { refresh() } else { stale = true }
    }

    private func refresh() {
        stale = false
        cache = nil
        version += 1
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// The feeds a ledger page reads: records newest first, accounts, rates.
/// The page counts as visible while its tab is the selected section (a
/// hidden tab's onDisappear does not fire reliably).
@MainActor
final class LedgerFeeds {
    let records = ModelFeed<Transaction>(sort: [SortDescriptor(\.date, order: .reverse)])
    let accounts = ModelFeed<Account>(sort: [SortDescriptor(\.createdAt)])
    let rates = ModelFeed<CurrencyRate>()
    private weak var app: AppState?
    private var section: AppSection?
    private var memoKey: AnyHashable?
    private var memoValue: Any?

    /// Work derived from the feeds, redone only when they or `key` change: a
    /// hidden page still redraws when a record it shows is touched, and
    /// rebuilding every chart then cost hundreds of ms per save.
    func derived<Key: Hashable, Value>(_ key: Key, _ make: () -> Value) -> Value {
        let full = AnyHashable([AnyHashable(records.stamp), AnyHashable(accounts.stamp), AnyHashable(rates.stamp),
                                AnyHashable(key)])
        if memoKey == full, let value = memoValue as? Value { return value }
        let value = make()
        memoKey = full
        memoValue = value
        return value
    }

    func bind(_ app: AppState, _ section: AppSection) {
        guard self.app == nil else { return }
        self.app = app
        self.section = section
        let visible: () -> Bool = { [weak self] in self?.app.map { $0.section == section } ?? true }
        records.isVisible = visible
        accounts.isVisible = visible
        rates.isVisible = visible
        track()
    }

    private func track() {
        withObservationTracking { _ = app?.section } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.app?.section == self.section {
                    self.records.becameVisible()
                    self.accounts.becameVisible()
                    self.rates.becameVisible()
                }
                self.track()
            }
        }
    }
}

extension View {
    func ledgerFeeds(_ feeds: LedgerFeeds, app: AppState, section: AppSection) -> some View {
        onAppear { feeds.bind(app, section) }
    }
}
