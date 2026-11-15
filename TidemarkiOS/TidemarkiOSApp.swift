import SwiftUI
import SwiftData

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
    @State private var tab = 0
    let storageError: String?

    var body: some View {
        TabView(selection: $tab) {
            PhoneLedgerView()
                .tabItem { Label(tr("Ledger"), systemImage: "list.bullet.rectangle.fill") }
                .tag(0)
            AccountsView()
                .tabItem { Label(tr("Accounts"), systemImage: "square.stack.3d.up.fill") }
                .tag(1)
            PhoneAnalysisView()
                .tabItem { Label(tr("Analysis"), systemImage: "chart.bar.fill") }
                .tag(2)
            PhoneSettingsView(storageError: storageError)
                .tabItem { Label(tr("Settings"), systemImage: "gearshape.fill") }
                .tag(3)
        }
        .preferredColorScheme(app.appearance.colorScheme)
        .tint(DS.accentText)
        .id("\(app.language.rawValue)-\(app.amountsHidden)")
        .environment(\.locale, app.language.locale)
        .task {
            CurrencyService.ensureSeeds(in: context)
            PresetScheduler.run(in: context)
        }
        // Recurring records and instalments due since last time.
        .onChange(of: scenePhase) { _, phase in
            lock.sceneChanged(to: phase)
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
    }
}
