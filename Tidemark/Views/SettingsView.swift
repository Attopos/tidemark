import SwiftUI

// MARK: - App settings (language, target allocation)

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context

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
            Section(tr("iCloud")) {
                SyncStatusView()
            }
            Section {
                Button(tr("Import bookkeeping export…")) { app.pickLedgerExport(into: context) }
            } header: {
                Text(tr("Ledger"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Reads the .xlsx a bookkeeping app exports (date, type, amount, categories, accounts, remark, currency). Records already imported are skipped, so a newer export can be imported on top."))
                        .foregroundStyle(DS.textTertiary)
                    if let message = app.ledgerImportMessage {
                        Text(message)
                            .foregroundStyle(app.ledgerImportFailed ? DS.warning : DS.textSecondary)
                    }
                }
                .font(DS.caption)
            }
            Section {
                HStack(spacing: 8) {
                    Button(tr("Back up now")) { app.backUp(context) }
                    Button(tr("Export…")) { app.exportBackup(context) }
                    Spacer()
                    Button(tr("Restore…")) { app.restoreBackup(context) }
                }
            } header: {
                Text(tr("Backup"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Saved automatically to iCloud Drive › Tidemark, one file per day: holdings, every valuation, ledger records, accounts, rates and settings. Restoring merges the file in; nothing is deleted."))
                        .foregroundStyle(DS.textTertiary)
                    if let message = app.backupMessage {
                        Text(message)
                            .foregroundStyle(app.backupFailed ? DS.warning : DS.textSecondary)
                    } else if let last = app.lastBackup {
                        Text("\(tr("Last backup")) \(Fmt.relative(last))")
                            .foregroundStyle(DS.textSecondary)
                    }
                }
                .font(DS.caption)
            }
        }
        .formStyle(.grouped)
        .tint(DS.accent)
        .frame(width: 460, height: 700)
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
