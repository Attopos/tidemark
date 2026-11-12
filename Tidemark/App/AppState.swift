import SwiftUI
import AppKit
import Observation
import SwiftData
import UniformTypeIdentifiers
import LocalAuthentication

// MARK: - App state
//
// Two halves share one window: long-term holdings (the portfolio, updated
// from Alipay / Binance screenshots) and day-to-day cash flow (the ledger,
// its accounts and analysis). State here is the page on screen, the display
// currency, the UI language and the import pipelines.

/// Pages of the main window.
enum AppSection: String, CaseIterable, Identifiable {
    case ledger, accounts, analysis, portfolio, settings

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

    /// Page on screen; remembered across launches (the portfolio is not:
    /// it is locked, so the app opens on the ledger).
    var section: AppSection {
        didSet {
            UserDefaults.standard.set(section.rawValue, forKey: "appSection")
            if oldValue == .portfolio && section != .portfolio { lockPortfolio() }
        }
    }

    var appearance: AppAppearance = AppAppearance.saved {
        didSet {
            appearance.save()
            Task { @MainActor in self.applyAppearance() }
        }
    }

    @MainActor
    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: Portfolio lock
    //
    // Holdings are looked at rarely and are the most private figures, so the
    // portfolio page asks for the Mac's login password (or Touch ID) each
    // time it is opened. Leaving the page or the app locks it again. Nothing
    // is stored: the check is the system's own (LocalAuthentication).

    private(set) var portfolioUnlocked = false
    private(set) var unlockMessage: String?
    /// A screenshot dropped while locked opens the import once unlocked.
    private var importAfterUnlock = false

    func lockPortfolio() {
        portfolioUnlocked = false
        importAfterUnlock = false
    }

    @MainActor
    func unlockPortfolio() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            unlockMessage = error?.localizedDescription ?? tr("This Mac cannot check a password.")
            return
        }
        do {
            portfolioUnlocked = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                                 localizedReason: tr("unlock the portfolio"))
            unlockMessage = nil
            if portfolioUnlocked && importAfterUnlock {
                importAfterUnlock = false
                ocrImportPresented = true
            }
        } catch {
            let quiet: [LAError.Code] = [.userCancel, .systemCancel, .appCancel]
            unlockMessage = (error as? LAError).map { quiet.contains($0.code) } == true ? nil : error.localizedDescription
        }
    }

    /// Open the screenshot import, unlocking the portfolio first if needed.
    @MainActor
    func openScreenshotImport() {
        if portfolioUnlocked {
            ocrImportPresented = true
        } else {
            importAfterUnlock = true
            section = .portfolio
        }
    }

    /// Eye toggle: every amount shows as dots (for screens others can see).
    var amountsHidden: Bool = UserDefaults.standard.bool(forKey: "amountsHidden") {
        didSet {
            UserDefaults.standard.set(amountsHidden, forKey: "amountsHidden")
            Fmt.amountsHidden = amountsHidden
        }
    }

    /// The add-record sheet from the floating button (or ⌘N).
    var addingRecord = false
    /// A receipt screenshot read into a draft, waiting in the editor.
    var pendingReceipt: PendingReceipt?

    /// Read a receipt screenshot into a new record (the editor opens).
    @MainActor
    func importReceipt(url: URL, context: ModelContext) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        Task { @MainActor in
            let draft = await ReceiptImport.draft(from: cgImage, context: context)
            pendingReceipt = PendingReceipt(draft: draft)
        }
    }

    @MainActor
    func pickReceipt(context: ModelContext) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importReceipt(url: url, context: context)
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
        let savedSection = AppSection(rawValue: UserDefaults.standard.string(forKey: "appSection") ?? "") ?? .ledger
        self.section = savedSection == .portfolio ? .ledger : savedSection
        L10n.current = self.language
        Fmt.amountsHidden = UserDefaults.standard.bool(forKey: "amountsHidden")
    }

    /// Route a dropped/picked image into the OCR flow.
    func routeImport(url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "heic", "tiff", "webp"].contains(ext),
              let image = NSImage(contentsOf: url) else { return }
        pendingOCRImages = [image]
        Task { @MainActor in openScreenshotImport() }
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
        .init(baseCurrency: baseCurrency, language: language.rawValue)
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
            backupMessage = trf("Restored: %d added, %d updated", stats.added, stats.updated)
            backupFailed = false
        } catch {
            context.rollback()
            backupMessage = trf("Restore failed: %@", error.localizedDescription)
            backupFailed = true
        }
    }
}
