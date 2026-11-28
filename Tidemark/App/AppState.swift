import SwiftUI
#if os(macOS)
import AppKit
#endif
import Observation
import SwiftData
import UniformTypeIdentifiers
import LocalAuthentication

enum AppSection: String, CaseIterable, Identifiable {
    case ledger, accounts, analysis, portfolio, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portfolio: return tr("Portfolio")
        case .ledger: return tr("Ledger")
        case .accounts: return tr("Assets")
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
    static let baseCurrencies = ["CNY", "USD"]

    var baseCurrency: String {
        didSet { UserDefaults.standard.set(baseCurrency, forKey: "baseCurrency") }
    }

    var defaultExpenseAccountID: UUID? = DefaultAccounts.id(for: .expense) {
        didSet { DefaultAccounts.set(defaultExpenseAccountID, for: .expense) }
    }

    var defaultIncomeAccountID: UUID? = DefaultAccounts.id(for: .income) {
        didSet { DefaultAccounts.set(defaultIncomeAccountID, for: .income) }
    }

    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
            L10n.current = language
        }
    }

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
        #if os(macOS)
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        #endif
    }

    var portfolioLockEnabled: Bool = UserDefaults.standard.bool(forKey: "portfolioLockEnabled") {
        didSet {
            UserDefaults.standard.set(portfolioLockEnabled, forKey: "portfolioLockEnabled")
            if !portfolioLockEnabled { portfolioUnlocked = true } else { lockPortfolio() }
        }
    }

    private(set) var portfolioUnlocked = !UserDefaults.standard.bool(forKey: "portfolioLockEnabled")
    private(set) var unlockMessage: String?
    private var importAfterUnlock = false

    func lockPortfolio() {
        guard portfolioLockEnabled else { return }
        portfolioUnlocked = false
        importAfterUnlock = false
    }

    @MainActor
    func unlockPortfolio() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            #if os(macOS)
            unlockMessage = error?.localizedDescription ?? tr("This Mac cannot check a password.")
            #else
            unlockMessage = error?.localizedDescription ?? tr("Set a passcode on this device first.")
            #endif
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

    @MainActor
    func openScreenshotImport() {
        if portfolioUnlocked {
            ocrImportPresented = true
        } else {
            importAfterUnlock = true
            section = .portfolio
        }
    }

    var amountsHidden: Bool = UserDefaults.standard.bool(forKey: "amountsHidden") {
        didSet {
            UserDefaults.standard.set(amountsHidden, forKey: "amountsHidden")
            Fmt.amountsHidden = amountsHidden
        }
    }

    var addingRecord = false
    var pendingReceipt: PendingReceipt?

    @MainActor
    func importReceipt(url: URL, context: ModelContext) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let image = PlatformImage.load(url), let cgImage = image.cgImageValue else { return }
        Task { @MainActor in
            let draft = await ReceiptImport.draft(from: cgImage, context: context)
            pendingReceipt = PendingReceipt(draft: draft)
        }
    }

    #if os(macOS)
    @MainActor
    func pickReceipt(context: ModelContext) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importReceipt(url: url, context: context)
    }
    #endif

    var cashPeriod = CashPeriod(unit: .month, containing: Date())

    var ledgerImportMessage: String?
    var ledgerImportFailed = false

    var lastBackup: Date?
    var backupMessage: String?
    var backupFailed = false

    var pendingOCRImages: [PlatformImage] = []
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

    func routeImport(url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "heic", "tiff", "webp"].contains(ext),
              let image = PlatformImage.load(url) else { return }
        pendingOCRImages = [image]
        Task { @MainActor in openScreenshotImport() }
    }

    @MainActor
    func importLedgerExport(url: URL, into context: ModelContext) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let stats = try LedgerExportImporter.importFile(at: url, into: context)
            var message = trf("Imported %d records, %d already there", stats.inserted, stats.skipped)
            if stats.updated > 0 { message += " · " + trf("%d updated", stats.updated) }
            if stats.accountsCreated > 0 { message += " · " + trf("%d accounts created", stats.accountsCreated) }
            if stats.rejected > 0 { message += " · " + trf("%d rows could not be read", stats.rejected) }
            message += "\n" + tr("iCost exports carry records but not account balances. If a balance differs from iCost, set it in Assets › ⋯ › Reconcile.")
            ledgerImportMessage = message
            ledgerImportFailed = false
            if stats.inserted > 0 { section = .ledger }
        } catch {
            context.rollback()
            ledgerImportMessage = trf("Import failed: %@", error.localizedDescription)
            ledgerImportFailed = true
        }
    }

    #if os(macOS)
    @MainActor
    func pickLedgerExport(into context: ModelContext) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importLedgerExport(url: url, into: context)
    }
    #endif

    #if os(macOS)
    @MainActor
    func exportLedger(from context: ModelContext) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx")].compactMap { $0 }
        panel.nameFieldStringValue = LedgerExportWriter.fileName()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let records = try context.fetch(FetchDescriptor<Transaction>())
            try LedgerExportWriter.workbook(for: records).write(to: url, options: .atomic)
            ledgerImportMessage = trf("Exported %d records", records.filter(LedgerExportWriter.isExportable).count)
            ledgerImportFailed = false
        } catch {
            ledgerImportMessage = trf("Export failed: %@", error.localizedDescription)
            ledgerImportFailed = true
        }
    }
    #endif

    private var backupSettings: BackupFile.Settings {
        .init(baseCurrency: baseCurrency, language: language.rawValue)
    }

    @MainActor
    func backUp(_ context: ModelContext) {
        guard !TidemarkSchema.isTesting else { return }
        let container = context.container
        let settings = backupSettings
        let previous = backupTask
        backupTask = Task.detached(priority: .utility) { [weak self] in
            await previous?.value
            let outcome: Result<Bool, Error> = Result {
                let backup = try BackupService.makeBackup(from: ModelContext(container), settings: settings)
                guard !backup.holdings.isEmpty || !(backup.transactions ?? []).isEmpty else { return false }
                _ = try BackupService.writeBackup(backup, to: BackupService.automaticFolder)
                return true
            }
            await MainActor.run {
                guard let self else { return }
                switch outcome {
                case .success(let wrote):
                    guard wrote else { return }
                    self.lastBackup = Date()
                    self.backupMessage = nil
                    self.backupFailed = false
                case .failure(let error):
                    self.backupMessage = trf("Backup failed: %@", error.localizedDescription)
                    self.backupFailed = true
                }
            }
        }
    }
    @ObservationIgnored private var backupTask: Task<Void, Never>?

    @MainActor
    func backupFile(_ context: ModelContext) -> URL? {
        do {
            let backup = try BackupService.makeBackup(from: context, settings: backupSettings)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(BackupService.fileName())
            try BackupService.encode(backup).write(to: url, options: .atomic)
            backupMessage = nil
            backupFailed = false
            return url
        } catch {
            backupMessage = trf("Backup failed: %@", error.localizedDescription)
            backupFailed = true
            return nil
        }
    }

    @MainActor
    func restoreBackup(from url: URL, into context: ModelContext) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
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

    #if os(macOS)
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

    @MainActor
    func restoreBackup(_ context: ModelContext) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.directoryURL = BackupService.automaticFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        restoreBackup(from: url, into: context)
    }
    #endif
}
