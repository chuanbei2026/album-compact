import Foundation
import BackgroundTasks

/// Finishing the Vision pass in the background.
///
/// On a real 12 930-photo library the classification stage is 13–19 minutes of
/// Neural Engine work. Asking the user to hold the app open for that is not a
/// plan, so the remainder is registered as a `BGProcessingTask`.
///
/// What is actually true about this, stated plainly because it is easy to
/// over-promise:
///
/// * **The Neural Engine is available in a background processing task.** Vision
///   requests run there the same as in the foreground.
/// * **iOS decides when.** `BGProcessingTaskRequest` is discretionary: the system
///   typically runs it while the device is charging and idle, often overnight.
///   There is no schedule you can rely on and no way to force it.
/// * **It can be cut off at any moment.** The expiration handler may fire with
///   little warning, so the work has to be resumable — it is: every fingerprint
///   and every feature print is cached per asset, so a killed run simply leaves
///   less to do next time.
/// * It never runs if the user force-quits the app, and never before the app has
///   been launched at least once.
enum BackgroundWork {

    static let refreshID = "com.xiangyang.albumcompact.finishScan"

    private(set) nonisolated(unsafe) static var lastOutcome: String?

    /// Must be called before the app finishes launching.
    static func register(runner: @escaping (@escaping () -> Bool) -> Void) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshID, using: nil
        ) { task in
            var expired = false
            task.expirationHandler = {
                expired = true
                lastOutcome = String(localized: "被系统中断（已处理的部分已缓存）")
            }
            // The runner polls `shouldContinue` and stops cooperatively.
            runner { !expired }
            if !expired { lastOutcome = String(localized: "后台跑完了") }
            task.setTaskCompleted(success: !expired)
            schedule()      // ask for another slot; there may be more to do
        }
    }

    /// Ask for a slot. Called when the app goes to the background with work left.
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: refreshID)
        // The whole pipeline is offline, so no network is needed.
        request.requiresNetworkConnectivity = false
        // Vision on thousands of photos is real work; only ask for it on power.
        // Set false and iOS will still mostly pick charging windows, but being
        // explicit keeps it off the user's battery.
        request.requiresExternalPower = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            #if DEBUG
            NSLog("ALBUMCOMPACT 已申请后台处理时段")
            #endif
        } catch {
            #if DEBUG
            NSLog("ALBUMCOMPACT 后台申请失败: %@", error.localizedDescription)
            #endif
        }
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshID)
    }
}
