import SwiftUI

/// One line saying whether iCloud sync is on and when it last moved data.
struct SyncStatusView: View {
    @Environment(CloudSync.self) private var sync: CloudSync?

    private var text: String {
        guard let sync else { return tr("iCloud sync is off (local database could not be opened).") }
        switch sync.phase {
        case .off(let reason): return "\(tr("iCloud sync is off.")) \(reason)"
        case .failed(let reason): return reason
        case .syncing: return tr("Syncing…")
        case .idle:
            guard let last = sync.lastActivity else { return tr("iCloud sync is on.") }
            return "\(tr("Synced")) \(Fmt.relative(last)) · ↑\(sync.sentCount) ↓\(sync.receivedCount)"
        }
    }

    private var healthy: Bool {
        guard let sync else { return false }
        switch sync.phase {
        case .idle, .syncing: return true
        case .off, .failed: return false
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: healthy ? "checkmark.icloud" : "exclamationmark.icloud")
                .foregroundStyle(healthy ? DS.accentText : DS.warning)
            Text(text)
                .foregroundStyle(DS.textSecondary)
            Spacer()
            if healthy {
                Button(tr("Sync now")) { sync?.fetchNow() }
            }
        }
        .font(DS.caption)
    }
}
