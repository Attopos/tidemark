import SwiftUI
import AppKit
import Observation

// MARK: - App state
//
// The app does exactly two things: show the portfolio, and update it from
// Alipay screenshots. State is accordingly
// tiny: the UI language and the OCR import pipeline.

@Observable
final class AppState {
    /// Display currency for all aggregates. Original amounts are preserved.
    let baseCurrency = "CNY"

    /// UI language — switches live, no relaunch.
    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
            L10n.current = language
        }
    }

    // Alipay OCR import flow
    var pendingOCRImages: [NSImage] = []
    var ocrImportPresented = false

    init() {
        let savedLanguage = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        self.language = AppLanguage(rawValue: savedLanguage) ?? .english
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
