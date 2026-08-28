import Foundation

/// Union-Find with path compression — turns pairwise "these two are dupes"
/// verdicts into connected components.
struct DisjointSet {
    private var parent: [Int]
    private var rank: [Int]

    init(_ n: Int) {
        parent = Array(0..<n)
        rank = [Int](repeating: 0, count: n)
    }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var cur = x
        while parent[cur] != root { let next = parent[cur]; parent[cur] = root; cur = next }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        guard ra != rb else { return }
        if rank[ra] < rank[rb] { parent[ra] = rb }
        else if rank[ra] > rank[rb] { parent[rb] = ra }
        else { parent[rb] = ra; rank[ra] += 1 }
    }
}

/// Near-duplicate search over 64-bit hashes.
///
/// Naive all-pairs is O(n²): at 200k photos that's 2×10¹⁰ comparisons, far too
/// slow on a phone. Multi-Index Hashing exploits the pigeonhole principle —
/// split each hash into `bands` chunks; if two hashes differ in at most
/// `bands - 1` bits, at least one chunk must be *identical*. So we only ever
/// compare hashes that collide in some chunk, which is near-linear in practice.
struct MultiIndexHash {
    let bands = 8                        // 8 bands × 8 bits ⇒ exact recall up to d ≤ 7
    private var tables: [[UInt64: [Int]]]

    init() { tables = Array(repeating: [:], count: 8) }

    private func chunk(_ h: UInt64, _ band: Int) -> UInt64 {
        (h >> UInt64(band * 8)) & 0xFF
    }

    mutating func insert(_ hash: UInt64, index: Int) {
        for b in 0..<bands { tables[b][chunk(hash, b), default: []].append(index) }
    }

    /// Candidate neighbours (a superset of the true ≤7-bit neighbours).
    func candidates(for hash: UInt64, excluding index: Int) -> Set<Int> {
        var out = Set<Int>()
        for b in 0..<bands {
            if let bucket = tables[b][chunk(hash, b)] {
                // A pathological bucket (e.g. 40k pure-black thumbnails all
                // sharing a chunk) would blow up; cap it and let other bands
                // carry the recall.
                if bucket.count > 4000 { continue }
                for i in bucket where i != index { out.insert(i) }
            }
        }
        return out
    }
}

// MARK: - Thresholds

/// Thresholds derived from measured distance distributions rather than intuition.
/// See `algolab --distances`: true copies land at dHash ≤ 1 / pHash 0, while
/// unrelated-but-same-layout images (two receipts, two frames of one game) start
/// colliding at dHash 0 / pHash 2. There is no threshold that separates those by
/// distance alone, which is why the moment tier uses time and media type instead.
struct DuplicateThresholds {
    /// A re-encoded or resized copy of the same capture. Kept deliberately tight:
    /// widening this admits false pairs and catches no additional real copies.
    var copyDHash = 2
    var copyPHash = 4

    /// Shots of one scene.
    ///
    /// Measured separation (`--distances`): burst frames sit at dHash 0–11 and
    /// pHash 6–20, while *different* real photographs sit at dHash 5–37 and pHash
    /// 14–36. dHash therefore cannot separate them at all; pHash can, but only
    /// between adjacent frames. So the moment rule leans on metadata — an iOS
    /// burst id, or tight time adjacency — and uses the hash purely as a guard
    /// against absurd pairings.
    var momentWindow: TimeInterval = 10
    var momentDHash = 12
    var momentPHash = 12
    /// A whole moment may not sprawl. Batch imports (AirDrop, an SD card, a
    /// messaging app saving 40 pictures) stamp every asset with almost the same
    /// creation date, and without a span and size cap they chain through
    /// union-find into one enormous bogus "moment".
    var momentSpanFactor: Double = 6
    var momentMaxRunSize = 12

    static let `default` = DuplicateThresholds()
}

enum DuplicateFinder {

    /// How many time-adjacent runs were rejected as import batches on the last
    /// pass. Surfaced in the scan log rather than swallowed — a silent cap reads
    /// as "we covered everything" when it didn't.
    nonisolated(unsafe) static var lastDroppedRunCount = 0

    /// Cheap structural test for "this is a capture of a UI, not a photograph".
    /// Deliberately metadata-only so grouping (stage 3) never has to wait on
    /// Vision (stage 4).
    static func isScreenLike(_ s: AssetSnapshot) -> Bool {
        if s.isScreenshot { return true }
        let w = min(s.pixelWidth, s.pixelHeight), h = max(s.pixelWidth, s.pixelHeight)
        // Tall, exact-power-ish phone screen ratios only — 4:3 is far too common
        // among ordinary photos to use as a signal here.
        guard h > 0 else { return false }
        let ratio = Double(h) / Double(w)
        return ratio > 1.9 && ratio < 2.3
    }

    /// Group assets, in two independent passes.
    ///
    /// Copies and moments are different relations and must not share a union-find
    /// structure. Mixing them merges a chain of true copies with one time-adjacent
    /// pair into a single component, and then *any* tier-resolution rule mislabels
    /// it: taking the worst tier sends a pile of identical copies to the "pick one"
    /// screen, taking the best offers a one-tap sweep over genuinely different
    /// shots. So:
    ///
    ///   pass 1  copies   — hash-indexed, tight, safe to sweep
    ///   pass 2  moments  — time-indexed, over whatever pass 1 did not claim
    ///
    /// Resolving copies first is also the right product order: if two photos are
    /// literally the same image, that is a duplication problem, not a choice.
    static func findGroups(snapshots: [AssetSnapshot],
                           fingerprints: [String: Fingerprint],
                           thresholds: DuplicateThresholds = .default,
                           protectedIDs: Set<String> = []) -> [DuplicateGroup] {
        lastDroppedRunCount = 0

        let images = snapshots.filter { !$0.isVideo && fingerprints[$0.id] != nil }
        let fps = images.map { fingerprints[$0.id]! }
        var groups: [DuplicateGroup] = []

        // ---------- pass 1: copies of the same picture ----------
        var copyDSU = DisjointSet(images.count)
        var copyTier = [Int: DuplicateTier]()
        var index = MultiIndexHash()
        for i in 0..<images.count { index.insert(fps[i].dHash, index: i) }

        for i in 0..<images.count {
            let a = images[i], fa = fps[i]
            for j in index.candidates(for: fa.dHash, excluding: i) where j > i {
                let b = images[j], fb = fps[j]
                let dd = hammingDistance(fa.dHash, fb.dHash)
                let dp = hammingDistance(fa.pHash, fb.pHash)

                // A UI capture can only ever be `identical`. "Similar layout" says
                // nothing about being the same content — two different receipts
                // collide at dHash 0.
                let uiCapture = isScreenLike(a) || isScreenLike(b)
                let sameShape = a.pixelWidth * b.pixelHeight == b.pixelWidth * a.pixelHeight

                var tier: DuplicateTier?
                if fa.contentHash == fb.contentHash
                    && a.pixelWidth == b.pixelWidth && a.pixelHeight == b.pixelHeight {
                    tier = .identical
                } else if !uiCapture, sameShape,
                          dd <= thresholds.copyDHash, dp <= thresholds.copyPHash {
                    tier = .copy
                }
                guard let t = tier else { continue }
                copyDSU.union(i, j)
                let root = copyDSU.find(i)
                copyTier[root] = max(copyTier[root] ?? .identical, t)
            }
        }

        var copyComponents = [Int: [Int]]()
        for i in 0..<images.count { copyComponents[copyDSU.find(i), default: []].append(i) }
        var resolvedCopyTier = [Int: DuplicateTier]()
        for (oldRoot, tier) in copyTier {
            let root = copyDSU.find(oldRoot)
            resolvedCopyTier[root] = max(resolvedCopyTier[root] ?? .identical, tier)
        }

        var claimed = Set<Int>()
        for (root, members) in copyComponents where members.count > 1 {
            claimed.formUnion(members)
            groups.append(makeGroup(members.map { images[$0] },
                                    tier: resolvedCopyTier[root] ?? .copy,
                                    fingerprints: fingerprints, protectedIDs: protectedIDs))
        }

        // ---------- pass 2: moments, over what pass 1 left ----------
        var momentDSU = DisjointSet(images.count)
        var momentTouched = false

        var candidates: [Int] = []
        for (i, a) in images.enumerated()
        where !isScreenLike(a) && !claimed.contains(i) {
            candidates.append(i)
        }
        candidates.sort { images[$0].creationDate < images[$1].creationDate }

        var runStart = 0
        while runStart < candidates.count {
            var runEnd = runStart
            while runEnd + 1 < candidates.count {
                let prev = images[candidates[runEnd]]
                let next = images[candidates[runEnd + 1]]
                let gap = next.creationDate.timeIntervalSince(prev.creationDate)
                let sameBurst = prev.burstID != nil && prev.burstID == next.burstID
                guard sameBurst || gap <= thresholds.momentWindow else { break }
                runEnd += 1
            }

            if runEnd > runStart {
                let run = Array(candidates[runStart...runEnd])
                // An iOS-declared burst is exempt from the caps: a real burst can
                // be 30 frames, and PhotoKit already vouched for it.
                let vouchedByPhotoKit = run.allSatisfy { images[$0].burstID != nil }
                    && Set(run.compactMap { images[$0].burstID }).count == 1

                let span = images[run.last!].creationDate
                    .timeIntervalSince(images[run.first!].creationDate)
                let spanOK = span <= thresholds.momentWindow * thresholds.momentSpanFactor
                let sizeOK = run.count <= thresholds.momentMaxRunSize

                // A camera exposes frames one after another, so capture timestamps
                // differ. A batch write — AirDrop, an SD card, an app saving nine
                // pictures at once — stamps them all with one instant.
                var stampCounts: [TimeInterval: Int] = [:]
                for i in run {
                    stampCounts[images[i].creationDate.timeIntervalSince1970, default: 0] += 1
                }
                let looksLikeBatchWrite = run.count >= 3
                    && Double(stampCounts.values.max() ?? 1) / Double(run.count) > 0.6

                if vouchedByPhotoKit || (spanOK && sizeOK && !looksLikeBatchWrite) {
                    for x in 0..<run.count {
                        for y in (x + 1)..<run.count {
                            let ax = run[x], by = run[y]
                            let a = images[ax], b = images[by]
                            let sameBurst = a.burstID != nil && a.burstID == b.burstID
                            let dd = hammingDistance(fps[ax].dHash, fps[by].dHash)
                            let dp = hammingDistance(fps[ax].pHash, fps[by].pHash)
                            // pHash is the discriminating measure here (different
                            // real photos start at pHash 14; burst frames sit at
                            // 6–10 between neighbours). dHash is only a guard.
                            guard sameBurst || (dp <= thresholds.momentPHash
                                                && dd <= thresholds.momentDHash)
                            else { continue }
                            momentDSU.union(ax, by)
                            momentTouched = true
                        }
                    }
                } else {
                    lastDroppedRunCount += 1
                }
            }
            runStart = runEnd + 1
        }

        if momentTouched {
            var momentComponents = [Int: [Int]]()
            for i in candidates { momentComponents[momentDSU.find(i), default: []].append(i) }
            for (_, members) in momentComponents where members.count > 1 {
                groups.append(makeGroup(members.map { images[$0] }, tier: .moment,
                                        fingerprints: fingerprints, protectedIDs: protectedIDs))
            }
        }

        // ---------- videos: metadata-exact only ----------
        let videos = snapshots.filter(\.isVideo)
        var vKey = [String: [AssetSnapshot]]()
        for v in videos where v.byteSize > 0 {
            let key = "\(v.byteSize)-\(Int(v.duration * 10))-\(v.pixelWidth)x\(v.pixelHeight)"
            vKey[key, default: []].append(v)
        }
        for (_, members) in vKey where members.count > 1 {
            groups.append(makeGroup(members, tier: .identical,
                                    fingerprints: fingerprints, protectedIDs: protectedIDs))
        }

        return groups.sorted {
            if $0.tier != $1.tier { return $0.tier < $1.tier }
            if $0.reclaimableBytes != $1.reclaimableBytes {
                return $0.reclaimableBytes > $1.reclaimableBytes
            }
            return $0.id < $1.id
        }
    }

    // MARK: keeper selection

    /// Score a member of a duplicate group. Highest score is kept.
    ///
    /// The user asked for "most recent, or highest quality" — both matter, so
    /// this is an explicit weighted sum rather than a single sort key, and the
    /// winning reason is surfaced in the UI so the choice is never a black box.
    static func keeperScore(_ a: AssetSnapshot,
                            in group: [AssetSnapshot],
                            fingerprint: Fingerprint?,
                            tier: DuplicateTier = .moment) -> (score: Double, reason: String) {
        var score = 0.0
        var reasons: [String] = []

        // Hard preferences — a favourite is never the one we throw away.
        if a.isFavorite { score += 1000; reasons.append(String(localized: "已收藏")) }
        if a.isLivePhoto { score += 60; reasons.append("Live Photo") }
        if a.isPortrait { score += 50; reasons.append(String(localized: "人像景深")) }
        if a.hasLocation { score += 25; reasons.append(String(localized: "带定位")) }
        if !a.isScreenshot { score += 15 }

        // Resolution — log scale, so 12MP vs 8MP matters but 12 vs 12.1 doesn't.
        let maxPixels = group.map(\.pixelCount).max() ?? a.pixelCount
        if maxPixels > 0 {
            let ratio = Double(a.pixelCount) / Double(maxPixels)
            score += ratio * 120
            if ratio >= 0.999 && group.contains(where: { $0.pixelCount < maxPixels }) {
                reasons.append(String(localized: "分辨率最高"))
            }
        }

        // File size — a bigger file of the same scene means less recompression.
        let maxBytes = group.map(\.byteSize).max() ?? a.byteSize
        if maxBytes > 0 {
            let ratio = Double(a.byteSize) / Double(maxBytes)
            score += ratio * 60
            if ratio >= 0.999 && group.contains(where: { $0.byteSize < maxBytes }) {
                reasons.append(String(localized: "画质损失最小"))
            }
        }

        // Sharpness.
        if let fp = fingerprint {
            score += Double(fp.sharpness) * 70
            if fp.sharpness > 0.6 { reasons.append(String(localized: "最清晰")) }
        }

        // Recency — but only where it means something. For several *versions of
        // one image*, "newest" is noise: the newest copy is often the one a
        // messaging app re-compressed. There the best version is simply the
        // highest-quality one, so recency is dropped entirely.
        if tier == .moment,
           let newest = group.map(\.creationDate).max(),
           let oldest = group.map(\.creationDate).min(),
           newest > oldest {
            let span = newest.timeIntervalSince(oldest)
            let rel = a.creationDate.timeIntervalSince(oldest) / span
            score += rel * 40
            if rel >= 0.999 { reasons.append(String(localized: "最新一张")) }
        }

        let reason = reasons.isEmpty ? "综合评分最高" : reasons.prefix(2).joined(separator: " · ")
        return (score, reason)
    }

    private static func makeGroup(_ members: [AssetSnapshot],
                                  tier: DuplicateTier,
                                  fingerprints: [String: Fingerprint],
                                  protectedIDs: Set<String>) -> DuplicateGroup {
        var best = members[0]
        var bestScore = -Double.infinity
        var bestReason = ""
        // Iterate in a stable order and break ties on id, so the same library
        // always proposes the same keeper. Without this, a tie resolves by
        // whatever order the set happened to hash in and the highlighted photo
        // moves between scans for no visible reason.
        for m in members.sorted(by: { $0.id < $1.id }) {
            var (s, r) = keeperScore(m, in: members, fingerprint: fingerprints[m.id],
                                     tier: tier)
            if protectedIDs.contains(m.id) { s += 5000; r = "你标记为永久保留" }
            if s > bestScore + 1e-9 { bestScore = s; best = m; bestReason = r }
        }
        let ordered = [best] + members.filter { $0.id != best.id }
                                      .sorted { $0.creationDate > $1.creationDate }
        return DuplicateGroup(tier: tier, members: ordered,
                              keeperID: best.id, keeperReason: bestReason)
    }
}
