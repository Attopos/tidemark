import SwiftUI
import AppKit
import Observation
import SwiftData
import UniformTypeIdentifiers

// MARK: - App state
//
// Two halves share one window: long-term holdings (the portfolio, updated
// from Alipay / Binance screenshots) and day-to-day cash flow (the ledger,
// its accounts and analysis). State here is the page on screen, the display
// currency, the UI language and the import pipelines.

/// Pages of the main window.
enum AppSection: String, CaseIterable, Identifiable {
    case portfolio, ledger, accounts, analysis, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portfolio: return tr("Portfolio")
        case .ledger: return tr("Ledger")
        case .accounts: return tr("Accounts")
        case .analysis: return tr("Analysis")
        case .settings: return tr("Settings")
        }
    }

    var icon: String {
        switch self {
        case .portfolio: return "chart.pie.fill"
        case .ledger: return "list.bullet.rectangle.fill"
        case .accounts: return "square.stack.3d.up.fill"
        case .analysis: return "chart.bar.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

@Observable
final class AppState {
    /// Display currencies offered for totals and allocation.
    static let baseCurrencies = ["CNY", "USD"]

    /// Display currency for totals and allocation (CNY by default). Each
    /// holding is still recorded in its own currency.
    var baseCurrency: String {
        didSet { UserDefaults.standard.set(baseCurrency, forKey: "baseCurrency") }
    }

    /// UI language — switches live, no relaunch.
    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
            L10n.current = language
        }
    }

    /// Target weight per exposure (Exposure.rawValue → fraction, 0.30 = 30%).
    /// Empty means no targets; the board then shows no drift.
    var targets: [String: Double] {
        didSet { UserDefaults.standard.set(targets, forKey: "targetAllocation") }
    }

    func target(for exposure: Exposure) -> Double? {
        guard let value = targets[exposure.rawValue], value > 0 else { return nil }
        return value
    }

    /// Page on screen; remembered across launches.
    var section: AppSection {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: "appSection") }
    }

    /// Month or year the Ledger and Analysis pages show.
    var cashPeriod = CashPeriod(unit: .month, containing: Date())

    /// Result of the last bookkeeping-export import, for Settings and the banner.
    var ledgerImportMessage: String?
    var ledgerImportFailed = false

    // Backup (see BackupService)
    var lastBackup: Date?
    /// Why the last automatic backup or restore failed, or what a restore did.
    var backupMessage: String?
    var backupFailed = false

    // Alipay OCR import flow
    var pendingOCRImages: [NSImage] = []
    var ocrImportPresented = false

    init() {
        let savedLanguage = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        self.language = AppLanguage(rawValue: savedLanguage) ?? .english
        let savedBase = UserDefaults.standard.string(forKey: "baseCurrency") ?? ""
        self.baseCurrency = Self.baseCurrencies.contains(savedBase) ? savedBase : "CNY"
        self.targets = (UserDefaults.standard.dictionary(forKey: "targetAllocation") as? [String: Double]) ?? [:]
        self.section = AppSection(rawValue: UserDefaults.standard.string(forKey: "appSection") ?? "") ?? .portfolio
        L10n.current = self.language
    }

    /// Route a dropped/picked image into the OCR flow.
    func routeImport(url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "heic", "tiff", "webp"].contains(ext),
              let image = NSImage(contentsOf: url) else { return }
        pendingOCRImages = [image]
        ocrImportPresented = true
    }

    // MARK: Bookkeeping export

    /// Import a bookkeeping export (.xlsx). Rows already in the ledger are skipped.
    @MainActor
    func importLedgerExport(url: URL, into context: ModelContext) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let stats = try LedgerExportImporter.importFile(at: url, into: context)
            var message = trf("Imported %d records, %d already there", stats.inserted, stats.skipped)
            if stats.accountsCreated > 0 { message += " · " + trf("%d accounts created", stats.accountsCreated) }
            if stats.rejected > 0 { message += " · " + trf("%d rows could not be read", stats.rejected) }
            ledgerImportMessage = message
            ledgerImportFailed = false
            if stats.inserted > 0 { section = .ledger }
        } catch {
            context.rollback()
            ledgerImportMessage = trf("Import failed: %@", error.localizedDescription)
            ledgerImportFailed = true
        }
    }

    @MainActor
    func pickLedgerExport(into context: ModelContext) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importLedgerExport(url: url, into: context)
    }

    // MARK: Backup & restore

    private var backupSettings: BackupFile.Settings {
        .init(baseCurrency: baseCurrency, language: language.rawValue, targets: targets)
    }

    /// Write today's backup to iCloud Drive › Tidemark. An empty store is
    /// never backed up: on a new device that would shadow the real backup.
    @MainActor
    func backUp(_ context: ModelContext) {
        do {
            let backup = try BackupService.makeBackup(from: context, settings: backupSettings)
            guard !backup.holdings.isEmpty || !(backup.transactions ?? []).isEmpty else { return }
            try BackupService.writeBackup(backup, to: BackupService.automaticFolder)
            lastBackup = Date()
            backupMessage = nil
            backupFailed = false
        } catch {
            backupMessage = trf("Backup failed: %@", error.localizedDescription)
            backupFailed = true
        }
    }

    /// Save a backup wherever the user chooses.
    @MainActor
    func exportBackup(_ context: ModelContext) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = BackupService.fileName()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let backup = try BackupService.makeBackup(from: context, settings: backupSettings)
            try BackupService.encode(backup).write(to: url, options: .atomic)
            backupMessage = nil
            backupFailed = false
        } catch {
            backupMessage = trf("Backup failed: %@", error.localizedDescription)
            backupFailed = true
        }
    }

    /// Pick a backup file and merge it into the store (nothing is deleted).
    @MainActor
    func restoreBackup(_ context: ModelContext) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.directoryURL = BackupService.automaticFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let backup = try BackupService.decode(try Data(contentsOf: url))
            let stats = try BackupService.restore(backup, into: context)
            if let code = backup.settings.baseCurrency, Self.baseCurrencies.contains(code) { baseCurrency = code }
            if let raw = backup.settings.language, let restored = AppLanguage(rawValue: raw) { language = restored }
            if let restored = backup.settings.targets { targets = restored }
            backupMessage = trf("Restored: %d added, %d updated", stats.added, stats.updated)
            backupFailed = false
        } catch {
            context.rollback()
            backupMessage = trf("Restore failed: %@", error.localizedDescription)
            backupFailed = true
        }
    }
}
