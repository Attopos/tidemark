import SwiftUI
import SwiftData

@main
struct TidemarkApp: App {
    @State private var appState = AppState()
    @NSApplicationDelegateAdaptor(SyncPushDelegate.self) private var pushDelegate
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
            // Never lose the session: fall back to memory and tell the user.
            container = (try? TidemarkSchema.makeContainer(inMemory: true))
                ?? { fatalError("SwiftData container could not be created: \(error)") }()
            sync = nil
            storageError = "Local database could not be opened (\(error.localizedDescription)). Running in temporary memory — data will NOT persist."
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(storageError: storageError)
                .environment(appState)
                .environment(sync)
                .frame(minWidth: 600, minHeight: 560)
                .task { sync?.start() }
        }
        .modelContainer(container)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 820)
        .commands { AppCommands(app: appState) }
    }
}

// MARK: - Menu commands & keyboard shortcuts

struct AppCommands: Commands {
    let app: AppState

    var body: some Commands {
        // Settings are a page of the main window, not a separate one.
        CommandGroup(replacing: .appSettings) {
            Button(tr("Settings…")) { app.section = .settings }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button(tr("Import Holdings Screenshot…")) {
                app.ocrImportPresented = true
            }
            .keyboardShortcut("i", modifiers: .command)
        }
    }
}
