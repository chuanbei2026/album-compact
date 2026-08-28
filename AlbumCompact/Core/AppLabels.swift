import Foundation

/// Per-app labelling, built on nearest-centroid matching over frozen FeaturePrint
/// vectors.
///
/// Why centroids and not a trained head:
/// * **Open set.** New apps appear all the time. A fixed-output softmax cannot
///   gain a class without retraining; a centroid store gains one by appending.
/// * **One label, hundreds of photos.** Measured on real embeddings, screenshots
///   from one app sit at cosine 0.95–0.999 of each other while unrelated
///   screenshots sit around 0.58. So the app clusters *first* and the user names
///   a cluster *once* — five taps instead of five hundred.
/// * **Inspectable.** "这一簇最像微信，相似度 0.94" is something a user can check
///   and correct. A weight vector is not.
///
/// The real payoff is not a prettier label. It is that once the app is known, the
/// user can state a policy for it — "微信截图默认删除，支付宝账单默认保留" — which is
/// far more actionable than any generic category.
struct AppLabel: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// One app can look like several different screens (a chat list vs a chat
    /// thread vs its settings page), so a label owns multiple centroids.
    var centroids: [[Float]]
    var sampleCount: Int
    /// FeaturePrint revision these centroids were built with. Vectors from a
    /// different revision are meaningless against them.
    var revision: Int
    var category: CleanupCategory?
    /// Per-app policy. Neither implies automatic deletion — `preferDelete` only
    /// pushes the app's screenshots up the triage queue.
    var preferDelete: Bool = false
    var preferKeep: Bool = false

    func similarity(to e: Embedding) -> Float {
        guard revision == e.revision else { return -1 }
        var best: Float = -1
        for c in centroids where c.count == e.values.count {
            let s = Embedding(values: c, revision: revision).cosine(e)
            if s > best { best = s }
        }
        return best
    }
}

/// A group of visually near-identical screenshots that has not been named yet.
struct AppCluster: Identifiable {
    var id = UUID()
    var memberIDs: [String]
    var centroid: [Float]
    var revision: Int
    var bytes: Int64
    /// Similarity of the loosest member to the centroid — how tight the cluster is.
    var cohesion: Float
    /// Best matching existing label, if any, so the UI can suggest a name.
    var suggestedName: String?
    var suggestedSimilarity: Float = 0
}

enum AppClustering {

    /// Greedy clustering compares every photo against every cluster centroid, so
    /// it costs O(n × clusters × dim). At 26 000 screenshots and a few hundred
    /// clusters that is billions of float operations — measured at 21.9 s.
    ///
    /// A fixed random projection (Johnson–Lindenstrauss) to 64 dimensions cuts
    /// that by 12× while preserving cosine well enough for the decision at hand:
    /// same-app pairs sit at 0.95+ and different-app pairs at ~0.58, a margin far
    /// wider than the distortion a projection of this size introduces. Exact
    /// centroids are still kept in full dimension — only the *search* is reduced.
    static let projectedDim = 64

    /// Hard ceiling on cluster count.
    ///
    /// Greedy clustering is O(n × clusters). If nothing merges — a library of
    /// wildly varied screenshots, or a degenerate embedding — every photo becomes
    /// its own cluster and the cost turns quadratic: 26 000 photos would be 45
    /// billion operations. Past this ceiling we stop opening new clusters and let
    /// the remainder fall through unlabeled, which is the honest outcome: they
    /// genuinely do not belong to any group worth naming.
    static let maxClusters = 400

    /// How many photos fell past the ceiling on the last pass. Surfaced rather
    /// than swallowed — a silent cap reads as "we covered everything".
    nonisolated(unsafe) static var lastOverflowCount = 0

    /// Deterministic projection matrix, generated from a fixed seed so a photo
    /// lands in the same place on every launch.
    private static let projection: [[Float]] = {
        var rows: [[Float]] = []
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Float {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(Int64(bitPattern: state &>> 11)) / Float(1 << 53) - 0.5
        }
        for _ in 0..<projectedDim {
            var r = [Float](repeating: 0, count: 768)
            var n: Float = 0
            for d in 0..<768 { r[d] = next(); n += r[d] * r[d] }
            n = sqrt(max(n, 1e-9))
            for d in 0..<768 { r[d] /= n }
            rows.append(r)
        }
        return rows
    }()

    static func project(_ v: [Float]) -> [Float] {
        guard v.count == 768 else { return v }
        var out = [Float](repeating: 0, count: projectedDim)
        for k in 0..<projectedDim {
            let r = projection[k]
            var acc: Float = 0
            for d in 0..<768 { acc += r[d] * v[d] }
            out[k] = acc
        }
        var n: Float = 0
        for x in out { n += x * x }
        n = sqrt(max(n, 1e-9))
        for k in 0..<projectedDim { out[k] /= n }
        return out
    }

    @inline(__always)
    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }

    /// Cosine above which two screenshots are treated as the same app screen.
    /// Measured separation: same-app 0.95–0.999, unrelated ≈ 0.58. 0.93 sits well
    /// inside the gap and still tolerates a chat thread that scrolled.
    static let mergeThreshold: Float = 0.93
    /// Matching a whole cluster onto an existing label can be a little looser —
    /// the cluster centroid is already an average, so it is less noisy.
    static let labelMatchThreshold: Float = 0.90

    /// Greedy agglomerative clustering. O(n · clusters), and the cluster count
    /// stays small because one app produces a handful of distinct screens.
    static func cluster(_ items: [(id: String, embedding: Embedding, bytes: Int64)],
                        against labels: [AppLabel]) -> (clusters: [AppCluster],
                                                        assigned: [String: UUID]) {
        lastOverflowCount = 0
        var full: [[Float]] = []        // exact centroid, 768-d
        var small: [[Float]] = []       // projected centroid, used for the search
        var members: [[String]] = []
        var bytes: [Int64] = []
        var worst: [Float] = []
        var overflowed = 0
        let revision = VisionAnalyzer.featurePrintRevision

        for item in items {
            guard item.embedding.revision == revision else { continue }
            let p = project(item.embedding.values)
            var best = -1
            var bestSim: Float = -1
            for k in 0..<small.count {
                let sim = dot(small[k], p)
                if sim > bestSim { bestSim = sim; best = k }
            }
            if best >= 0, bestSim >= mergeThreshold {
                let n = Float(members[best].count)
                var merged = [Float](repeating: 0, count: item.embedding.values.count)
                for d in 0..<merged.count {
                    merged[d] = (full[best][d] * n + item.embedding.values[d]) / (n + 1)
                }
                // Renormalise, or cosine against the centroid drifts as it grows.
                full[best] = Embedding(values: merged, revision: revision).normalized.values
                small[best] = project(full[best])
                members[best].append(item.id)
                bytes[best] += item.bytes
                worst[best] = min(worst[best], bestSim)
            } else if full.count < maxClusters {
                full.append(item.embedding.values)
                small.append(p)
                members.append([item.id])
                bytes.append(item.bytes)
                worst.append(1)
            } else {
                overflowed += 1
            }
        }

        var out: [AppCluster] = []
        var assigned: [String: UUID] = [:]
        for k in 0..<full.count {
            // A single screenshot is not a cluster worth naming.
            guard members[k].count >= 2 else { continue }
            var c = AppCluster(memberIDs: members[k], centroid: full[k],
                               revision: revision, bytes: bytes[k], cohesion: worst[k])
            let e = Embedding(values: full[k], revision: revision)
            if let match = labels.map({ ($0, $0.similarity(to: e)) })
                .filter({ $0.1 >= labelMatchThreshold })
                .max(by: { $0.1 < $1.1 }) {
                c.suggestedName = match.0.name
                c.suggestedSimilarity = match.1
            }
            out.append(c)
            for m in members[k] { assigned[m] = c.id }
        }
        if overflowed > 0 {
            lastOverflowCount = overflowed
        }
        return (out.sorted { $0.memberIDs.count > $1.memberIDs.count }, assigned)
    }

    /// Best label for one screenshot, with its similarity.
    static func match(_ e: Embedding, labels: [AppLabel]) -> (AppLabel, Float)? {
        labels.map { ($0, $0.similarity(to: e)) }
            .filter { $0.1 >= labelMatchThreshold }
            .max { $0.1 < $1.1 }
    }
}

// MARK: - 2D projection for the embedding map

enum EmbeddingProjection {

    /// Project high-dimensional vectors to 2D with PCA, for a scatter plot.
    ///
    /// Two components via power iteration on the covariance matrix, with the
    /// second deflated against the first. Deterministic (fixed seed vector), so
    /// the map does not reshuffle itself every time it is opened — a plot whose
    /// points jump around on each render is unreadable as a reference.
    static func pca2D(_ vectors: [[Float]], iterations: Int = 40) -> [(x: Float, y: Float)] {
        guard let dim = vectors.first?.count, vectors.count >= 3 else {
            return vectors.map { _ in (0, 0) }
        }
        var mean = [Float](repeating: 0, count: dim)
        for v in vectors { for d in 0..<dim { mean[d] += v[d] } }
        for d in 0..<dim { mean[d] /= Float(vectors.count) }
        let centered = vectors.map { v in (0..<dim).map { v[$0] - mean[$0] } }

        func multiplyCovariance(_ x: [Float]) -> [Float] {
            // Cov · x  ==  Σ_i vᵢ (vᵢ · x), which avoids ever materialising the
            // dim×dim covariance matrix.
            var out = [Float](repeating: 0, count: dim)
            for v in centered {
                var dot: Float = 0
                for d in 0..<dim { dot += v[d] * x[d] }
                guard dot != 0 else { continue }
                for d in 0..<dim { out[d] += v[d] * dot }
            }
            return out
        }
        func normalise(_ x: [Float]) -> [Float] {
            var n: Float = 0
            for v in x { n += v * v }
            n = sqrt(n)
            return n > 0 ? x.map { $0 / n } : x
        }
        func power(deflating first: [Float]?) -> [Float] {
            // Fixed, non-degenerate start vector keeps the result reproducible.
            var x = (0..<dim).map { Float(sin(Double($0) * 0.7) + 0.31) }
            x = normalise(x)
            for _ in 0..<iterations {
                var y = multiplyCovariance(x)
                if let f = first {
                    var dot: Float = 0
                    for d in 0..<dim { dot += y[d] * f[d] }
                    for d in 0..<dim { y[d] -= dot * f[d] }
                }
                x = normalise(y)
            }
            return x
        }
        let pc1 = power(deflating: nil)
        let pc2 = power(deflating: pc1)

        return centered.map { v in
            var a: Float = 0, b: Float = 0
            for d in 0..<dim { a += v[d] * pc1[d]; b += v[d] * pc2[d] }
            return (a, b)
        }
    }
}


// MARK: - Bundled centroid library

/// A library of app centroids shipped inside the app binary.
///
/// This is the zero-upload answer to "how does a fresh install already know what
/// 微信 looks like": the developer builds the library once from their own
/// screenshots (`algolab --build-app-library`), it ships as a resource, and no
/// user data ever moves. A centroid averaged over dozens of screenshots is a
/// description of an app's chrome — a navigation bar, a colour scheme, a layout —
/// not of anyone's content.
///
/// Vectors are stored as raw little-endian Float32 so the file stays small
/// (768 × 4 = 3 KB per centroid) and loads without parsing overhead.
struct BundledAppLibrary: Codable {
    struct Entry: Codable {
        var name: String
        var category: String?
        var sampleCount: Int
        /// Concatenated centroids, `dimension` floats each.
        var centroidData: Data
        var dimension: Int

        var centroids: [[Float]] {
            let count = centroidData.count / (dimension * 4)
            guard count > 0 else { return [] }
            return centroidData.withUnsafeBytes { raw -> [[Float]] in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: Float.self) else {
                    return []
                }
                return (0..<count).map { k in
                    Array(UnsafeBufferPointer(start: base + k * dimension, count: dimension))
                }
            }
        }

        init(name: String, category: String?, sampleCount: Int, centroids: [[Float]]) {
            self.name = name
            self.category = category
            self.sampleCount = sampleCount
            self.dimension = centroids.first?.count ?? 0
            var d = Data()
            for c in centroids { c.withUnsafeBufferPointer { d.append(Data(buffer: $0)) } }
            self.centroidData = d
        }
    }

    /// The FeaturePrint revision every centroid here was built with. A library
    /// built under a different revision is not merely stale, it is meaningless —
    /// the loader must refuse it rather than compute nonsense similarities.
    var revision: Int
    var entries: [Entry]
    var builtAt: Date

    /// Resource name inside the app bundle.
    static let resourceName = "AppCentroids"

    static func loadFromBundle() -> BundledAppLibrary? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let lib = try? PropertyListDecoder().decode(BundledAppLibrary.self, from: data)
        else { return nil }
        guard lib.revision == VisionAnalyzer.featurePrintRevision else {
            #if DEBUG
            NSLog("ALBUMCOMPACT 内置质心库 revision=%d，本机 FeaturePrint revision=%d，忽略",
                  lib.revision, VisionAnalyzer.featurePrintRevision)
            #endif
            return nil
        }
        return lib
    }

    func asLabels() -> [AppLabel] {
        entries.compactMap { e in
            let c = e.centroids
            guard !c.isEmpty else { return nil }
            return AppLabel(name: e.name, centroids: c, sampleCount: e.sampleCount,
                            revision: revision,
                            category: e.category.flatMap(CleanupCategory.init(rawValue:)))
        }
    }

    func encoded() throws -> Data {
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        return try enc.encode(self)
    }
}
