import Foundation
import Photos
import UIKit

enum ScanStage: Equatable {
    case idle
    case readingLibrary(done: Int, total: Int)
    case fingerprinting(done: Int, total: Int)
    case grouping
    case classifying(done: Int, total: Int, eta: TimeInterval?)
    case finished

    var isRunning: Bool {
        switch self { case .idle, .finished: return false; default: return true }
    }

    /// Remaining time, from measured throughput rather than a guess. On a real
    /// 12 930-photo library the Vision stage is 13–19 minutes; leaving the user to
    /// wonder how long a spinner will spin is the actual problem.
    var eta: TimeInterval? {
        if case .classifying(_, _, let e) = self { return e }
        return nil
    }

    var etaText: String? {
        guard let e = eta, e > 1 else { return nil }
        if e < 90 { return "约 \(Int(e)) 秒" }
        if e < 3600 { return "约 \(Int((e / 60).rounded())) 分钟" }
        return String(format: "约 %.1f 小时", e / 3600)
    }

    var label: String {
        switch self {
        case .idle:                       return String(localized: "待开始")
        case .readingLibrary:             return String(localized: "读取相册")
        case .fingerprinting:             return String(localized: "计算指纹（pHash）")
        case .grouping:                   return String(localized: "归并重复组")
        case .classifying:                return String(localized: "识别截图类型（神经引擎）")
        case .finished:                   return String(localized: "完成")
        }
    }

    var fraction: Double? {
        switch self {
        case .readingLibrary(let d, let t),
             .fingerprinting(let d, let t):
            return t == 0 ? nil : Double(d) / Double(t)
        case .classifying(let d, let t, _):
            return t == 0 ? nil : Double(d) / Double(t)
        default: return nil
        }
    }
}

/// Drives the whole analysis in four stages, cheapest first, so the UI has
/// something useful to show within a second or two:
///
///   1. read library      metadata only, no pixels           — instant
///   2. fingerprint       one 96px decode per photo          — the bulk of the time
///   3. group             multi-index hash + union-find      — pure CPU, milliseconds
///   4. classify          Vision OCR + FeaturePrint on ANE   — screenshots only, lazy
///
/// Stages 1–3 give the duplicate results. Stage 4 streams categories in behind
/// them, so the user can already be swiping while it finishes.
final class ScanEngine {

    private let work = DispatchQueue(label: "scan.engine", qos: .userInitiated)
    private var cancelled = false

    var onStage: ((ScanStage) -> Void)?
    var onSnapshots: (([AssetSnapshot]) -> Void)?
    var onDuplicates: (([DuplicateGroup]) -> Void)?
    var onCandidates: (([Candidate]) -> Void)?
    var onLog: ((String) -> Void)?

    /// Set by a background task; polled in the same places as `cancelled`, so a
    /// system expiration stops the run at the next asset boundary instead of
    /// being killed mid-write.
    var shouldContinue: (() -> Bool)?

    func cancel() { cancelled = true }

    private var stopRequested: Bool {
        if cancelled { return true }
        if let c = shouldContinue, !c() { return true }
        return false
    }

    func start(settings: AppSettings) {
        cancelled = false
        work.async { [weak self] in self?.run(settings: settings) }
    }

    // MARK: pipeline

    private func run(settings: AppSettings) {
        let t0 = Date()
        let store = Store.shared

        // ---- stage 1: metadata ----
        emit(.readingLibrary(done: 0, total: 0))
        let fetch = PhotoLibraryService.shared.fetchAllAssets()
        let total = fetch.count
        emit(.readingLibrary(done: 0, total: total))

        var snapshots: [AssetSnapshot] = []
        snapshots.reserveCapacity(total)
        var assets: [PHAsset] = []
        assets.reserveCapacity(total)
        fetch.enumerateObjects { asset, idx, stop in
            if self.cancelled { stop.pointee = true; return }
            assets.append(asset)
            snapshots.append(PhotoLibraryService.makeSnapshot(asset))
            if idx % 400 == 0 { self.emit(.readingLibrary(done: idx, total: total)) }
        }
        guard !cancelled else { return emit(.idle) }
        log("读取 \(snapshots.count) 项，用时 \(fmt(t0))")
        publishSnapshots(snapshots)
        store.pruneCaches(livingIDs: Set(snapshots.map(\.id)))

        // ---- stage 2: fingerprints (parallel, cache-aware) ----
        let needHash: [Int] = (0..<snapshots.count).filter {
            !snapshots[$0].isVideo && store.fingerprints[snapshots[$0].id] == nil
        }
        emit(.fingerprinting(done: 0, total: needHash.count))
        let t1 = Date()

        var fresh = [String: Fingerprint]()
        if !needHash.isEmpty {
            let lock = NSLock()
            var completed = 0
            // Chunked so each worker amortises its autorelease pool over ~24
            // decodes; one pool per image would thrash, one per chunk is right.
            let chunkSize = 24
            let chunks = stride(from: 0, to: needHash.count, by: chunkSize).map {
                Array(needHash[$0..<min($0 + chunkSize, needHash.count)])
            }
            DispatchQueue.concurrentPerform(iterations: chunks.count) { c in
                if self.cancelled { return }
                var local = [String: Fingerprint]()
                autoreleasepool {
                    for i in chunks[c] {
                        if self.cancelled { return }
                        let asset = assets[i]
                        guard let cg = ThumbnailProvider.shared.hashingImage(for: asset),
                              let fp = PerceptualHasher.fingerprint(from: cg) else { continue }
                        local[snapshots[i].id] = fp
                    }
                }
                lock.lock()
                fresh.merge(local) { _, b in b }
                completed += chunks[c].count
                let done = completed
                lock.unlock()
                if c % 4 == 0 {
                    self.emit(.fingerprinting(done: done, total: needHash.count))
                }
            }
            guard !cancelled else { return emit(.idle) }
            store.mergeFingerprints(fresh)
            log("新算 \(fresh.count) 个指纹，用时 \(fmt(t1))（缓存命中 \(snapshots.count - needHash.count)）")
        } else {
            log("指纹全部命中缓存")
        }

        let fingerprints = store.fingerprints
        log("指纹表共 \(fingerprints.count) 条；待去重 \(snapshots.filter { !$0.isVideo }.count) 张图")

        // ---- stage 3: duplicate grouping ----
        emit(.grouping)
        let t2 = Date()
        var thresholds = DuplicateThresholds.default
        // The copy thresholds are fixed by measurement and are not user-tunable —
        // loosening them only manufactures false pairs. The slider moves the
        // moment window, which is a genuine judgement call: how far apart can two
        // shots be and still count as "the same moment"?
        let slack = 1.0 - settings.similarityStrictness
        thresholds.momentWindow = 5 + slack * 35          // 5 s … 40 s

        let pool = settings.includeVideos ? snapshots : snapshots.filter { !$0.isVideo }
        let eligible = pool.filter { !store.protectedIDs.contains($0.id) }
        var groups = DuplicateFinder.findGroups(snapshots: eligible,
                                                fingerprints: fingerprints,
                                                thresholds: thresholds,
                                                protectedIDs: store.protectedIDs)
        if settings.rules.skipFavorites {
            // A group where every extra copy is a favourite has nothing to offer.
            groups = groups.filter { !$0.discardable.allSatisfy(\.isFavorite) }
        }
        // Sizes were estimated during the fast metadata pass. Refine the ones the
        // user is about to read — the headline "可回收 X GB" has to be true — but
        // only those: an exact size costs ~1 ms per asset.
        // Every member, not just the discardable ones. The review screen puts the
        // keeper's size next to the others as evidence that they are the same
        // file — an estimate sitting beside exact values makes that evidence look
        // like it disproves the claim.
        let shownIDs = Array(Set(groups.flatMap { $0.members.map(\.id) }))
        if !shownIDs.isEmpty {
            let tExact = Date()
            let exact = PhotoLibraryService.shared.exactSizes(for: shownIDs)
            if !exact.isEmpty {
                for i in snapshots.indices {
                    if let s = exact[snapshots[i].id] { snapshots[i].byteSize = s }
                }
                groups = groups.map { g in
                    var g = g
                    g.members = g.members.map { m in
                        var m = m
                        if let s = exact[m.id] { m.byteSize = s }
                        return m
                    }
                    return g
                }
                log("精修 \(exact.count) 项的精确体积，用时 \(fmt(tExact))")
            }
        }
        publishDuplicates(groups)
        let copies = groups.filter { !$0.tier.needsPicking }.count
        let moments = groups.count - copies
        log("重复副本 \(copies) 组 · 同一时刻 \(moments) 组，可回收 \(ByteFormat.string(groups.reduce(0) { $0 + $1.reclaimableBytes }))，用时 \(fmt(t2))")
        #if DEBUG
        if DebugLaunch.verboseScan {
            for g in groups where g.tier.needsPicking {
                NSLog("ALBUMCOMPACT moment-group %d 张:", g.members.count)
                for m in g.members.sorted(by: { $0.creationDate < $1.creationDate }) {
                    NSLog("ALBUMCOMPACT    %@  %@  %dx%d",
                          m.filename,
                          ISO8601DateFormatter().string(from: m.creationDate),
                          m.pixelWidth, m.pixelHeight)
                }
            }
        }
        #endif
        if DuplicateFinder.lastDroppedRunCount > 0 {
            log("有 \(DuplicateFinder.lastDroppedRunCount) 段时间相邻的照片过多/跨度过长，判定为批量导入而非连拍，已跳过")
        }

        // ---- stage 4: screenshot classification, streamed ----
        let idsInGroups = Set(groups.flatMap { $0.discardable.map(\.id) })
        let triageTargets = snapshots.filter {
            eligibleForTriage($0, rules: settings.rules,
                              protectedIDs: store.protectedIDs,
                              alreadyQueued: idsInGroups)
        }
        log("可进入队列的候选 \(triageTargets.count) / \(snapshots.count)（重复组已占 \(idsInGroups.count)）")
        emit(.classifying(done: 0, total: triageTargets.count, eta: nil))
        let t3 = Date()

        var assetByID = [String: PHAsset]()
        for (i, s) in snapshots.enumerated() { assetByID[s.id] = assets[i] }

        var visionFresh = [String: VisionFeatures]()
        var batch: [Candidate] = []
        var done = 0

        for snap in triageTargets {
            if stopRequested { break }
            autoreleasepool {
                var vf = store.visionCache[snap.id]
                if vf == nil, let asset = assetByID[snap.id],
                   let cg = ThumbnailProvider.shared.analysisImage(for: asset) {
                    vf = VisionAnalyzer.analyze(cg)
                    if let vf { visionFresh[snap.id] = vf }
                }
                let fp = fingerprints[snap.id]
                let (ruleCat, ruleConf, reasons) =
                    RuleClassifier.classify(snapshot: snap, fingerprint: fp, vision: vf)

                var category = ruleCat
                var confidence = ruleConf
                var why = reasons

                if settings.enableLearning,
                   let e = vf?.embedding {
                    let (fused, conf, usedModel) =
                        store.classifier.fuse(rule: (ruleCat, ruleConf), embedding: e)
                    if usedModel {
                        category = fused
                        confidence = conf
                        why.append("你之前的选择让模型改判为「\(fused.title)」")
                    } else {
                        confidence = max(confidence, conf * 0.9)
                    }
                }

                #if DEBUG
                if DebugLaunch.verboseScan {
                let L = vf?.layout
                NSLog("ALBUMCOMPACT cls %@ -> %@ %.2f | 行=%d 文字=%.3f 双峰=%.2f 成对=%.2f 右贴=%.2f 数字=%.2f | flat=%.2f sat=%.2f edge=%.2f bright=%.2f sharp=%.2f | %dx%d screenshot=%@",
                      snap.filename, category.rawValue, confidence,
                      L?.lineCount ?? -1, L?.textAreaFraction ?? -1,
                      L?.alignmentBimodality ?? -1, L?.pairedRowFraction ?? -1,
                      L?.rightHuggingFraction ?? -1, L?.digitFraction ?? -1,
                      fp?.flatness ?? -1, fp?.saturation ?? -1, fp?.edgeDensity ?? -1,
                      fp?.brightness ?? -1, fp?.sharpness ?? -1,
                      snap.pixelWidth, snap.pixelHeight, snap.isScreenshot ? "Y" : "N")
                }
                #endif

                guard confidence >= 0.35, category.isDeletionCandidate else { return }
                if settings.rules.skipDocuments && category == .documentShot { return }

                batch.append(Candidate(snapshot: snap, category: category,
                                       confidence: confidence, reasons: why))
            }
            done += 1
            if batch.count >= 24 {
                let exact = PhotoLibraryService.shared.exactSizes(for: batch.map(\.snapshot.id))
                if !exact.isEmpty {
                    for i in batch.indices {
                        if let s = exact[batch[i].snapshot.id] { batch[i].snapshot.byteSize = s }
                    }
                }
                publishCandidates(batch); batch = []
                store.mergeVision(visionFresh); visionFresh = [:]
                let elapsed = Date().timeIntervalSince(t3)
                let rate = done > 0 ? elapsed / Double(done) : 0
                let remaining = Double(triageTargets.count - done) * rate
                emit(.classifying(done: done, total: triageTargets.count,
                                  eta: rate > 0 ? remaining : nil))
            }
        }
        if !batch.isEmpty {
            let exact = PhotoLibraryService.shared.exactSizes(for: batch.map(\.snapshot.id))
            for i in batch.indices {
                if let s = exact[batch[i].snapshot.id] { batch[i].snapshot.byteSize = s }
            }
            publishCandidates(batch)
        }
        store.mergeVision(visionFresh)
        log("分类 \(done) 张截图，用时 \(fmt(t3))")
        Store.shared.flushDirty()      // one write at the end, not one per batch
        log("全流程 \(fmt(t0))")
        emit(cancelled ? .idle : .finished)
    }

    // MARK: eligibility

    private func eligibleForTriage(_ s: AssetSnapshot,
                                   rules: ProtectionRules,
                                   protectedIDs: Set<String>,
                                   alreadyQueued: Set<String>) -> Bool {
        if protectedIDs.contains(s.id) { return false }
        if alreadyQueued.contains(s.id) { return false }
        if rules.skipFavorites && s.isFavorite { return false }
        if rules.skipWithLocation && s.hasLocation { return false }
        if rules.skipLivePhotos && s.isLivePhoto { return false }
        if rules.skipEdited && s.hasAdjustments { return false }
        if rules.skipRecentDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(rules.skipRecentDays) * 86_400)
            if s.creationDate > cutoff { return false }
        }
        // Only bother running Vision where there's a plausible reason to.
        if s.isScreenRecording { return true }
        if s.isVideo { return false }
        if s.isPanorama || s.isPortrait { return false }
        return true
    }

    // MARK: plumbing

    private func emit(_ s: ScanStage) { DispatchQueue.main.async { self.onStage?(s) } }
    private func log(_ m: String) {
        #if DEBUG
        NSLog("ALBUMCOMPACT %@", m)
        #endif
        DispatchQueue.main.async { self.onLog?(m) }
    }
    private func publishSnapshots(_ v: [AssetSnapshot]) {
        DispatchQueue.main.async { self.onSnapshots?(v) }
    }
    private func publishDuplicates(_ v: [DuplicateGroup]) {
        DispatchQueue.main.async { self.onDuplicates?(v) }
    }
    private func publishCandidates(_ v: [Candidate]) {
        DispatchQueue.main.async { self.onCandidates?(v) }
    }
    private func fmt(_ start: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(start))
    }
}

// MARK: - Formatting

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        // ByteCountFormatter renders 0 as the rather odd "Zero KB".
        guard bytes > 0 else { return "0 MB" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useGB, .useMB, .useKB]
        return f.string(fromByteCount: max(0, bytes))
    }
}
