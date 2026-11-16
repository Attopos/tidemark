#if DEBUG
import SwiftUI
import QuartzCore
import UIKit
import SwiftData

/// TIDEMARK_PERF=1: switches tabs by itself and logs the longest main-thread
/// stall after each switch to Application Support/perf.log.
@MainActor
final class PerfProbe: NSObject {
    static var isOn: Bool { ProcessInfo.processInfo.environment["TIDEMARK_PERF"] != nil }
    static var shotsOn: Bool { ProcessInfo.processInfo.environment["TIDEMARK_SHOTS"] != nil }
    static var entryOn: Bool { ProcessInfo.processInfo.environment["TIDEMARK_PERF_ENTRY"] != nil }
    static let openEntry = Notification.Name("probe.openEntry")
    static let entryKey = Notification.Name("probe.entryKey")
    static var importTestOn: Bool { ProcessInfo.processInfo.environment["TIDEMARK_IMPORT_TEST"] != nil }

    /// TIDEMARK_IMPORT_TEST=1: reads Documents/import-test.xlsx the way Import
    /// Data does, imports it into an empty in-memory store, previews it against
    /// the real store (read-only), and writes the counts to import-test.txt.
    func importTest(store: ModelContext) async {
        var lines: [String] = []
        let url = URL.documentsDirectory.appending(path: "import-test.xlsx")
        do {
            let parsed = try LedgerImportReview.read(url)
            lines.append("rows \(parsed.rows.count) rejected \(parsed.rejected.count)")
            let scratch = ModelContext(try TidemarkSchema.makeContainer(inMemory: true))
            let fresh = try LedgerExportImporter.commit(parsed, fileName: url.lastPathComponent, into: scratch)
            lines.append("in-memory: added \(fresh.inserted) updated \(fresh.updated) skipped \(fresh.skipped) accounts \(fresh.accountsCreated) records \(try scratch.fetchCount(FetchDescriptor<Transaction>()))")
            let real = try LedgerExportImporter.preview(parsed, in: store)
            lines.append("real-store preview: add \(real.inserted) update \(real.updated) skip \(real.skipped) not-in-file \(real.notInFile) new accounts \(real.accountsCreated) records now \(try store.fetchCount(FetchDescriptor<Transaction>()))")
        } catch {
            lines.append("error \(error)")
        }
        try? lines.joined(separator: "\n").write(to: URL.applicationSupportDirectory.appending(path: "import-test.txt"),
                                                  atomically: true, encoding: .utf8)
    }

    /// TIDEMARK_SHOTS=1: one PNG per tab (amounts hidden) in Application Support.
    func shoot(app: AppState) async {
        try? await Task.sleep(for: .seconds(5))
        let hidden = app.amountsHidden
        app.amountsHidden = true
        for section in AppSection.allCases {
            app.section = section
            try? await Task.sleep(for: .milliseconds(1500))
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else { continue }
            let data = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try? data.write(to: URL.applicationSupportDirectory.appending(path: "shot-\(section.rawValue).png"))
        }
        app.amountsHidden = hidden
        app.section = .ledger
    }

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var worst: CFTimeInterval = 0
    private var stalled: CFTimeInterval = 0

    @objc private func tick(_ link: CADisplayLink) {
        if last > 0 {
            let gap = link.timestamp - last
            worst = max(worst, gap)
            if gap > 0.05 { stalled += gap }
        }
        last = link.timestamp
    }

    private func measure(wait: Int = 1500, _ work: () -> Void) async -> (worst: Double, stalled: Double, firstFrame: Double) {
        last = 0; worst = 0; stalled = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        let start = CACurrentMediaTime()
        work()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
        let firstFrame = CACurrentMediaTime() - start
        try? await Task.sleep(for: .milliseconds(wait))
        link.invalidate()
        return (worst * 1000, stalled * 1000, firstFrame * 1000)
    }

    /// TIDEMARK_PERF_ENTRY=1: opens quick entry, taps categories and keys
    /// (never saves) and logs each tap's worst frame to perf-entry.log.
    func runEntry(app: AppState) async {
        try? await Task.sleep(for: .seconds(6))
        app.section = .ledger
        try? await Task.sleep(for: .seconds(1))
        var lines = ["perf-entry \(Date())"]
        let open = await measure { NotificationCenter.default.post(name: Self.openEntry, object: nil) }
        lines.append(String(format: "open: worst %.0f ms, stalled %.0f ms", open.worst, open.stalled))
        let keys = ["cat:0", "1", "2", ".", "5", "+×", "3", "cat:1", "cat:2", "8", "⌫", "−÷", "4", "cat:3", "9", "9",
                    "noop", "noop", "noop", "noop", "noop", "noop", "noop", "noop"]
        var worstKey = 0.0, sum = 0.0
        for key in keys {
            let r = await measure(wait: 500) { NotificationCenter.default.post(name: Self.entryKey, object: key) }
            worstKey = max(worstKey, r.worst); sum += r.worst
            lines.append(String(format: "%@: worst %.0f ms", key, r.worst))
        }
        lines.append(String(format: "taps: mean worst %.0f ms, max %.0f ms", sum / Double(keys.count), worstKey))
        NotificationCenter.default.post(name: Self.entryKey, object: "cat:0")
        try? await Task.sleep(for: .milliseconds(600))
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            for (i, window) in scene.windows.enumerated() {
                let data = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try? data.write(to: URL.applicationSupportDirectory.appending(path: "entry-shot-\(i).png"))
            }
        }
        let url = URL.applicationSupportDirectory.appending(path: "perf-entry.log")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func run(app: AppState) async {
        try? await Task.sleep(for: .seconds(6))
        var lines = ["perf \(Date())"]
        let order: [AppSection] = [.accounts, .portfolio, .analysis, .settings, .ledger]
        for round in 1...3 {
            for section in order {
                let result = await measure { app.section = section }
                lines.append(String(format: "round %d %@: worst frame %.0f ms, stalled %.0f ms, first %.0f ms",
                                    round, section.rawValue, result.worst, result.stalled, result.firstFrame))
            }
        }
        let url = URL.applicationSupportDirectory.appending(path: "perf.log")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
