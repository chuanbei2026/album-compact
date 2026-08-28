import Foundation
import Photos

#if DEBUG
/// Times the operations that run on the main thread, at a library size worth
/// worrying about. The Simulator's 67-photo library hides every one of these;
/// a real library is three orders of magnitude larger.
enum MainThreadBench {

    static func run(model: AppModel, count: Int) {
        NSLog("BENCH ===== 模拟 %d 张相册 =====", count)

        // Fabricate a library of the right shape: mostly screenshots, since those
        // are what every expensive path iterates over.
        var snaps: [AssetSnapshot] = []
        snaps.reserveCapacity(count)
        for i in 0..<count {
            let isShot = i % 3 != 0
            snaps.append(AssetSnapshot(
                id: "bench/\(i)",
                creationDate: Date(timeIntervalSince1970: 1_600_000_000 + Double(i) * 37),
                modificationDate: Date(timeIntervalSince1970: 1_600_000_000),
                pixelWidth: isShot ? 1179 : 4032,
                pixelHeight: isShot ? 2556 : 3024,
                byteSize: Int64(200_000 + (i % 900) * 5_000),
                isFavorite: i % 97 == 0, isHidden: false,
                hasLocation: !isShot, isVideo: false, duration: 0,
                burstID: nil, subtypes: 0, filename: "IMG_\(i).PNG"))
        }

        time("赋值 snapshots（含建索引）") { model.snapshots = snaps }

        // Candidates: roughly a fifth of a real library ends up in the queue.
        let cands = stride(from: 0, to: count, by: 5).map { i in
            Candidate(snapshot: snaps[i],
                      category: [.chatScreenshot, .gameScreenshot, .screenshot][i % 3],
                      confidence: 0.4 + Double(i % 50) / 100,
                      reasons: ["bench"])
        }
        NSLog("BENCH 候选 %d 个", cands.count)

        time("counts(for:) × 9 个类目") {
            for c in CleanupCategory.allCases { _ = model.counts(for: c) }
        }
        time("activeCategories") { _ = model.activeCategories }

        time("QueuePriority.sorted") {
            _ = QueuePriority.sorted(cands, vision: Store.shared.visionCache,
                                     model: Store.shared.deletability)
        }

        // Fabricating 26 000 × 768 floats is itself seconds of work, so it happens
        // off the main thread — otherwise the benchmark's own setup shows up as an
        // app hang. (It did, twice, before this was fixed.)
        let dim = 768
        let queue = DispatchQueue.global(qos: .utility)
        queue.async {
            var vision: [String: VisionFeatures] = [:]
            for (k, s) in snaps.enumerated() where k % 3 != 0 {
                var v = [Float](repeating: 0, count: dim)
                let cluster = k % 40
                for d in 0..<dim {
                    v[d] = Float(sin(Double(d) * 0.11 + Double(cluster))) + Float(k % 7) * 0.002
                }
                vision[s.id] = VisionFeatures(layout: TextLayout(),
                                              embedding: Embedding(values: v).normalized,
                                              labels: [])
            }
            NSLog("BENCH 向量 %d 条（后台构造完成）", vision.count)

            let items: [(id: String, embedding: Embedding, bytes: Int64)] =
                vision.compactMap { k, v in v.embedding.map { (k, $0, Int64(0)) } }
            let t = CFAbsoluteTimeGetCurrent()
            let r = AppClustering.cluster(items, against: [])
            let ms = (CFAbsoluteTimeGetCurrent() - t) * 1000
            NSLog("BENCH %@ 聚类 %d 个向量  %.0f ms（%d 簇，后台线程）",
                  ms > 4000 ? "🔴" : "✅", items.count, ms, r.clusters.count)
        }

        // PhotoKit lookups: one per visible image, currently on the main thread.
        let realIDs = PhotoLibraryService.shared.snapshot(
            PhotoLibraryService.shared.fetchAllAssets()).prefix(40).map(\.id)
        if !realIDs.isEmpty {
            time("PHAsset.fetchAssets × \(realIDs.count)（每张图一次）") {
                for id in realIDs { _ = PhotoLibraryService.shared.asset(for: id) }
            }
        }

        NSLog("BENCH ===== 结束 =====")
    }

    private static func time(_ name: String, _ body: () -> Void) {
        let t = CFAbsoluteTimeGetCurrent()
        body()
        let ms = (CFAbsoluteTimeGetCurrent() - t) * 1000
        NSLog("BENCH %@ %-34@ %8.1f ms",
              ms > 100 ? "🔴" : (ms > 16 ? "⚠️" : "  "), name as NSString, ms)
    }
}
#endif
