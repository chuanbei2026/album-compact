import SwiftUI

@main
struct AlbumCompactApp: App {
    @State private var model = AppModel()

    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        MainThreadWatchdog.start()
        #endif
        // Read the screen scale once, here, while we are provably on the main
        // actor — the scan's background workers need it and must not touch UIKit.
        ThumbnailProvider.displayScale = UIScreen.main.scale
        // Must be registered before launch finishes, so it cannot wait for
        // `.task` — hence the model reference is captured lazily inside.
        let m = model
        BackgroundWork.register { shouldContinue in
            m.runScanForBackgroundTask(shouldContinue: shouldContinue)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    // Ships with the binary; nothing is fetched.
                    Store.shared.seedFromBundledLibrary()
                    #if DEBUG
                    if DebugLaunch.benchMain > 0 {
                        try? await Task.sleep(for: .seconds(3))
                        MainThreadBench.run(model: model, count: DebugLaunch.benchMain)
                        return
                    }
                    if DebugLaunch.seedHistory { Store.shared.seedDemoHistory() }
                    if DebugLaunch.seedApps {
                        // Embeddings are unavailable on the Simulator, so the
                        // clustering that normally feeds this screen cannot run.
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(12))
                            Store.shared.seedDemoAppLabels(from: model.snapshots)
                            model.refreshAppClusters()
                        }
                    }
                    if DebugLaunch.dumpAssetMeta { AssetMetadataProbe.run() }
                    #endif
                    // A fresh launch with permission already granted goes
                    // straight to scanning; cached fingerprints make it quick.
                    if model.auth == .authorized || model.auth == .limited {
                        model.refreshPending()
                        model.scan()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .background else { return }
                    Store.shared.flushDirty()
                    if model.hasBackgroundWorkLeft { BackgroundWork.schedule() }
                }
        }
    }
}
