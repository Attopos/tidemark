import SwiftUI
import AppKit
import Observation

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
}
