import SwiftUI
import SwiftData

@main
struct TidemarkApp: App {
    @State private var appState = AppState()
    private let container: ModelContainer
    private let storageError: String?

    init() {
        do {
            container = try TidemarkSchema.makeContainer()
            storageError = nil
        } catch {
            // Never lose the session: fall back to memory and tell the user.
            container = (try? TidemarkSchema.makeContainer(inMemory: true))
                ?? { fatalError("SwiftData container could not be created: \(error)") }()
            storageError = "Local database could not be opened (\(error.localizedDescription)). Running in temporary memory — data will NOT persist."
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(storageError: storageError)
                .environment(appState)
                .frame(minWidth: 600, minHeight: 560)
        }
        .modelContainer(container)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 820)
        .commands { AppCommands(app: appState) }

        Settings {
            SettingsView()
                .environment(appState)
        }
        .modelContainer(container)
    }
}

// MARK: - Menu commands & keyboard shortcuts

struct AppCommands: Commands {
    let app: AppState

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button(tr("Import Alipay Screenshot…")) {
                app.ocrImportPresented = true
            }
            .keyboardShortcut("i", modifiers: .command)
        }
    }
}
