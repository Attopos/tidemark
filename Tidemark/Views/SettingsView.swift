import SwiftUI

// MARK: - App settings (language, target allocation)

struct SettingsView: View {
    @Environment(AppState.self) private var app

    private var targetSum: Int {
        Int((app.targets.values.reduce(0, +) * 100).rounded())
    }

    var body: some View {
        @Bindable var app = app
        Form {
            Section(tr("Language")) {
                CapsuleSwitch(options: AppLanguage.allCases, selection: $app.language) { $0.displayName }
            }
            Section {
                ForEach(Exposure.allCases) { exposure in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(exposure.color)
                            .frame(width: 11, height: 11)
                        Text(exposure.displayName)
                        Spacer()
                        TextField("—", text: targetBinding(exposure))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .labelsHidden()
                            .frame(width: 58)
                        Text("%").foregroundStyle(DS.textSecondary)
                    }
                }
            } header: {
                Text(tr("Target allocation"))
            } footer: {
                HStack {
                    Text(tr("Whole percentages. Leave empty for no target."))
                    Spacer()
                    if !app.targets.isEmpty {
                        Text("\(tr("Total")) \(targetSum)%")
                            .monospacedDigit()
                            .foregroundStyle(targetSum == 100 ? DS.textSecondary : DS.warning)
                    }
                }
                .font(DS.caption)
                .foregroundStyle(DS.textTertiary)
            }
        }
        .formStyle(.grouped)
        .tint(DS.accent)
        .frame(width: 440, height: 560)
        .id(app.language)
        .environment(\.locale, app.language.locale)
    }

    /// Whole percent in the field, fraction in the store; empty or 0 clears.
    private func targetBinding(_ exposure: Exposure) -> Binding<String> {
        Binding(
            get: {
                guard let value = app.targets[exposure.rawValue], value > 0 else { return "" }
                return String(Int((value * 100).rounded()))
            },
            set: { text in
                let digits = text.filter(\.isNumber)
                if let percent = Int(digits), percent > 0 {
                    app.targets[exposure.rawValue] = Double(min(percent, 100)) / 100
                } else {
                    app.targets.removeValue(forKey: exposure.rawValue)
                }
            }
        )
    }
}
