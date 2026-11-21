import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @State private var showsPresets = false

    var body: some View {
        @Bindable var app = app
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(tr("Settings"))
                    .font(DS.title(30))
                    .foregroundStyle(DS.textPrimary)
                    .padding(.bottom, 10)

                MacSetupCard {
                    MacSetupRow(icon: "lock.fill", color: .blue, title: tr("Ask for the Mac password to open the portfolio")) {
                        Toggle("", isOn: $app.portfolioLockEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(DS.accent)
                    }
                }

                MacSetupCard {
                    MacSetupRow(icon: "icloud.fill", color: Color(white: 0.45), title: tr("iCloud Sync")) {
                        SyncStatusView().fixedSize()
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    MacSetupCard {
                        MacSetupAction(icon: "square.and.arrow.down.fill", color: .indigo, title: tr("Import bookkeeping export…")) {
                            app.pickLedgerExport(into: context)
                        }
                        MacSetupDivider()
                        MacSetupAction(icon: "square.and.arrow.up.fill", color: .orange, title: tr("Export for iCost…")) {
                            app.exportLedger(from: context)
                        }
                    }
                    MacSetupNote(text: tr("Reads the .xlsx a bookkeeping app exports (date, type, amount, categories, accounts, remark, currency). Records already imported are skipped, so a newer export can be imported on top."),
                                 message: app.ledgerImportMessage, failed: app.ledgerImportFailed)
                }

                VStack(alignment: .leading, spacing: 8) {
                    MacSetupCard {
                        MacSetupAction(icon: "arrow.clockwise.icloud.fill", color: .mint, title: tr("Back up now")) {
                            app.backUp(context)
                        }
                        MacSetupDivider()
                        MacSetupAction(icon: "doc.badge.arrow.up.fill", color: .mint, title: tr("Export…")) {
                            app.exportBackup(context)
                        }
                        MacSetupDivider()
                        MacSetupAction(icon: "clock.arrow.circlepath", color: .mint, title: tr("Restore…")) {
                            app.restoreBackup(context)
                        }
                    }
                    MacSetupNote(text: tr("Saved automatically to iCloud Drive › Tidemark, one file per day: holdings, every valuation, ledger records, accounts, rates and settings. Restoring merges the file in; nothing is deleted."),
                                 message: app.backupMessage ?? app.lastBackup.map { "\(tr("Last backup")) \(Fmt.relative($0))" },
                                 failed: app.backupMessage != nil && app.backupFailed)
                }

                MacSetupCard {
                    MacSetupAction(icon: "repeat", color: .green, title: tr("Periodic Records")) {
                        showsPresets = true
                    }
                }

                MacSetupCard {
                    MacSetupMenu(icon: "sun.max.fill", color: .yellow, title: tr("Appearance"),
                                 options: AppAppearance.allCases, selection: $app.appearance) { $0.title }
                }

                MacSetupCard {
                    MacSetupMenu(icon: "globe", color: .teal, title: tr("Language Settings"),
                                 options: AppLanguage.allCases, selection: $app.language) { $0.displayName }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 38)
            .padding(.bottom, 32)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(DS.page)
        .sheet(isPresented: $showsPresets) { PresetsView() }
    }
}

private struct MacSetupCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(DS.panel)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct MacSetupIcon: View {
    let icon: String
    let color: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 12.5, weight: .regular).monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct MacSetupRow<Trailing: View>: View {
    let icon: String
    let color: Color
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            MacSetupIcon(icon: icon, color: color)
            Text(title)
                .font(.system(size: 14).monospacedDigit())
                .foregroundStyle(DS.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 12)
            trailing
        }
        .frame(minHeight: 50)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }
}

private struct MacSetupAction: View {
    let icon: String
    let color: Color
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            MacSetupRow(icon: icon, color: color, title: title) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .regular).monospacedDigit())
                    .foregroundStyle(DS.textTertiary)
            }
            .background(hovering ? DS.tile.opacity(0.6) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct MacSetupMenu<Option: Hashable>: View {
    let icon: String
    let color: Color
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(label(option), systemImage: "checkmark")
                    } else {
                        Text(label(option))
                    }
                }
            }
        } label: {
            MacSetupRow(icon: icon, color: color, title: title) {
                Text(label(selection))
                    .font(.system(size: 14).monospacedDigit())
                    .foregroundStyle(DS.textTertiary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .regular).monospacedDigit())
                    .foregroundStyle(DS.textTertiary)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }
}

private struct MacSetupDivider: View {
    var body: some View {
        Rectangle()
            .fill(DS.border)
            .frame(height: 0.5)
            .padding(.leading, 54)
    }
}

private struct MacSetupNote: View {
    let text: String
    var message: String?
    var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).foregroundStyle(DS.textTertiary)
            if let message {
                Text(message).foregroundStyle(failed ? DS.warning : DS.textSecondary)
            }
        }
        .font(DS.caption)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
