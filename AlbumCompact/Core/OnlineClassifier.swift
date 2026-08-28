import Foundation

/// A multinomial logistic-regression head trained on top of Vision's frozen
/// 768-d FeaturePrint embeddings.
///
/// Why this shape:
/// * The backbone (FeaturePrint) already runs on the Neural Engine and is a
///   general-purpose visual encoder, so a *linear* head is enough to separate
///   "your WeChat screenshots" from "your Genshin screenshots".
/// * ~768 × 5 ≈ 4k parameters. Training one step is a couple of microseconds,
///   so we can learn from every single swipe, live, with no batching.
/// * Nothing ships pre-trained and nothing leaves the device. The user's own
///   triage decisions *are* the dataset — which is exactly why it beats a
///   generic model: it learns their apps, their games, their habits.
final class OnlineClassifier: Codable {

    private(set) var classes: [CleanupCategory]
    private var weights: [[Float]]        // [class][feature]
    private var bias: [Float]
    private(set) var sampleCount: Int
    private(set) var perClassCount: [String: Int]
    private var dim: Int

    /// Learning rate. High enough that ~20 corrections visibly change ranking,
    /// low enough that one mis-swipe doesn't wreck the model.
    private static let lr: Float = 0.35
    private static let l2: Float = 1e-4

    init(dim: Int = 768, classes: [CleanupCategory] = CleanupCategory.learnable) {
        self.dim = dim
        self.classes = classes
        self.weights = Array(repeating: [Float](repeating: 0, count: dim), count: classes.count)
        self.bias = [Float](repeating: 0, count: classes.count)
        self.sampleCount = 0
        self.perClassCount = [:]
    }

    var isWarm: Bool { sampleCount >= 12 }

    /// How much the head is trusted against the hand-written rules.
    ///
    /// The rules are a **cold-start prior**, not a peer. They encode a handful of
    /// structural facts (a status bar exists; the resolution matches a screen;
    /// text sits in two columns) and they hit a ceiling fast — every attempt to
    /// push them further produced a new false positive somewhere else. The
    /// embedding, by contrast, encodes what an app *looks like*, which is the
    /// actual question. So trust ramps to near-total: past a few hundred labelled
    /// samples the head decides and the rules only fill in where it has never
    /// seen anything similar.
    var trust: Double {
        guard sampleCount > 0 else { return 0 }
        return min(0.92, Double(sampleCount) / 300.0)
    }

    /// Highest class probability, so a caller can tell "confidently chat" from
    /// "no idea, everything is 1/8".
    func margin(_ e: Embedding) -> Double {
        let p = predict(e)
        let sorted = p.values.sorted(by: >)
        guard sorted.count >= 2, sorted[0] > 0 else { return 0 }
        return sorted[0] / (sorted[0] + sorted[1])
    }

    // MARK: inference

    func predict(_ e: Embedding) -> CategoryScores {
        guard e.values.count == dim else { return [:] }
        var logits = [Float](repeating: 0, count: classes.count)
        for c in 0..<classes.count {
            var s = bias[c]
            let w = weights[c]
            for i in 0..<dim { s += w[i] * e.values[i] }
            logits[c] = s
        }
        let mx = logits.max() ?? 0
        var exps = logits.map { expf($0 - mx) }
        let sum = exps.reduce(0, +)
        if sum > 0 { for i in 0..<exps.count { exps[i] /= sum } }
        var out: CategoryScores = [:]
        for (i, c) in classes.enumerated() { out[c] = Double(exps[i]) }
        return out
    }

    // MARK: training — one SGD step of softmax cross-entropy

    func train(_ e: Embedding, label: CleanupCategory) {
        guard e.values.count == dim, let target = classes.firstIndex(of: label) else { return }
        let p = predict(e)
        for (c, cls) in classes.enumerated() {
            let pc = Float(p[cls] ?? 0)
            let y: Float = (c == target) ? 1 : 0
            let grad = pc - y
            guard abs(grad) > 1e-6 else { continue }
            let step = Self.lr * grad
            for i in 0..<dim {
                weights[c][i] -= step * e.values[i] + Self.l2 * weights[c][i]
            }
            bias[c] -= step
        }
        sampleCount += 1
        perClassCount[label.rawValue, default: 0] += 1
    }

    func reset() {
        weights = Array(repeating: [Float](repeating: 0, count: dim), count: classes.count)
        bias = [Float](repeating: 0, count: classes.count)
        sampleCount = 0
        perClassCount = [:]
    }

    /// Blend rule scores with the learned head, weighted by how much data we have.
    /// Head-only categories: ones with no defensible hand-written rule. The rule
    /// classifier can never emit these, so the head is their sole source.
    static let headOnly: Set<CleanupCategory> = [.mapScreenshot, .webShot, .other]

    func fuse(rule: (CleanupCategory, Double), embedding: Embedding?)
        -> (CleanupCategory, Double, Bool) {
        guard let e = embedding, isWarm else { return (rule.0, rule.1, false) }
        let learned = predict(e)
        guard let top = learned.max(by: { $0.value < $1.value }) else {
            return (rule.0, rule.1, false)
        }
        let t = trust
        var blended: CategoryScores = [:]
        for c in classes {
            let r = (c == rule.0) ? rule.1 : 0
            blended[c] = r * (1 - t) + (learned[c] ?? 0) * t
        }
        let best = blended.max { $0.value < $1.value }!
        let usedModel = best.key == top.key && best.key != rule.0
        return (best.key, min(0.98, best.value), usedModel)
    }
}
