import SwiftUI

// MARK: - App settings (language only)

struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section(tr("Language")) {
                CapsuleSwitch(options: AppLanguage.allCases, selection: $app.language) { $0.displayName }
            }
        }
        .formStyle(.grouped)
        .tint(DS.accent)
        .frame(width: 440, height: 130)
        .id(app.language)
        .environment(\.locale, app.language.locale)
    }
}
