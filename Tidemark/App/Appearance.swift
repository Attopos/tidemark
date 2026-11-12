import SwiftUI

/// Light, dark, or whatever the system uses. Chosen in Settings, per device.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return tr("System")
        case .light: return tr("Light")
        case .dark: return tr("Dark")
        }
    }

    /// Nil follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    static var saved: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
    }

    func save() { UserDefaults.standard.set(rawValue, forKey: "appearance") }
}
