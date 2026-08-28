import Foundation

/// DEBUG-only deep link driven by a launch argument, so a screen can be opened
/// directly from the command line:
///
///     xcrun simctl launch <device> com.xiangyang.albumcompact -demoRoute deck
///
/// The simulator has no scriptable tap, so without this every UI change would
/// need a human to navigate to it before it could be checked.
enum DebugLaunch {
    /// `-demoSwipes 3` performs three left-swipes (mark for deletion) after the
    /// deck opens, so the decision pipeline — mark, byte accounting, session
    /// summary, pending tray — can be smoke-tested without a human finger.
    static var swipes: Int {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demoSwipes"), i + 1 < args.count,
              let n = Int(args[i + 1]) else { return 0 }
        return n
        #else
        return 0
        #endif
    }

    /// `-verboseScan` prints one line per analysed asset with every feature the
    /// classifier saw. This is how a wrong label gets diagnosed — the verdict
    /// alone never says which signal misfired.
    static var verboseScan: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-verboseScan")
        #else
        return false
        #endif
    }

    /// `-demoAutoBack 8` pops the deck after 8 s. This exists to test one specific
    /// regression: tapping back while the scan is still streaming candidates used
    /// to be immediately undone by the auto-route, which looked exactly like a
    /// dead back button. There is no scriptable tap in the simulator, so the only
    /// way to prove the fix is to trigger the dismissal from code.
    static var autoBack: Double {
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-demoAutoBack"), i + 1 < a.count,
              let v = Double(a[i + 1]) else { return 0 }
        return v
        #else
        return 0
        #endif
    }

    /// `-seedHistory` fills the dashboard with plausible synthetic history.
    static var seedHistory: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-seedHistory")
        #else
        return false
        #endif
    }

    static var dumpAssetMeta: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-dumpAssetMeta")
        #else
        return false
        #endif
    }

    static var seedApps: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-seedApps")
        #else
        return false
        #endif
    }

    /// `-benchMain 50000` times every main-thread-bound operation at that
    /// library size.
    static var benchMain: Int {
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-benchMain"), i + 1 < a.count,
              let n = Int(a[i + 1]) else { return 0 }
        return n
        #else
        return 0
        #endif
    }

    static var route: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demoRoute"), i + 1 < args.count else { return nil }
        return args[i + 1]
        #else
        return nil
        #endif
    }
}
