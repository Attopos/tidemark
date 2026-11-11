import SwiftUI
import AppKit
import Observation
import SwiftData
import UniformTypeIdentifiers

// MARK: - App state
//
// The app does exactly two things: show the portfolio, and update it from
// Alipay / Binance screenshots. State is accordingly
// tiny: the UI language and the OCR import pipeline.

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
            guard !backup.holdings.isEmpty else { return }
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
