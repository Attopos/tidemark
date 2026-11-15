import SwiftUI
import LocalAuthentication
import Observation

@MainActor
@Observable
final class AppLock {
    enum Delay: Int, CaseIterable, Identifiable {
        case immediately = 0
        case oneMinute = 60
        case fiveMinutes = 300

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .immediately: return tr("Immediately")
            case .oneMinute: return tr("After 1 minute")
            case .fiveMinutes: return tr("After 5 minutes")
            }
        }
    }

    private(set) var enabled = UserDefaults.standard.bool(forKey: "appLockEnabled")
    private(set) var locked = UserDefaults.standard.bool(forKey: "appLockEnabled")
    private(set) var message: String?
    var delay = Delay(rawValue: UserDefaults.standard.integer(forKey: "appLockDelay")) ?? .immediately {
        didSet { UserDefaults.standard.set(delay.rawValue, forKey: "appLockDelay") }
    }
    private var backgroundedAt: Date?
    private var authenticating = false

    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return tr("Passcode")
        }
    }

    var biometryIcon: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.fill"
        }
    }

    func setEnabled(_ on: Bool) async {
        guard on != enabled else { return }
        guard await authenticate(reason: on ? tr("turn on app lock") : tr("turn off app lock")) else { return }
        enabled = on
        locked = false
        UserDefaults.standard.set(on, forKey: "appLockEnabled")
    }

    func sceneChanged(to phase: ScenePhase) {
        switch phase {
        case .background:
            if enabled && !locked && backgroundedAt == nil { backgroundedAt = Date() }
        case .active:
            if enabled, let since = backgroundedAt, Date().timeIntervalSince(since) >= Double(delay.rawValue) {
                locked = true
            }
            backgroundedAt = nil
            if locked { Task { await unlock() } }
        default:
            break
        }
    }

    func unlock() async {
        guard locked, !authenticating else { return }
        if await authenticate(reason: tr("unlock Tidemark")) { locked = false }
    }

    private func authenticate(reason: String) async -> Bool {
        authenticating = true
        defer { authenticating = false }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            message = error?.localizedDescription ?? tr("Set a passcode on this device first.")
            return false
        }
        do {
            let passed = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            message = nil
            return passed
        } catch {
            let quiet: [LAError.Code] = [.userCancel, .systemCancel, .appCancel]
            message = (error as? LAError).map { quiet.contains($0.code) } == true ? nil : error.localizedDescription
            return false
        }
    }
}

struct LockScreenView: View {
    @Environment(AppLock.self) private var lock

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(DS.heroInk)
                .frame(width: 72, height: 72)
                .background(DS.accent)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text(tr("Tidemark is locked"))
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(DS.textPrimary)
            if let message = lock.message {
                Text(message)
                    .font(DS.caption)
                    .foregroundStyle(DS.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
            Button {
                Task { await lock.unlock() }
            } label: {
                Label(trf("Unlock with %@", lock.biometryName), systemImage: lock.biometryIcon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DS.heroInk)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(DS.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DS.phoneMargin)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.page.ignoresSafeArea())
    }
}

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            Image(systemName: "lock.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(DS.textSecondary)
        }
    }
}
