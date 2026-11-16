import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct PhoneSettingsView: View {
    @Environment(AppState.self) private var app
    let storageError: String?

    var body: some View {
        NavigationStack {
            SetupPage(title: tr("Settings"), showsBack: false) {
                SetupCard {
                    SetupLink(icon: "lock.fill", color: .blue, title: tr("Protection")) { ProtectionView() }
                }
                SetupCard {
                    SetupLink(icon: "icloud.fill", color: Color(white: 0.45), title: tr("iCloud Sync")) {
                        CloudSyncSettingsView(storageError: storageError)
                    }
                }
                SetupCard {
                    SetupLink(icon: "square.and.arrow.down.fill", color: .indigo, title: tr("Import Data")) {
                        ImportDataView()
                    }
                    SetupDivider()
                    SetupLink(icon: "square.and.arrow.up.fill", color: .orange, title: tr("Export Data")) {
                        ExportDataView()
                    }
                }
                SetupCard {
                    SetupLink(icon: "arrow.clockwise.icloud.fill", color: .mint, title: tr("Data Backup")) {
                        BackupSettingsView()
                    }
                }
                SetupCard {
                    SetupLink(icon: "repeat", color: .green, title: tr("Periodic Records")) {
                        PresetsView(showsDone: false)
                            .padding(.horizontal, DS.phoneMargin)
                            .padding(.vertical, 16)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .background(DS.page)
                            .phoneHeader {
                                PhoneHeader(title: tr("Periodic Records")) { PhoneBackButton() } trailing: { EmptyView() }
                            }
                    }
                }
                SetupCard {
                    SetupLink(icon: "sun.max.fill", color: .yellow, title: tr("Appearance"),
                              value: app.appearance.title) { AppearanceSettingsView() }
                    SetupDivider()
                    SetupLink(icon: "banknote.fill", color: .blue, title: tr("Currency"),
                              value: app.baseCurrency) { CurrencySettingsView() }
                }
                SetupCard {
                    SetupLink(icon: "globe", color: .teal, title: tr("Language Settings"),
                              value: app.language.displayName) { LanguageSettingsView() }
                }
            }
        }
    }
}

// MARK: - Building blocks

struct SetupPage<Content: View>: View {
    let title: String
    var showsBack = true
    @ViewBuilder let content: Content

    var body: some View {
        if showsBack {
            scroll
                .phoneHeader {
                    PhoneHeader(title: title) { PhoneBackButton() } trailing: { EmptyView() }
                }
        } else {
            scroll
                .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var scroll: some View {
        ScrollView {
            VStack(spacing: 14) {
                if !showsBack { PageTitle(title: title) }
                content
            }
            .padding(.horizontal, DS.phoneMargin)
            .padding(.top, showsBack ? 6 : PageTitle<EmptyView>.pageTop)
            .padding(.bottom, 28)
        }
        .background(DS.page)
    }
}

struct SetupCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(DS.panel)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct SetupIcon: View {
    let icon: String
    let color: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SetupRowLabel<Trailing: View>: View {
    var icon: String?
    var color: Color = .blue
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            if let icon { SetupIcon(icon: icon, color: color) }
            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(DS.textPrimary)
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 56)
        .padding(.horizontal, 18)
        .contentShape(Rectangle())
    }
}

struct SetupLink<Destination: View>: View {
    let icon: String
    let color: Color
    let title: String
    var value: String?
    @ViewBuilder let destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            SetupRowLabel(icon: icon, color: color, title: title) {
                if let value {
                    Text(value).font(.system(size: 17)).foregroundStyle(DS.textTertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DS.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

struct SetupDivider: View {
    var inset: CGFloat = 60

    var body: some View {
        Rectangle()
            .fill(DS.border)
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}

struct SetupChoice: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SetupRowLabel(title: title) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(DS.accentText)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct SetupNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.caption)
            .foregroundStyle(DS.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
    }
}

struct SetupChoices<Option: Hashable>: View {
    let options: [Option]
    let selection: Option
    let title: (Option) -> String
    let select: (Option) -> Void

    var body: some View {
        SetupCard {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 { SetupDivider(inset: 18) }
                SetupChoice(title: title(option), selected: option == selection) { select(option) }
            }
        }
    }
}

// MARK: - Protection

struct ProtectionView: View {
    @Environment(AppLock.self) private var lock
    @Environment(AppState.self) private var app

    var body: some View {
        SetupPage(title: tr("Protection")) {
            SetupCard {
                SetupRowLabel(icon: lock.biometryIcon, color: .blue, title: tr("App lock")) {
                    Toggle("", isOn: Binding(get: { lock.enabled },
                                             set: { on in Task { await lock.setEnabled(on) } }))
                        .labelsHidden()
                        .tint(.green)
                }
            }
            SetupNote(text: trf("Ask for %@ or the device passcode when Tidemark opens or comes back, and hide its content in the app switcher.", lock.biometryName))
            if let message = lock.message {
                SetupNote(text: message)
            }
            if lock.enabled {
                SetupChoices(options: AppLock.Delay.allCases, selection: lock.delay, title: \.title) { lock.delay = $0 }
                SetupNote(text: tr("How long Tidemark may stay in the background before it locks."))
            }
            SetupCard {
                SetupRowLabel(icon: "chart.pie.fill", color: .purple, title: tr("Portfolio lock")) {
                    Toggle("", isOn: Binding(get: { app.portfolioLockEnabled }, set: { app.portfolioLockEnabled = $0 }))
                        .labelsHidden()
                        .tint(.green)
                }
            }
            SetupNote(text: trf("Ask for %@ or the device passcode each time the Portfolio tab is opened.", lock.biometryName))
        }
    }
}

// MARK: - Backup

struct BackupSettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @State private var file: URL?
    @State private var restoring = false

    var body: some View {
        SetupPage(title: tr("Data Backup")) {
            SetupCard {
                Button { app.backUp(context) } label: {
                    SetupRowLabel(icon: "arrow.clockwise", color: .mint, title: tr("Back up now")) { EmptyView() }
                }
                .buttonStyle(.plain)
                SetupDivider()
                if let file {
                    ShareLink(item: file) {
                        SetupRowLabel(icon: "square.and.arrow.up.fill", color: .orange, title: tr("Share backup file")) {
                            Text(file.lastPathComponent).font(DS.caption).foregroundStyle(DS.textTertiary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { file = app.backupFile(context) } label: {
                        SetupRowLabel(icon: "doc.badge.arrow.up", color: .orange, title: tr("Export backup")) { EmptyView() }
                    }
                    .buttonStyle(.plain)
                }
                SetupDivider()
                Button { restoring = true } label: {
                    SetupRowLabel(icon: "clock.arrow.circlepath", color: .indigo, title: tr("Restore from backup…")) {
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
            }
            SetupNote(text: tr("Saved automatically on this iPhone (Files › On My iPhone › Tidemark › Backups), one file per day: holdings, every valuation, ledger records, accounts, rates and settings. Restoring merges the file in; nothing is deleted."))
            if let message = app.backupMessage {
                SetupNote(text: message)
            } else if let last = app.lastBackup {
                SetupNote(text: "\(tr("Last backup")) \(Fmt.relative(last))")
            }
        }
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { app.restoreBackup(from: url, into: context) }
        }
    }
}

// MARK: - iCloud

struct CloudSyncSettingsView: View {
    @Environment(CloudSync.self) private var sync: CloudSync?
    let storageError: String?

    var body: some View {
        SetupPage(title: tr("iCloud Sync")) {
            SetupCard {
                SyncStatusView()
                    .padding(.horizontal, 18)
                    .frame(minHeight: 56)
                if let last = sync?.lastActivity {
                    SetupDivider(inset: 18)
                    SetupRowLabel(title: tr("Last synced")) {
                        Text(Fmt.dateTime.string(from: last)).font(DS.caption).foregroundStyle(DS.textSecondary)
                    }
                }
                if let sync {
                    SetupDivider(inset: 18)
                    SetupRowLabel(title: tr("Sent / received")) {
                        Text("↑\(sync.sentCount) ↓\(sync.receivedCount)").font(DS.caption).foregroundStyle(DS.textSecondary)
                    }
                    SetupDivider(inset: 18)
                    Button { sync.fetchNow() } label: {
                        SetupRowLabel(title: tr("Sync now")) {
                            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(DS.accentText)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            SetupNote(text: tr("Records, accounts and presets sync with your other devices through your private iCloud database."))
            if let storageError {
                SetupNote(text: storageError)
            }
            if sync?.portfolioBlocked == true {
                SetupNote(text: tr("Portfolio sync is waiting for the iCloud schema."))
            }
        }
    }
}

// MARK: - Import

struct ImportDataView: View {
    @State private var picking = false
    @State private var reviewing: ImportFile?
    @State private var error: String?

    static let xlsx = UTType("org.openxmlformats.spreadsheetml.sheet") ?? UTType(filenameExtension: "xlsx") ?? .data

    var body: some View {
        SetupPage(title: tr("Import Data")) {
            SetupCard {
                Button { picking = true } label: {
                    SetupRowLabel(icon: "doc.badge.plus", color: .indigo, title: tr("Choose an iCost export (.xlsx)")) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(DS.textTertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            SetupNote(text: tr("In iCost: Settings → Export Data, then share the file to Tidemark or choose it here. Records already in Tidemark are skipped and records edited in iCost are updated, so importing a newer export adds only what changed."))
            if let error {
                SetupNote(text: error)
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [Self.xlsx]) { result in
            switch result {
            case .success(let url): reviewing = ImportFile(url: url)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .sheet(item: $reviewing) { LedgerImportReview(url: $0.url) }
    }
}

struct ImportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Shows what an import will do (added, updated, already there) and imports
/// on confirmation. Opened from Import Data and when a file is shared to the app.
struct LedgerImportReview: View {
    let url: URL
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var parsed: LedgerExportImporter.Parsed?
    @State private var preview: LedgerExportImporter.Stats?
    @State private var result: LedgerExportImporter.Stats?
    @State private var error: String?

    /// Reads the workbook while the file is accessible (Files, iCloud Drive, AirDrop, share sheet).
    static func read(_ url: URL) throws -> LedgerExportImporter.Parsed {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinated: Data?
        var failure: Error?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readable in
            do { coordinated = try Data(contentsOf: readable) } catch { failure = error }
        }
        if let failure { throw failure }
        if let coordinatorError { throw coordinatorError }
        return try LedgerExportImporter.parse(rows: try XLSXReader.firstSheetRows(of: coordinated ?? Data()))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    SetupCard {
                        SetupRowLabel(icon: "doc.fill", color: .indigo, title: url.lastPathComponent) { EmptyView() }
                    }
                    if let result {
                        SetupCard {
                            row(tr("Added"), result.inserted)
                            SetupDivider(inset: 18)
                            row(tr("Updated"), result.updated)
                            SetupDivider(inset: 18)
                            row(tr("Already there"), result.skipped)
                            SetupDivider(inset: 18)
                            row(tr("New accounts"), result.accountsCreated)
                        }
                        SetupNote(text: tr("Imported."))
                    } else if let preview {
                        SetupCard {
                            row(tr("To add"), preview.inserted)
                            SetupDivider(inset: 18)
                            row(tr("To update"), preview.updated)
                            SetupDivider(inset: 18)
                            row(tr("Already there"), preview.skipped)
                            SetupDivider(inset: 18)
                            row(tr("New accounts"), preview.accountsCreated)
                            if preview.rejected > 0 {
                                SetupDivider(inset: 18)
                                row(tr("Unreadable rows"), preview.rejected)
                            }
                            if preview.notInFile > 0 {
                                SetupDivider(inset: 18)
                                row(tr("Not in this file"), preview.notInFile)
                            }
                        }
                        if preview.updated > 0 {
                            SetupNote(text: tr("“To update” are records edited in iCost since they were imported; they are changed in place."))
                        }
                        if preview.notInFile > 0 {
                            SetupNote(text: tr("“Not in this file” are imported records this export no longer has (deleted in iCost?). Nothing is deleted."))
                        }
                    } else if error == nil {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    }
                    if let error {
                        SetupNote(text: error)
                    }
                }
                .padding(.horizontal, DS.phoneMargin)
                .padding(.bottom, 28)
            }
            .background(DS.page)
            .phoneHeader {
                PhoneHeader(title: tr("Import Data")) {
                    if result == nil { Button(tr("Cancel")) { dismiss() } }
                } trailing: {
                    if result != nil {
                        Button(tr("Done")) { dismiss() }.fontWeight(.semibold)
                    } else {
                        Button(tr("Import")) { commit() }
                            .fontWeight(.semibold)
                            .disabled(preview == nil || (preview?.inserted ?? 0) + (preview?.updated ?? 0) == 0)
                    }
                }
            }
        }
        .task { load() }
    }

    private func row(_ title: String, _ count: Int) -> some View {
        SetupRowLabel(title: title) {
            Text("\(count)").font(.system(size: 17).monospacedDigit()).foregroundStyle(DS.textSecondary)
        }
    }

    private func load() {
        do {
            let parsed = try Self.read(url)
            self.parsed = parsed
            preview = try LedgerExportImporter.preview(parsed, in: context)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func commit() {
        guard let parsed else { return }
        do {
            result = try LedgerExportImporter.commit(parsed, fileName: url.lastPathComponent, into: context)
        } catch {
            context.rollback()
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Export

struct ExportDataView: View {
    @Environment(AppState.self) private var app
    @Query private var transactions: [Transaction]
    @State private var onlyPeriod = false
    @State private var file: URL?
    @State private var error: String?

    private var selected: [Transaction] {
        let period = app.cashPeriod
        return transactions.filter { LedgerExportWriter.isExportable($0) && (!onlyPeriod || period.contains($0.date)) }
    }

    var body: some View {
        let count = selected.count
        SetupPage(title: tr("Export Data")) {
            SetupCard {
                SetupChoice(title: tr("All records"), selected: !onlyPeriod) { choose(false) }
                SetupDivider(inset: 18)
                SetupChoice(title: app.cashPeriod.title, selected: onlyPeriod) { choose(true) }
            }
            SetupNote(text: trf("%d records as iCost's import template (.xlsx): in iCost, Settings › Bill Import › Template Import; Tidemark imports it too. Expenses are net of refunds; investment records and balance adjustments are left out.", count))
            SetupCard {
                if let file {
                    ShareLink(item: file) {
                        SetupRowLabel(icon: "square.and.arrow.up.fill", color: .orange, title: tr("Share file")) {
                            Text(file.lastPathComponent).font(DS.caption).foregroundStyle(DS.textTertiary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { export() } label: {
                        SetupRowLabel(icon: "doc.badge.arrow.up", color: .orange, title: tr("Create export file")) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(DS.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(count == 0)
                }
            }
            if let error {
                SetupNote(text: error)
            }
        }
    }

    private func choose(_ period: Bool) {
        onlyPeriod = period
        file = nil
    }

    private func export() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(LedgerExportWriter.fileName())
        do {
            try LedgerExportWriter.workbook(for: selected).write(to: url, options: .atomic)
            file = url
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Appearance, currency, language

struct AppearanceSettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        SetupPage(title: tr("Appearance")) {
            SetupChoices(options: AppAppearance.allCases, selection: app.appearance, title: \.title) { app.appearance = $0 }
        }
    }
}

struct CurrencySettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        SetupPage(title: tr("Currency")) {
            SetupChoices(options: AppState.baseCurrencies, selection: app.baseCurrency,
                         title: { "\(Fmt.symbol(for: $0)) \($0)" }) { app.baseCurrency = $0 }
            SetupNote(text: tr("Totals and charts are shown in this currency."))
        }
    }
}

struct LanguageSettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        SetupPage(title: tr("Language Settings")) {
            SetupChoices(options: AppLanguage.allCases, selection: app.language, title: \.displayName) { app.language = $0 }
        }
    }
}
