import SwiftUI

// MARK: - App settings (language only)

struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section(tr("Language")) {
                Picker(tr("Language"), selection: $app.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 130)
        .id(app.language)
        .environment(\.locale, app.language.locale)
    }
}
