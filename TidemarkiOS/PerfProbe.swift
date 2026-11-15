#if DEBUG
import SwiftUI
import QuartzCore

/// TIDEMARK_PERF=1: switches tabs by itself and logs the longest main-thread
/// stall after each switch to Application Support/perf.log.
@MainActor
final class PerfProbe: NSObject {
    static var isOn: Bool { ProcessInfo.processInfo.environment["TIDEMARK_PERF"] != nil }

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

    private func measure(_ work: () -> Void) async -> (worst: Double, stalled: Double, firstFrame: Double) {
        last = 0; worst = 0; stalled = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        let start = CACurrentMediaTime()
        work()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
        let firstFrame = CACurrentMediaTime() - start
        try? await Task.sleep(for: .milliseconds(1500))
        link.invalidate()
        return (worst * 1000, stalled * 1000, firstFrame * 1000)
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
