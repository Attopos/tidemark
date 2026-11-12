import SwiftUI
import SwiftData

@main
struct TidemarkiOSApp: App {
    @State private var appState = AppState()
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
                .environment(sync)
                .task { sync?.start() }
        }
        .modelContainer(container)
    }
}

struct PhoneRootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    let storageError: String?

    var body: some View {
        TabView {
            PhoneLedgerView()
                .tabItem { Label(tr("Ledger"), systemImage: "list.bullet.rectangle.fill") }
            AccountsView()
                .tabItem { Label(tr("Accounts"), systemImage: "square.stack.3d.up.fill") }
            AnalysisView()
                .tabItem { Label(tr("Analysis"), systemImage: "chart.bar.fill") }
            PhoneSettingsView(storageError: storageError)
                .tabItem { Label(tr("Settings"), systemImage: "gearshape.fill") }
        }
        .preferredColorScheme(app.appearance.colorScheme)
        .tint(DS.accentText)
        .id(app.language)
        .environment(\.locale, app.language.locale)
        .task { CurrencyService.ensureSeeds(in: context) }
    }
}

struct PhoneSettingsView: View {
    @Environment(AppState.self) private var app
    let storageError: String?

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section(tr("iCloud")) {
                    SyncStatusView()
                    if let storageError {
                        Text(storageError).font(DS.caption).foregroundStyle(DS.warning)
                    }
                }
                Section(tr("Appearance")) {
                    CapsuleSwitch(options: AppAppearance.allCases, selection: $app.appearance) { $0.title }
                }
                Section(tr("Language")) {
                    CapsuleSwitch(options: AppLanguage.allCases, selection: $app.language) { $0.displayName }
                }
                Section(tr("Currency")) {
                    CapsuleSwitch(options: AppState.baseCurrencies, selection: $app.baseCurrency) {
                        "\(Fmt.symbol(for: $0)) \($0)"
                    }
                }
            }
            .navigationTitle(tr("Settings"))
        }
    }
}
