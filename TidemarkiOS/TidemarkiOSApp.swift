import SwiftUI
import SwiftData
import Combine

@main
struct TidemarkiOSApp: App {
    @State private var appState = AppState()
    @State private var appLock = AppLock()
    @UIApplicationDelegateAdaptor(SyncPushDelegate.self) private var pushDelegate
    private let container: ModelContainer
    private let storageError: String?
    /// Nil when the store could not be opened: an empty in-memory store must
    /// never be compared with the server.
    private let sync: CloudSync?

    init() {
        do {
            container = try TidemarkSchema.makeContainer()
            storageError = nil
            sync = CloudSync(container: container)
        } catch {
            sync = nil
            container = (try? TidemarkSchema.makeContainer(inMemory: true))
                ?? { fatalError("SwiftData container could not be created: \(error)") }()
            storageError = error.localizedDescription
        }
    }

    var body: some Scene {
        WindowGroup {
            PhoneRootView(storageError: storageError)
                .environment(appState)
                .environment(appLock)
                .environment(sync)
                .task { sync?.start() }
        }
        .modelContainer(container)
    }
}

struct PhoneRootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var scenePhase
    let storageError: String?
    @State private var sharedFile: ImportFile?

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.section) {
            StableTab { PhoneLedgerView() }.equatable()
                .tabItem { Label(tr("Ledger"), systemImage: AppSection.ledger.icon) }
                .tag(AppSection.ledger)
            StableTab { AccountsView() }.equatable()
                .tabItem { Label(tr("Accounts"), systemImage: AppSection.accounts.icon) }
                .tag(AppSection.accounts)
            StableTab { PhonePortfolioView() }.equatable()
                .tabItem { Label(tr("Portfolio"), systemImage: AppSection.portfolio.icon) }
                .tag(AppSection.portfolio)
            StableTab { PhoneAnalysisView() }.equatable()
                .tabItem { Label(tr("Analysis"), systemImage: AppSection.analysis.icon) }
                .tag(AppSection.analysis)
            StableTab { PhoneSettingsView(storageError: storageError) }.equatable()
                .tabItem { Label(tr("Settings"), systemImage: AppSection.settings.icon) }
                .tag(AppSection.settings)
        }
        .preferredColorScheme(app.appearance.colorScheme)
        .tint(DS.accentText)
        .scrollIndicators(.hidden)
        .id("\(app.language.rawValue)-\(app.amountsHidden)")
        .environment(\.locale, app.language.locale)
        .sheet(item: $sharedFile) { LedgerImportReview(url: $0.url) }
        .onOpenURL { url in
            if url.pathExtension.lowercased() == "xlsx" { sharedFile = ImportFile(url: url) }
        }
        .fullScreenCover(isPresented: $app.ocrImportPresented) {
            ScreenshotImportFlow()
                .tint(DS.accentText)
                .scrollIndicators(.hidden)
        }
        .task {
            CurrencyService.ensureSeeds(in: context)
            PresetScheduler.run(in: context)
            app.backUp(context)
            while !Task.isCancelled {
                await CurrencyService.refreshUSDIfStale(in: context)
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)) { _ in
            app.backUp(context)
        }
        // Recurring records and instalments due since last time.
        .onChange(of: scenePhase) { _, phase in
            lock.sceneChanged(to: phase)
            if phase == .background { app.lockPortfolio() }
            if phase == .active { PresetScheduler.run(in: context) }
        }
        .overlay {
            if lock.locked {
                LockScreenView()
            } else if lock.enabled && scenePhase != .active {
                PrivacyCover()
            }
        }
        .task { await lock.unlock() }
        #if DEBUG
        .task { if PerfProbe.isOn { await PerfProbe().run(app: app) } }
        .task { if PerfProbe.entryOn { await PerfProbe().runEntry(app: app) } }
        .task { if PerfProbe.shotsOn { await PerfProbe().shoot(app: app) } }
        .task { if PerfProbe.importTestOn { await PerfProbe().importTest(store: context) } }
        #endif
    }
}

/// A tab whose page is not rebuilt when the tab bar's selection changes: the
/// pages read their own data, and rebuilding one re-runs its @Query and every
/// figure computed from it.
struct StableTab<Content: View>: View, Equatable {
    @ViewBuilder let content: () -> Content

    static func == (lhs: StableTab, rhs: StableTab) -> Bool { true }

    var body: some View { content() }
}
