import Foundation

#if DEBUG
/// Detects main-thread stalls by measuring how long a no-op takes to round-trip
/// through the main queue.
///
/// Guessing at hangs from reading code is unreliable — SwiftUI re-evaluates
/// bodies far more often than you expect, and a linear scan that looks harmless
/// at 60 items is a freeze at 60 000. This measures instead, and names the work
/// that was in flight when the stall happened.
enum MainThreadWatchdog {

    /// Anything longer than this is visible as a stutter; 400 ms is a hang.
    private static let warnThreshold: TimeInterval = 0.25
    private static let hangThreshold: TimeInterval = 0.8

    private static let queue = DispatchQueue(label: "watchdog", qos: .utility)
    nonisolated(unsafe) private static var running = false

    /// What the app believes it is doing, so a stall report can name it.
    nonisolated(unsafe) private static var context = "idle"
    private static let contextLock = NSLock()

    static func setContext(_ c: String) {
        contextLock.lock(); context = c; contextLock.unlock()
    }

    /// Wrap a suspect block to time it directly.
    @discardableResult
    static func measure<T>(_ name: String, _ body: () -> T) -> T {
        let t = CFAbsoluteTimeGetCurrent()
        let r = body()
        let dt = CFAbsoluteTimeGetCurrent() - t
        if dt > warnThreshold {
            NSLog("WATCHDOG ⚠️ %@ 占用主线程 %.0f ms", name, dt * 1000)
        }
        return r
    }

    static func start() {
        guard !running else { return }
        running = true
        queue.async {
            while running {
                let sent = CFAbsoluteTimeGetCurrent()
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }
                // Wait generously; the point is to measure the delay, not to give up.
                _ = sem.wait(timeout: .now() + 10)
                let waited = CFAbsoluteTimeGetCurrent() - sent
                if waited > hangThreshold {
                    contextLock.lock(); let c = context; contextLock.unlock()
                    NSLog("WATCHDOG 🔴 主线程卡住 %.0f ms（当时在做：%@）", waited * 1000, c)
                } else if waited > warnThreshold {
                    contextLock.lock(); let c = context; contextLock.unlock()
                    NSLog("WATCHDOG ⚠️ 主线程延迟 %.0f ms（%@）", waited * 1000, c)
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }
}
#endif
