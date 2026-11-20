import Foundation
import QuartzCore

enum PerfLog {
    nonisolated(unsafe) static var lines: [String] = []

    @discardableResult
    static func time<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        #if DEBUG
        let start = CACurrentMediaTime()
        defer {
            lines.append(String(format: "%@ %.0f ms", label, (CACurrentMediaTime() - start) * 1000))
            if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        }
        #endif
        return try work()
    }
}
