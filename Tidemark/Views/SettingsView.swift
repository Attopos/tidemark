import SwiftUI

// MARK: - Settings page (a page of the main window, like the others)

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @State private var showsPresets = false

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("Settings"))
                .font(DS.title(30))
                .foregroundStyle(DS.textPrimary)
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
        Form {
            Section(tr("Language")) {
                CapsuleSwitch(options: AppLanguage.allCases, selection: $app.language) { $0.displayName }
            }
            Section(tr("Appearance")) {
                CapsuleSwitch(options: AppAppearance.allCases, selection: $app.appearance) { $0.title }
            }
            Section(tr("Portfolio")) {
                Toggle(tr("Ask for the Mac password to open the portfolio"), isOn: $app.portfolioLockEnabled)
                    .toggleStyle(LimeCheckboxStyle())
            }
            Section(tr("iCloud")) {
                SyncStatusView()
            }
            Section(tr("Templates & recurring")) {
                Button(tr("Templates, recurring records and instalments…")) { showsPresets = true }
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
        .scrollContentBackground(.hidden)
        .tint(DS.accentText)
        }
        .padding(.top, 38)
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .background(DS.page)
        .sheet(isPresented: $showsPresets) { PresetsView() }
    }
}
