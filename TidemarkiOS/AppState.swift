import SwiftUI
import Observation

// MARK: - App state (iPhone)
//
// The iPhone app is the cash-flow half of Tidemark: the ledger, its accounts
// and the analysis, kept in step with the Mac through iCloud. Its state is
// the display currency, the UI language and the period on screen.

@Observable
final class AppState {
    static let baseCurrencies = ["CNY", "USD"]

    var baseCurrency: String {
        didSet { UserDefaults.standard.set(baseCurrency, forKey: "baseCurrency") }
    }

    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
            L10n.current = language
        }
    }

    var appearance: AppAppearance = AppAppearance.saved {
        didSet { appearance.save() }
    }

    /// Eye toggle: every amount shows as dots (for screens others can see).
    var amountsHidden: Bool = UserDefaults.standard.bool(forKey: "amountsHidden") {
        didSet {
            UserDefaults.standard.set(amountsHidden, forKey: "amountsHidden")
            Fmt.amountsHidden = amountsHidden
        }
    }

    /// Month or year the Ledger and Analysis pages show.
    var cashPeriod = CashPeriod(unit: .month, containing: Date())

    init() {
        let savedLanguage = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        self.language = AppLanguage(rawValue: savedLanguage) ?? .english
        let savedBase = UserDefaults.standard.string(forKey: "baseCurrency") ?? ""
        self.baseCurrency = Self.baseCurrencies.contains(savedBase) ? savedBase : "CNY"
        L10n.current = self.language
        Fmt.amountsHidden = UserDefaults.standard.bool(forKey: "amountsHidden")
    }
}
