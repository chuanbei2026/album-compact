import Foundation
import SwiftUI
import Photos
import UserNotifications

/// What the user did with a card.
///
/// The vertical axis is the only destructive one: up deletes, down undoes. Both
/// horizontal directions keep the photo and differ only in permanence, so a
/// mis-swipe left/right can never lose anything — the worst case is being asked
/// again, or not being asked again.
enum Decision: String, Sendable {
    case delete        // ↑  mark for deletion
    case keepOnce      // ←  keep this time; may be proposed again later
    case whitelist     // →  never propose this photo again

    var keepsPhoto: Bool { self != .delete }
}

@Observable
final class AppModel {

    // MARK: library state

    var auth: LibraryAuthState = PhotoLibraryService.shared.authState
    var stage: ScanStage = .idle
    var logs: [String] = []

    var snapshots: [AssetSnapshot] = [] {
        didSet { snapshotIndex = Dictionary(snapshots.map { ($0.id, $0) },
                                            uniquingKeysWith: { a, _ in a }) }
    }
    var duplicateGroups: [DuplicateGroup] = []
    var candidates: [Candidate] = []

    /// Which members of a group the user wants to keep. A single keeper was too
    /// rigid: two similar shots are often *both* worth keeping, and there was no
    /// way to say so. Absent an entry, the algorithm's proposal is used.
    var keepSelection: [String: Set<String>] = [:]  // groupID → asset ids to keep

    // MARK: deck state

    var deck: [Candidate] = []
    var deckIndex = 0
    var deckDecisions: [String: Decision] = [:]
    var deckCategory: CleanupCategory?
    var sessionMarkedBytes: Int64 = 0
    var sessionKeptCount = 0
    var sessionWhitelistCount = 0

    // MARK: settings / pending

    var settings: AppSettings = Store.shared.settings {
        didSet { Store.shared.update(settings: settings) }
    }
    var pendingCount: Int = Store.shared.pending.count
    var pendingBytes: Int64 = Store.shared.pendingBytes

    var lastDeletionMessage: String?

    // MARK: history

    var history: [DeletionEvent] { Store.shared.history }
    var librarySnapshots: [LibrarySnapshot] { Store.shared.librarySnapshots }
    var lifetimeBytes: Int64 { Store.shared.lifetimeDeletedBytes }
    var lifetimeCount: Int { Store.shared.lifetimeDeletedCount }

    /// Freed bytes per category across all runs, highest first.
    var freedByCategory: [(category: CleanupCategory, bytes: Int64, count: Int)] {
        var bytes: [String: Int64] = [:]
        var count: [String: Int] = [:]
        for e in Store.shared.history {
            for (k, v) in e.bytesByCategory { bytes[k, default: 0] += v }
            for (k, v) in e.countByCategory { count[k, default: 0] += v }
        }
        return bytes.compactMap { key, v -> (CleanupCategory, Int64, Int)? in
            guard let c = CleanupCategory(rawValue: key) else { return nil }
            return (c, v, count[key] ?? 0)
        }
        .sorted { $0.1 > $1.1 }
        .map { (category: $0.0, bytes: $0.1, count: $0.2) }
    }

    /// The library reading immediately before the first cleanup, so the dashboard
    /// can state the change honestly rather than implying we caused all of it.
    var librarySizeChange: (from: Int64, to: Int64)? {
        guard let first = Store.shared.librarySnapshots.first,
              let last = Store.shared.librarySnapshots.last,
              first.date != last.date else { return nil }
        return (first.bytes, last.bytes)
    }

    // MARK: app labels

    var appClusters: [AppCluster] = []
    /// assetID → label name, rebuilt after each clustering pass.
    private(set) var appLabelByAsset: [String: String] = [:]
    var appLabels: [AppLabel] { Store.shared.appLabels }

    /// Regroup unlabeled screenshots and re-resolve which app each one belongs to.
    /// Cheap enough to run on every scan: greedy clustering is linear in photos
    /// and the cluster count stays tiny.
    private var clusteringInFlight = false

    /// Clustering is O(n × clusters × dim) and was measured at 21.9 s on a
    /// 26 000-screenshot library. It must never run on the main thread — gather
    /// the inputs here, do the work on a background queue, publish the result back.
    func refreshAppClusters() {
        guard !clusteringInFlight else { return }
        let vision = Store.shared.visionCache
        var items: [(id: String, embedding: Embedding, bytes: Int64)] = []
        for s in snapshots where DuplicateFinder.isScreenLike(s) {
            guard let e = vision[s.id]?.embedding else { continue }
            items.append((s.id, e, s.byteSize))
        }
        guard !items.isEmpty else {
            appClusters = []; appLabelByAsset = [:]; return
        }
        let labels = Store.shared.appLabels
        clusteringInFlight = true

        Task.detached(priority: .utility) {
            var byAsset: [String: String] = [:]
            var unlabeled: [(id: String, embedding: Embedding, bytes: Int64)] = []
            for it in items {
                if let (label, _) = AppClustering.match(it.embedding, labels: labels) {
                    byAsset[it.id] = label.name
                } else {
                    unlabeled.append(it)
                }
            }
            let clusters = AppClustering.cluster(unlabeled, against: labels).clusters
            await MainActor.run {
                self.appLabelByAsset = byAsset
                self.appClusters = clusters
                self.clusteringInFlight = false
            }
        }
    }

    func appName(for assetID: String) -> String? { appLabelByAsset[assetID] }

    func label(named name: String) -> AppLabel? {
        Store.shared.appLabels.first { $0.name == name }
    }

    /// Policy for one asset, derived from its app label.
    func appPolicy(for assetID: String) -> AppLabel? {
        guard let n = appLabelByAsset[assetID] else { return nil }
        return label(named: n)
    }

    /// Name a cluster — and train the category head on **every member of it**.
    ///
    /// This is the answer to the head's cold-start problem. Screenshots from one
    /// app sit at cosine 0.95+ of each other, so a cluster is already a set of
    /// same-label examples. One naming action therefore delivers hundreds of
    /// labelled samples, which is what moves the head from "no idea" to
    /// "confidently right" without the user tagging photos one at a time.
    func nameCluster(_ c: AppCluster, as name: String, category: CleanupCategory?) {
        Store.shared.nameCluster(c, as: name, category: category)

        if let category {
            let vision = Store.shared.visionCache
            var trained = 0
            // Several passes: one gradient step per sample is not enough to move
            // a 768-dimensional head, and the whole cluster is only a few hundred
            // vectors, so this is milliseconds.
            for _ in 0..<6 {
                for id in c.memberIDs.shuffled() {
                    guard let e = vision[id]?.embedding else { continue }
                    Store.shared.learn(embedding: e, label: category)
                    trained += 1
                }
            }
            Store.shared.flushClassifier()
            #if DEBUG
            NSLog("ALBUMCOMPACT 命名「%@」→ 用 %d 张训练类别头（%d 次梯度步）",
                  name, c.memberIDs.count, trained)
            #endif
            // Re-label everything the head now recognises.
            reclassifyWithHead()
        }
        refreshAppClusters()
    }

    /// Re-run the fusion over existing candidates so a freshly trained head takes
    /// effect immediately, instead of only on the next full scan.
    func reclassifyWithHead() {
        let vision = Store.shared.visionCache
        let head = Store.shared.classifier
        guard head.isWarm else { return }
        var changed = 0
        for i in candidates.indices {
            guard let e = vision[candidates[i].id]?.embedding else { continue }
            let (fused, conf, usedModel) =
                head.fuse(rule: (candidates[i].category, candidates[i].confidence),
                          embedding: e)
            if usedModel, fused != candidates[i].category {
                candidates[i].category = fused
                candidates[i].confidence = conf
                candidates[i].reasons = ["按你标注过的同类截图判断"]
                changed += 1
            }
        }
        if changed > 0 {
            candidates = QueuePriority.sorted(candidates, vision: vision,
                                              model: Store.shared.deletability)
        }
        #if DEBUG
        NSLog("ALBUMCOMPACT 类别头重判了 %d 张", changed)
        #endif
    }

    private let engine = ScanEngine()

    init() {
        engine.onStage = { [weak self] s in
            guard let self else { return }
            stage = s
            if s == .finished {
                Store.shared.recordLibrarySnapshot(assetCount: libraryCount,
                                                    bytes: libraryBytes)
                refreshAppClusters()
            }
        }
        engine.onSnapshots = { [weak self] v in self?.snapshots = v }
        engine.onDuplicates = { [weak self] g in self?.duplicateGroups = g }
        engine.onCandidates = { [weak self] c in self?.appendCandidates(c) }
        engine.onLog = { [weak self] m in
            guard let self else { return }
            logs.append(m)
            if logs.count > 40 { logs.removeFirst(logs.count - 40) }
        }
    }

    // MARK: derived numbers

    var libraryBytes: Int64 { snapshots.reduce(0) { $0 + $1.byteSize } }
    var libraryCount: Int { snapshots.count }

    /// Byte-for-byte the same picture: nothing to choose, genuinely safe to sweep.
    var identicalGroups: [DuplicateGroup] { duplicateGroups.filter { $0.tier == .identical } }
    /// The same shot, but the versions differ — one is higher resolution, or less
    /// compressed. Which to keep (or whether to keep both) is a real decision, so
    /// these are never swept; they go to the picker.
    var variantGroups: [DuplicateGroup] { duplicateGroups.filter { $0.tier == .copy } }
    /// Everything that is not "pick one of several different photos".
    var copyGroups: [DuplicateGroup] { duplicateGroups.filter { !$0.tier.needsPicking } }
    /// Different pictures of one scene — the user has to pick.
    var momentGroups: [DuplicateGroup] { duplicateGroups.filter(\.tier.needsPicking) }

    var copyReclaimable: Int64 { copyGroups.reduce(0) { $0 + reclaimable(for: $1) } }
    var identicalReclaimable: Int64 { identicalGroups.reduce(0) { $0 + reclaimable(for: $1) } }
    var variantReclaimable: Int64 { variantGroups.reduce(0) { $0 + reclaimable(for: $1) } }
    var momentReclaimable: Int64 { momentGroups.reduce(0) { $0 + reclaimable(for: $1) } }
    var duplicateReclaimable: Int64 { copyReclaimable + momentReclaimable }

    /// Only exact matches may ever be cleared without the user looking at them.
    var oneTapGroups: [DuplicateGroup] { identicalGroups }

    func counts(for category: CleanupCategory) -> (count: Int, bytes: Int64) {
        if category == .duplicate {
            return (copyGroups.reduce(0) { $0 + $1.discardable.count }, copyReclaimable)
        }
        let c = candidates.filter {
            $0.category == category
                && !isMarked($0.snapshot.id)
                && !Store.shared.protectedIDs.contains($0.snapshot.id)
                && appPolicy(for: $0.snapshot.id)?.preferKeep != true
        }
        return (c.count, c.reduce(0) { $0 + $1.snapshot.byteSize })
    }

    var activeCategories: [CleanupCategory] {
        CleanupCategory.allCases.filter { counts(for: $0).count > 0 }
    }

    var learningSummary: String {
        if !candidates.isEmpty && !VisionAnalyzer.embeddingsAvailable {
            return "这台设备取不到 Vision 向量，只用规则判断（模拟器上属正常）"
        }
        let d = Store.shared.deletability
        let c = Store.shared.classifier
        if d.sampleCount == 0 { return "还没有学习样本 — 滑几十张就会开始变准" }
        var parts = ["已从 \(d.sampleCount) 次滑动中学习"]
        if d.isWarm {
            parts.append("排序权重 \(Int(d.influence * 100))%")
        } else {
            parts.append("还需 \(max(0, 8 - min(d.positives, d.negatives))) 个样本才启用")
        }
        if c.sampleCount > 0 { parts.append("类别纠正 \(c.sampleCount) 次") }
        return parts.joined(separator: " · ")
    }

    // MARK: lifecycle

    func requestAccess() async {
        auth = await PhotoLibraryService.shared.requestAccess()
        if auth == .authorized || auth == .limited { scan() }
    }

    func scan() {
        guard !stage.isRunning else { return }
        duplicateGroups = []
        candidates = []
        keepSelection = [:]
        logs = []
        engine.start(settings: settings)
    }

    func cancelScan() { engine.cancel() }

    /// Entry point for the background task: run a scan that stops cooperatively
    /// when iOS says time is up. Everything already computed stays cached, so an
    /// interrupted run just leaves less for next time.
    func runScanForBackgroundTask(shouldContinue: @escaping () -> Bool) {
        engine.shouldContinue = shouldContinue
        let done = DispatchSemaphore(value: 0)
        var finished = false
        engine.onStage = { [weak self] s in
            self?.stage = s
            if (s == .finished || s == .idle) && !finished { finished = true; done.signal() }
        }
        engine.start(settings: settings)
        _ = done.wait(timeout: .now() + 25 * 60)
        engine.shouldContinue = nil
        Store.shared.flushDirty()
    }

    /// True when the Vision pass has assets left to look at.
    var hasBackgroundWorkLeft: Bool {
        guard case .classifying = stage else { return stage == .idle && !candidates.isEmpty }
        return true
    }

    private func appendCandidates(_ new: [Candidate]) {
        #if DEBUG
        MainThreadWatchdog.setContext("appendCandidates(\(new.count))")
        defer { MainThreadWatchdog.setContext("idle") }
        #endif
        let known = Set(candidates.map(\.id))
        candidates.append(contentsOf: new.filter { !known.contains($0.id) })
        // Re-ranking the whole list costs ~29 ms at 8 000 candidates, and the scan
        // delivers hundreds of batches — that is seconds of cumulative stutter for
        // an ordering nobody is looking at yet. Coalesce it instead.
        scheduleReranking()
        // If a deck is open on this category, top it up without disturbing
        // the user's current position.
        if let cat = deckCategory {
            let known = Set(deck.map(\.id))
            let extra = candidates.filter {
                $0.category == cat && !known.contains($0.id) && !isMarked($0.id)
                    && !Store.shared.protectedIDs.contains($0.id)
            }
            if !extra.isEmpty && deck.count < settings.deckBatchSize * 3 {
                deck.append(contentsOf: extra.prefix(settings.deckBatchSize))
            }
        }
    }

    // MARK: deck

    func startDeck(category: CleanupCategory) {
        deckCategory = category
        deckIndex = 0
        deckDecisions = [:]
        sessionMarkedBytes = 0
        sessionKeptCount = 0
        sessionWhitelistCount = 0
        deck = Array(candidates
            .filter {
                $0.category == category
                    && !isMarked($0.snapshot.id)
                    && !Store.shared.protectedIDs.contains($0.snapshot.id)
                    && appPolicy(for: $0.snapshot.id)?.preferKeep != true
            }
            .prefix(settings.deckBatchSize))
        prefetch()
    }

    var currentCard: Candidate? {
        deckIndex >= 0 && deckIndex < deck.count ? deck[deckIndex] : nil
    }

    var deckFinished: Bool { deckIndex >= deck.count }

    var deckMarkedCount: Int { deckDecisions.values.filter { $0 == .delete }.count }

    func decide(_ decision: Decision) {
        guard let card = currentCard else { return }
        deckDecisions[card.id] = decision

        switch decision {
        case .delete:
            Store.shared.mark(card.snapshot, category: card.category)
            sessionMarkedBytes += card.snapshot.byteSize
        case .keepOnce:
            Store.shared.unmark(card.id)
            sessionKeptCount += 1
        case .whitelist:
            Store.shared.unmark(card.id)
            Store.shared.protectAsset(card.id)
            sessionWhitelistCount += 1
        }
        refreshPending()

        // Every swipe is a training example for the deletability head.
        if let e = Store.shared.visionCache[card.id]?.embedding {
            Store.shared.learnDeletability(embedding: e, willDelete: decision == .delete)
        }

        deckIndex += 1
        prefetch()
        #if DEBUG
        // Direct measurement of "does the next card appear instantly": if its
        // render is already in the cache there is nothing to wait for.
        if let next = currentCard {
            let hit = ThumbnailProvider.shared.cached(next.snapshot.id,
                                                      side: Self.cardSide) != nil
            NSLog("ALBUMCOMPACT handoff idx=%d nextCached=%@", deckIndex, hit ? "Y" : "N")
        }
        #endif
        Haptics.tap(decision == .delete ? .rigid : .soft)
    }

    /// Step back one card and forget its decision, so a mis-swipe costs one gesture.
    func undo() {
        guard deckIndex > 0 else { return }
        deckIndex -= 1
        guard let card = currentCard else { return }
        switch deckDecisions[card.id] {
        case .delete:
            Store.shared.unmark(card.id)
            sessionMarkedBytes -= card.snapshot.byteSize
        case .keepOnce:
            sessionKeptCount = max(0, sessionKeptCount - 1)
        case .whitelist:
            // Undo has to lift the protection as well, or the card silently
            // stays hidden from every future scan.
            Store.shared.unprotect(card.id)
            sessionWhitelistCount = max(0, sessionWhitelistCount - 1)
        case nil:
            break
        }
        deckDecisions[card.id] = nil
        refreshPending()
        Haptics.tap(.light)
    }

    /// The user disagrees with our label. That correction trains the category head.
    func relabelCurrent(to category: CleanupCategory) {
        guard let card = currentCard else { return }
        if let e = Store.shared.visionCache[card.id]?.embedding {
            Store.shared.learn(embedding: e, label: category)
        }
        if let i = candidates.firstIndex(where: { $0.id == card.id }) {
            candidates[i].category = category
        }
        if let i = deck.firstIndex(where: { $0.id == card.id }) {
            deck[i].category = category
        }
        Haptics.notify(.success)
    }

    /// Warm the next few cards, and stop warming the ones already behind us so the
    /// cache isn't holding a whole session's worth of full-size renders.
    private var rerankScheduled = false

    private func scheduleReranking() {
        guard !rerankScheduled else { return }
        rerankScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            rerankScheduled = false
            candidates = QueuePriority.sorted(candidates,
                                              vision: Store.shared.visionCache,
                                              model: Store.shared.deletability)
        }
    }

    private func prefetch() {
        let ahead = deck[safe: deckIndex..<(deckIndex + 8)].map(\.snapshot.id)
        ThumbnailProvider.shared.startCaching(ids: Array(ahead), side: Self.cardSide)
        let behind = deck[safe: (deckIndex - 6)..<(deckIndex - 1)].map(\.snapshot.id)
        if !behind.isEmpty {
            ThumbnailProvider.shared.stopCaching(ids: Array(behind), side: Self.cardSide)
        }
    }

    /// Must match the `side:` the deck's `AssetImageView` asks for, or the
    /// prefetch lands in a different cache bucket and does nothing.
    static let cardSide: CGFloat = 460

    // MARK: duplicates

    func kept(in group: DuplicateGroup) -> Set<String> {
        keepSelection[group.id] ?? [group.keeperID]
    }

    func isKept(_ assetID: String, in group: DuplicateGroup) -> Bool {
        kept(in: group).contains(assetID)
    }

    /// Toggle one member. At least one member always stays kept — a group where
    /// everything is marked for deletion is never what the user meant.
    func toggleKeep(_ assetID: String, in group: DuplicateGroup) {
        var set = kept(in: group)
        if set.contains(assetID) {
            guard set.count > 1 else { Haptics.notify(.warning); return }
            set.remove(assetID)
        } else {
            set.insert(assetID)
        }
        keepSelection[group.id] = set
        Haptics.tap(.light)
    }

    func keepAll(in group: DuplicateGroup) {
        keepSelection[group.id] = Set(group.members.map(\.id))
        Haptics.tap(.light)
    }

    /// Back-compat for views that still show a single primary pick.
    func keeper(for group: DuplicateGroup) -> String {
        let set = kept(in: group)
        return set.contains(group.keeperID) ? group.keeperID
             : (group.members.first { set.contains($0.id) }?.id ?? group.keeperID)
    }

    func setKeeper(_ assetID: String, for group: DuplicateGroup) {
        keepSelection[group.id] = [assetID]
        Haptics.tap(.light)
    }

    func discardable(for group: DuplicateGroup) -> [AssetSnapshot] {
        let set = kept(in: group)
        return group.members.filter { !set.contains($0.id) }
    }

    /// Short, factual hints about why one frame of a moment beats another.
    /// Only ever states what is measurably true of this group.
    func qualityBadges(for s: AssetSnapshot, in group: DuplicateGroup) -> [String] {
        var out: [String] = []
        let fps = Store.shared.fingerprints
        if let mine = fps[s.id]?.sharpness {
            let others = group.members.compactMap { fps[$0.id]?.sharpness }
            if let best = others.max(), mine >= best - 0.001, others.count > 1,
               (others.min() ?? best) < best - 0.03 {
                out.append(String(localized: "最清晰"))
            }
        }
        if let maxPx = group.members.map(\.pixelCount).max(),
           s.pixelCount == maxPx {
            if group.members.contains(where: { $0.pixelCount < maxPx }) {
                out.append(String(localized: "分辨率最高"))
            }
            // Among the ones at full resolution, say which is least compressed —
            // "分辨率最高" on four of five thumbnails does not help anyone choose.
            let atMax = group.members.filter { $0.pixelCount == maxPx }
            if atMax.count > 1, let best = atMax.map(\.byteSize).max(),
               s.byteSize == best,
               (atMax.map(\.byteSize).min() ?? best) < best {
                out.append(String(localized: "画质最好"))
            }
        }
        if let newest = group.members.map(\.creationDate).max(),
           s.creationDate == newest, group.members.count > 1 {
            out.append(String(localized: "最后一张"))
        }
        if s.isFavorite { out.append(String(localized: "已收藏")) }
        return Array(out.prefix(2))
    }

    /// The actual evidence behind "删掉多余的没有风险", in a form a person can
    /// check. Claiming safety without showing the basis for it is just an
    /// assertion — and this is the one place in the app that offers to delete
    /// without the user looking at each photo.
    struct SafetyEvidence {
        var contentHashHex: String?
        var hashesMatch: Bool
        var dimensions: String
        var dimensionsMatch: Bool
        var byteSizes: [Int64]
        var byteSizesMatch: Bool
        var dHashDistance: Int?
        var pHashDistance: Int?
    }

    /// What is different about the members, in words a person uses.
    ///
    /// The previous version printed the content hash, and the dHash/pHash
    /// distances. Those are how the app decided — they are not what the user
    /// needs to know. "有一张分辨率更高" is the same fact, stated usefully.
    func differenceSummary(for group: DuplicateGroup) -> [String] {
        var out: [String] = []
        let dims = Set(group.members.map { $0.pixelCount })
        let sizes = group.members.map(\.byteSize).filter { $0 > 0 }

        if group.tier == .identical {
            out.append(String(localized: "像素完全相同，连文件大小都一样 —— 就是同一张图存了 \(group.members.count) 份"))
            return out
        }

        if dims.count > 1,
           let hi = group.members.max(by: { $0.pixelCount < $1.pixelCount }),
           let lo = group.members.min(by: { $0.pixelCount < $1.pixelCount }) {
            out.append(String(localized: "分辨率不同：最高 \(hi.pixelWidth)×\(hi.pixelHeight)，最低 \(lo.pixelWidth)×\(lo.pixelHeight)"))
        }
        if let mx = sizes.max(), let mn = sizes.min(), mn > 0, Double(mx) / Double(mn) > 1.6 {
            out.append(String(localized: "画质不同：最清楚的那张文件大 \(Int((Double(mx) / Double(mn)).rounded())) 倍"))
        }
        if out.isEmpty {
            out.append(String(localized: "画面看起来是同一张，细节上有轻微差别"))
        } else {
            out.insert("画面是同一张照片的不同版本", at: 0)
        }
        return out
    }

    func evidence(for group: DuplicateGroup) -> SafetyEvidence {
        let fps = Store.shared.fingerprints
        let keeperID = keeper(for: group)
        let keeperFP = fps[keeperID]
        let others = group.members.filter { $0.id != keeperID }

        let hashes = group.members.compactMap { fps[$0.id]?.contentHash }
        let hashesMatch = hashes.count == group.members.count
            && Set(hashes).count == 1

        let dims = Set(group.members.map { "\($0.pixelWidth)×\($0.pixelHeight)" })
        let sizes = group.members.map(\.byteSize)

        var dd: Int?, dp: Int?
        if let k = keeperFP {
            dd = others.compactMap { fps[$0.id] }
                .map { hammingDistance(k.dHash, $0.dHash) }.max()
            dp = others.compactMap { fps[$0.id] }
                .map { hammingDistance(k.pHash, $0.pHash) }.max()
        }

        return SafetyEvidence(
            contentHashHex: hashesMatch
                ? String(format: "%016llx", hashes.first ?? 0) : nil,
            hashesMatch: hashesMatch,
            dimensions: dims.sorted().joined(separator: " / "),
            dimensionsMatch: dims.count == 1,
            byteSizes: sizes,
            byteSizesMatch: Set(sizes).count == 1,
            dHashDistance: dd, pHashDistance: dp)
    }

    func reclaimable(for group: DuplicateGroup) -> Int64 {
        discardable(for: group).reduce(0) { $0 + $1.byteSize }
    }

    func markGroup(_ group: DuplicateGroup) {
        for s in discardable(for: group) { Store.shared.mark(s, category: .duplicate) }
        duplicateGroups.removeAll { $0.id == group.id }
        refreshPending()
        Haptics.notify(.success)
    }

    /// Sweep every copy group at once. Only ever called for copy groups — a
    /// moment group has no defensible automatic answer.
    func markAllOneTapGroups() {
        for g in oneTapGroups {
            for s in discardable(for: g) { Store.shared.mark(s, category: .duplicate) }
        }
        let ids = Set(oneTapGroups.map(\.id))
        duplicateGroups.removeAll { ids.contains($0.id) }
        refreshPending()
        Haptics.notify(.success)
    }

    func skipGroup(_ group: DuplicateGroup) {
        for s in group.members { Store.shared.protectAsset(s.id) }
        duplicateGroups.removeAll { $0.id == group.id }
        refreshPending()
    }

    // MARK: pending / execution

    func isMarked(_ id: String) -> Bool { Store.shared.pending[id] != nil }

    var pendingItems: [PendingItem] {
        Store.shared.pending.values.sorted { $0.markedAt > $1.markedAt }
    }

    var duePendingItems: [PendingItem] { Store.shared.duePending }

    func snapshot(for id: String) -> AssetSnapshot? {
        snapshotIndex[id]
    }

    /// O(1) lookup. `snapshots.first { $0.id == id }` is a linear scan over the
    /// whole library, and the review grid calls it once per visible cell — at
    /// 100 000 photos that is tens of millions of comparisons per frame.
    private var snapshotIndex: [String: AssetSnapshot] = [:]

    func restore(_ id: String) {
        Store.shared.unmark(id)
        refreshPending()
    }

    func restoreAll() {
        Store.shared.clearPending(ids: Array(Store.shared.pending.keys))
        refreshPending()
    }

    func refreshPending() {
        pendingCount = Store.shared.pending.count
        pendingBytes = Store.shared.pendingBytes
    }

    /// Execute deletion for the given ids (defaults to everything already due).
    @MainActor
    func execute(ids explicit: [String]? = nil) async {
        let ids = explicit ?? duePendingItems.map(\.id)
        guard !ids.isEmpty else { return }
        // Capture the rows before the tray is cleared — the per-category
        // breakdown only exists here, and the dashboard needs it.
        let executed = ids.compactMap { Store.shared.pending[$0] }

        if settings.stageInAlbum {
            _ = await DeletionService.addToStagingAlbum(ids: ids, albumTitle: String(localized: "待删 · 相册瘦身"))
        }

        switch await DeletionService.delete(ids: ids) {
        case .success(let count, let bytes):
            Store.shared.clearPending(ids: ids)
            Store.shared.recordDeletion(items: executed, actualBytes: bytes)
            snapshots.removeAll { ids.contains($0.id) }
            candidates.removeAll { ids.contains($0.id) }
            deck.removeAll { ids.contains($0.id) }
            refreshPending()
            lastDeletionMessage = "已删除 \(count) 项，释放 \(ByteFormat.string(bytes))。它们会在系统「最近删除」里保留 30 天。"
            Haptics.notify(.success)
        case .cancelled:
            lastDeletionMessage = "已取消，没有删除任何东西。"
        case .failed(let msg):
            lastDeletionMessage = "删除失败：\(msg)"
            Haptics.notify(.error)
        }
        Store.shared.flushClassifier()
    }

    /// Hide pending items from the library while they wait out the grace period.
    @MainActor
    func applyHideForPending() async {
        guard settings.hideWhilePending else { return }
        _ = await DeletionService.setHidden(true, ids: pendingItems.map(\.id))
    }

    // MARK: reminders

    /// A third-party app can't run code days later to delete files, so the grace
    /// period is honoured with a local reminder instead. Being upfront about that
    /// is better than pretending we have a background daemon.
    func scheduleReminder() {
        guard settings.grace != .immediate, pendingCount > 0 else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            center.removePendingNotificationRequests(withIdentifiers: ["compact.due"])
            let content = UNMutableNotificationContent()
            content.title = "待删照片已到期"
            content.body = "\(self.pendingCount) 项 · 可释放 \(ByteFormat.string(self.pendingBytes))，打开确认执行。"
            content.sound = .default
            let fire = max(60, self.settings.grace.interval)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire, repeats: false)
            center.add(UNNotificationRequest(identifier: "compact.due",
                                             content: content, trigger: trigger))
        }
    }
}

// MARK: - Small helpers

enum Haptics {
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}

extension Array {
    subscript(safe range: Range<Int>) -> ArraySlice<Element> {
        let lower = Swift.max(0, range.lowerBound)
        let upper = Swift.min(count, range.upperBound)
        guard lower < upper else { return [] }
        return self[lower..<upper]
    }
}
