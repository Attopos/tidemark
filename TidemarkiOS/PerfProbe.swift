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
    static let openDetail = Notification.Name("probe.openDetail")
    static let openAccountEditor = Notification.Name("probe.openAccountEditor")
    static let pushAccountType = Notification.Name("probe.pushAccountType")
    static let entryKey = Notification.Name("probe.entryKey")
    static let openField = Notification.Name("probe.openField")
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
        app.amountsHidden = ProcessInfo.processInfo.environment["TIDEMARK_SHOTS_AMOUNTS"] == nil
        func capture(_ name: String) {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
            for (index, window) in scene.windows.enumerated() where !window.isHidden {
                let data = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try? data.write(to: URL.applicationSupportDirectory.appending(path: "shot-\(name)-\(index).png"))
            }
        }
        for section in AppSection.allCases {
            app.section = section
            try? await Task.sleep(for: .milliseconds(1500))
            capture(section.rawValue)
        }
        app.section = .ledger
        try? await Task.sleep(for: .milliseconds(1000))
        NotificationCenter.default.post(name: Self.openDetail, object: nil)
        try? await Task.sleep(for: .milliseconds(1500))
        capture("detail")
        for field in ["type", "remark", "account"] {
            NotificationCenter.default.post(name: Self.openField, object: field)
            try? await Task.sleep(for: .milliseconds(1500))
            capture("field-\(field)")
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
                .first?.presentedViewController?.dismiss(animated: false)
            try? await Task.sleep(for: .milliseconds(600))
        }
        if ProcessInfo.processInfo.environment["TIDEMARK_SHOTS_ENTRY"] != nil {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
                .first?.dismiss(animated: false)
            try? await Task.sleep(for: .milliseconds(800))
            NotificationCenter.default.post(name: Self.openEntry, object: nil)
            try? await Task.sleep(for: .milliseconds(1500))
            capture("entry")
        }
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first?.dismiss(animated: false)
        app.section = .accounts
        try? await Task.sleep(for: .milliseconds(1200))
        NotificationCenter.default.post(name: Self.openAccountEditor, object: nil)
        try? await Task.sleep(for: .milliseconds(1500))
        capture("account-new")
        NotificationCenter.default.post(name: Self.pushAccountType, object: nil)
        try? await Task.sleep(for: .milliseconds(1500))
        capture("account-form")
        app.amountsHidden = hidden
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
    var probeContext: ModelContext?

    func runEntry(app: AppState, context: ModelContext? = nil) async {
        probeContext = context
        try? await Task.sleep(for: .seconds(6))
        if let tabs = ProcessInfo.processInfo.environment["TIDEMARK_PERF_TABS"] {
            let all: [AppSection] = [.accounts, .portfolio, .analysis, .settings]
            for section in all where tabs == "1" || tabs.contains(section.rawValue) {
                app.section = section
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        app.section = .ledger
        try? await Task.sleep(for: .seconds(1))
        var lines = ["perf-entry \(Date())"]
        if let context {
            let leftover = (try? context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.note == "perf-probe" }))) ?? []
            leftover.forEach(context.delete)
            if !leftover.isEmpty { try? context.save() }
            lines.append("leftover probe records removed: \(leftover.count)")
        }
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
        PerfLog.lines.removeAll()
        let post: (String) -> Void = { NotificationCenter.default.post(name: Self.entryKey, object: $0) }
        post("cat:0"); post("⌫"); post("⌫"); post("⌫"); post("⌫"); post("⌫"); post("⌫"); post("1")
        try? await Task.sleep(for: .milliseconds(300))
        let againAnim = await measure(wait: 450) { post("save") }
        let again = await measure(wait: 2600) {}
        lines.append(String(format: "save (again): during badge %.0f ms; after: worst %.0f ms, stalled %.0f ms", againAnim.worst, again.worst, again.stalled))
        for key in ["2", "3", ".", "5"] {
            let r = await measure(wait: 200) { post(key) }
            lines.append(String(format: "after-save %@: worst %.0f ms", key, r.worst))
        }
        let doneAnim = await measure(wait: 380) { post("done") }
        let done = await measure(wait: 3000) {}
        lines.append(String(format: "save (done+dismiss): during dismiss %.0f ms; after: worst %.0f ms, stalled %.0f ms", doneAnim.worst, done.worst, done.stalled))
        lines.append(contentsOf: PerfLog.lines.map { "  " + $0 })
        if let context = probeContext {
            let probe = (try? context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.note == "perf-probe" }))) ?? []
            probe.forEach(context.delete)
            try? context.save()
            lines.append("deleted \(probe.count) probe records")
        }
        try? await Task.sleep(for: .milliseconds(800))
        post("noop")
        for key in ["cat:0", "sub:0", "⌫", "⌫", "⌫", "⌫", "⌫", "⌫", "⌫", "⌫", "⌫", "⌫"] {
            NotificationCenter.default.post(name: Self.entryKey, object: key)
            try? await Task.sleep(for: .milliseconds(150))
        }
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
