import Foundation

/// Binary logistic regression: P(the user will delete this | embedding).
///
/// This is the model that actually makes the swipe deck feel smart. Every single
/// swipe is a labelled example — left = 1, up = 0 — so it starts paying off after
/// a couple of dozen cards, and it learns things no category taxonomy can express
/// ("he deletes his own game screenshots but keeps the ones with friends in them").
///
/// It never *deletes* anything. It only reorders the queue so the cards most
/// likely to be junk come first, which is where the time savings come from.
final class DeletabilityModel: Codable {

    private var w: [Float]
    private var b: Float
    private(set) var positives: Int
    private(set) var negatives: Int
    private let dim: Int
    private static let lr: Float = 0.25
    private static let l2: Float = 2e-4

    init(dim: Int = 768) {
        self.dim = dim
        self.w = [Float](repeating: 0, count: dim)
        self.b = 0
        self.positives = 0
        self.negatives = 0
    }

    var sampleCount: Int { positives + negatives }

    /// Needs examples of *both* classes before its output means anything.
    var isWarm: Bool { positives >= 8 && negatives >= 8 }

    /// Ramps 0 → 0.6 over the first ~150 swipes.
    var influence: Double {
        guard isWarm else { return 0 }
        return min(0.6, Double(sampleCount) / 250.0)
    }

    func score(_ e: Embedding) -> Double {
        guard e.values.count == dim else { return 0.5 }
        var z = b
        for i in 0..<dim { z += w[i] * e.values[i] }
        return Double(1 / (1 + expf(-z)))
    }

    func train(_ e: Embedding, willDelete: Bool) {
        guard e.values.count == dim else { return }
        let y: Float = willDelete ? 1 : 0
        let p = Float(score(e))
        let grad = p - y
        let step = Self.lr * grad
        for i in 0..<dim { w[i] -= step * e.values[i] + Self.l2 * w[i] }
        b -= step
        if willDelete { positives += 1 } else { negatives += 1 }
    }

    func reset() {
        w = [Float](repeating: 0, count: dim)
        b = 0
        positives = 0
        negatives = 0
    }
}

// MARK: - Queue ordering

enum QueuePriority {

    /// Rank candidates so each swipe reclaims as much space as possible per
    /// second of the user's attention.
    ///
    ///   priority = confidence  ×  learned-deletability  ×  size-weight
    ///
    /// `sizeWeight` is logarithmic: a 4 MB screenshot should outrank a 400 KB one,
    /// but a 40 MB video shouldn't monopolise the whole session.
    static func sorted(_ candidates: [Candidate],
                       vision: [String: VisionFeatures],
                       model: DeletabilityModel) -> [Candidate] {
        let inf = model.influence
        return candidates
            .map { c -> (Candidate, Double) in
                let sizeWeight = log2(Double(max(c.snapshot.byteSize, 65_536)) / 65_536) / 10
                var p = c.confidence
                if inf > 0, let e = vision[c.snapshot.id]?.embedding {
                    p = p * (1 - inf) + model.score(e) * inf
                }
                return (c, p * (0.55 + sizeWeight))
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}
