import Foundation
import Vision
import CoreGraphics

/// Layout evidence extracted from a screenshot's text. This is the cheap,
/// training-free signal that separates a chat log from a game HUD from a receipt.
struct TextLayout: Codable, Sendable {
    var lineCount: Int = 0
    var textAreaFraction: Float = 0        // how much of the frame is covered by text
    var medianLineHeight: Float = 0        // relative to image height
    var alignmentBimodality: Float = 0     // chat bubbles alternate left/right ⇒ high
    var shortLineFraction: Float = 0       // chat messages are short
    var gapRegularity: Float = 0           // forms/receipts have evenly spaced rows
    var hasTopBar: Bool = false            // status bar / nav bar at the very top
    var hasBottomBar: Bool = false         // message input field at the bottom
    var digitFraction: Float = 0           // receipts / tickets are digit-heavy
    var averageConfidence: Float = 0
    /// Fraction of lines that share a baseline with another line further right.
    /// A "key            value" form row does; a chat bubble never does. This is
    /// what stops an order-detail screen from reading as a conversation.
    var pairedRowFraction: Float = 0
    /// Fraction of lines whose right edge hugs the right margin. Outgoing chat
    /// bubbles are right-aligned; a form's value column is left-aligned.
    var rightHuggingFraction: Float = 0
    /// A clock reading like `9:41` in the very top-left corner — the iOS status
    /// bar. Ordinary app screenshots keep the status bar; games run full-screen
    /// with it hidden. This is the single strongest training-free signal for
    /// "screenshot of an app" versus "screenshot of a game", and it costs nothing
    /// extra: the OCR pass has already read the text.
    var hasStatusBarClock: Bool = false
    /// How spread out the text is in *both* axes. Chat bubbles, forms and
    /// articles stack in rows; map labels sit wherever the road or the park is.
    var textScatter: Float = 0
    /// How many distinct x positions the lines start at.
    ///
    /// This is the cheapest way to tell apart several layouts that otherwise look
    /// alike: a Settings page is **one** column, a chat is **two** (incoming and
    /// outgoing), a Home Screen of app labels is **four or more** on a regular
    /// grid, and a photograph of text is irregular.
    var textColumnCount: Int = 0
    /// True when those columns are evenly spaced — a grid rather than a jumble.
    var columnsEvenlySpaced: Bool = false
}

/// A Vision FeaturePrint, stored compactly.
///
/// **Vectors from different FeaturePrint revisions are not comparable.** This OS
/// offers revisions [1, 2] and defaults to 2 — but a future iOS could default to
/// 3, at which point every centroid persisted under revision 2 would silently
/// start producing nonsense similarities. So the revision is pinned explicitly
/// and carried with the vector, and anything stored is invalidated on mismatch.
struct Embedding: Codable, Sendable {
    var values: [Float]
    var revision: Int = VisionAnalyzer.featurePrintRevision

    func cosine(_ other: Embedding) -> Float {
        guard values.count == other.values.count, !values.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<values.count {
            dot += values[i] * other.values[i]
            na += values[i] * values[i]
            nb += other.values[i] * other.values[i]
        }
        let denom = sqrt(na) * sqrt(nb)
        return denom == 0 ? 0 : dot / denom
    }

    var normalized: Embedding {
        var n: Float = 0
        for v in values { n += v * v }
        n = sqrt(n)
        guard n > 0 else { return self }
        return Embedding(values: values.map { $0 / n }, revision: revision)
    }

    /// Only compare vectors produced by the same model.
    func comparable(with other: Embedding) -> Bool {
        revision == other.revision && values.count == other.values.count
    }
}

/// Everything Vision gives us for one image. Both requests run on the Neural
/// Engine / GPU, so this stays affordable even over thousands of screenshots.
struct VisionFeatures: Codable, Sendable {
    /// Bump whenever the analysis changes meaning. Without this, results written
    /// by an older build are reused forever — including results from a build whose
    /// OCR silently returned nothing, which is exactly how a fixed classifier can
    /// keep serving broken labels after an update.
    static let currentVersion = 3
    var version: Int = VisionFeatures.currentVersion
    /// The FeaturePrint revision `embedding` was produced with.
    var embeddingRevision: Int = VisionAnalyzer.featurePrintRevision

    var layout: TextLayout
    var embedding: Embedding?
    /// Top labels from Apple's built-in general image classifier. Useful as a
    /// weak prior ("document", "text", "screenshot"), never as the sole verdict.
    var labels: [String]
}

enum VisionAnalyzer {

    /// Pinned FeaturePrint revision. Chosen once, explicitly, so an OS update
    /// that moves the default cannot invalidate stored vectors behind our back.
    /// Falls back to whatever the OS offers if the pinned one disappears — and in
    /// that case the stored-vector version check will correctly wipe the cache.
    static let featurePrintRevision: Int = {
        let want = 2
        let supported = VNGenerateImageFeaturePrintRequest.supportedRevisions
        let chosen = supported.contains(want) ? want : (supported.max() ?? want)
        #if DEBUG
        NSLog("ALBUMCOMPACT FeaturePrint revision=%d（系统支持 %@）",
              chosen, supported.sorted().map(String.init).joined(separator: ","))
        #endif
        return chosen
    }()

    /// Languages actually available on this OS build, resolved once. Passing an
    /// unsupported language to `VNRecognizeTextRequest` makes `perform` **throw**,
    /// which previously took the feature print and the classifier down with it and
    /// left every screenshot classified from colour statistics alone.
    private static let textLanguages: [String] = {
        let wanted = ["zh-Hans", "en-US"]
        let probe = VNRecognizeTextRequest()
        probe.recognitionLevel = .accurate
        let supported = (try? probe.supportedRecognitionLanguages()) ?? []
        let usable = wanted.filter { supported.contains($0) }
        #if DEBUG
        NSLog("ALBUMCOMPACT OCR 可用语言 %@（想要 %@，系统支持 %d 种）",
              usable.joined(separator: ","), wanted.joined(separator: ","), supported.count)
        #endif
        return usable
    }()

    /// Run OCR + feature print + general classification on one image.
    ///
    /// Each request gets its own `perform` call. Batching them is faster, but one
    /// unavailable capability then silently zeroes out all three — and a failure
    /// here is invisible, because the classifier still returns *an* answer.
    static func analyze(_ image: CGImage, wantEmbedding: Bool = true) -> VisionFeatures {
        let aspect = Double(image.width) / Double(max(image.height, 1))

        var layout = TextLayout()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate      // `.fast` cannot read Chinese at all
        text.usesLanguageCorrection = false    // we need box geometry, not transcripts
        if !textLanguages.isEmpty { text.recognitionLanguages = textLanguages }
        if run(text, on: image, label: "text") {
            layout = layoutFrom(text.results ?? [], imageAspect: aspect)
        }

        var embedding: Embedding?
        if wantEmbedding {
            let print = VNGenerateImageFeaturePrintRequest()
            print.revision = featurePrintRevision
            if run(print, on: image, label: "featureprint"),
               let obs = print.results?.first as? VNFeaturePrintObservation {
                    embedding = Embedding(values: floats(from: obs),
                                      revision: featurePrintRevision).normalized
            }
        }

        var labels: [String] = []
        let classify = VNClassifyImageRequest()
        if run(classify, on: image, label: "classify") {
            labels = (classify.results ?? [])
                .filter { $0.confidence > 0.12 }
                .prefix(6)
                .map(\.identifier)
        }

        return VisionFeatures(layout: layout, embedding: embedding, labels: labels)
    }

    private static let failureLock = NSLock()
    nonisolated(unsafe) private static var reportedFailures = Set<String>()

    /// A capability that is missing is missing for the whole run, so report it
    /// once. `VNGenerateImageFeaturePrintRequest` and `VNClassifyImageRequest`
    /// both fail on the Simulator ("Failed to create espresso context") because
    /// there is no Neural Engine to bind to — the rule classifier has to carry
    /// the whole load there, and the learned head simply stays cold.
    private static func noteFailure(_ label: String, _ error: Error) {
        failureLock.lock()
        let isNew = reportedFailures.insert(label).inserted
        failureLock.unlock()
        guard isNew else { return }
        #if DEBUG
        NSLog("ALBUMCOMPACT Vision %@ 不可用: %@（本次运行只报一次）",
              label, error.localizedDescription)
        #endif
    }

    /// True when this device produced at least one feature print. When it is
    /// false, on-device learning cannot run and the UI should say so instead of
    /// promising it will get smarter.
    static var embeddingsAvailable: Bool {
        failureLock.lock(); defer { failureLock.unlock() }
        return !reportedFailures.contains("featureprint")
    }

    @discardableResult
    private static func run(_ request: VNRequest, on image: CGImage, label: String) -> Bool {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            return true
        } catch {
            noteFailure(label, error)
            return false
        }
    }

    private static func floats(from obs: VNFeaturePrintObservation) -> [Float] {
        let count = obs.elementCount
        var out = [Float](repeating: 0, count: count)
        obs.data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Float.self).baseAddress else { return }
            for i in 0..<count { out[i] = base[i] }
        }
        return out
    }

    // MARK: layout derivation

    private static func layoutFrom(_ obs: [VNRecognizedTextObservation],
                                   imageAspect: Double) -> TextLayout {
        var l = TextLayout()
        guard !obs.isEmpty else { return l }

        l.lineCount = obs.count

        // Vision boxes are normalised, origin bottom-left.
        var area: Float = 0
        var heights: [Float] = []
        var lefts: [Float] = []
        var widths: [Float] = []
        var centersY: [Float] = []
        var conf: Float = 0
        var digits = 0, chars = 0

        for o in obs {
            let b = o.boundingBox
            area += Float(b.width * b.height)
            heights.append(Float(b.height))
            lefts.append(Float(b.minX))
            widths.append(Float(b.width))
            centersY.append(Float(b.midY))
            conf += o.confidence
            if let top = o.topCandidates(1).first {
                for ch in top.string {
                    chars += 1
                    if ch.isNumber { digits += 1 }
                }
                // Vision's origin is bottom-left, so the status bar is maxY ≈ 1.
                if b.maxY > 0.955 && b.minX < 0.38 && looksLikeClock(top.string) {
                    l.hasStatusBarClock = true
                }
            }
        }

        l.textAreaFraction = min(1, area)
        l.averageConfidence = conf / Float(obs.count)
        l.medianLineHeight = median(heights)
        l.digitFraction = chars == 0 ? 0 : Float(digits) / Float(chars)
        l.shortLineFraction = Float(widths.filter { $0 < 0.45 }.count) / Float(widths.count)

        // Chat signature: line starts cluster into two groups — one near the left
        // edge (incoming) and one pushed right (outgoing). Measure that as the
        // fraction of mass in the outer thirds of the left-edge distribution.
        if lefts.count >= 4 {
            let leftish = lefts.filter { $0 < 0.22 }.count
            let rightish = lefts.filter { $0 > 0.38 }.count
            let both = Float(min(leftish, rightish)) / Float(lefts.count)
            l.alignmentBimodality = min(1, both * 2.4)      // 0 unless BOTH sides are populated
        }

        // Row-gap regularity: receipts / settings pages have near-constant spacing.
        if centersY.count >= 4 {
            let sorted = centersY.sorted()
            var gaps: [Float] = []
            for i in 1..<sorted.count { gaps.append(sorted[i] - sorted[i - 1]) }
            let m = gaps.reduce(0, +) / Float(gaps.count)
            if m > 0 {
                let variance = gaps.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(gaps.count)
                l.gapRegularity = max(0, 1 - min(1, sqrt(variance) / m))
            }
        }

        // Paired rows: two boxes at (nearly) the same height, separated horizontally.
        if obs.count >= 4 {
            let boxes = obs.map { $0.boundingBox }
            let tol = max(0.004, Double(l.medianLineHeight) * 0.45)
            var paired = 0
            for (i, a) in boxes.enumerated() {
                for (j, b) in boxes.enumerated() where i != j {
                    if abs(a.midY - b.midY) < tol && b.minX - a.maxX > 0.02 {
                        paired += 1
                        break
                    }
                }
            }
            l.pairedRowFraction = Float(paired) / Float(boxes.count)
            l.rightHuggingFraction =
                Float(boxes.filter { $0.maxX > 0.90 }.count) / Float(boxes.count)
        }

        // Scatter: how much of the frame's area the text bounding boxes span,
        // measured as the product of their x-spread and y-spread. Rows of text
        // fill one axis; map labels fill both.
        if lefts.count >= 5 {
            let xs = obs.map { Float($0.boundingBox.midX) }
            let ys = obs.map { Float($0.boundingBox.midY) }
            func spread(_ v: [Float]) -> Float {
                let m = v.reduce(0, +) / Float(v.count)
                let varr = v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(v.count)
                return sqrt(varr)
            }
            // 0.29 is the standard deviation of a uniform distribution on [0,1].
            l.textScatter = min(1, (spread(xs) / 0.29) * (spread(ys) / 0.29))
        }

        // Cluster the line starts. 0.06 of the width is about one character at
        // typical UI sizes — wide enough to absorb kerning, tight enough that a
        // real second column stays separate.
        if lefts.count >= 4 {
            let sorted = lefts.sorted()
            var clusters: [[Float]] = [[sorted[0]]]
            for v in sorted.dropFirst() {
                if v - (clusters[clusters.count - 1].last ?? v) <= 0.06 {
                    clusters[clusters.count - 1].append(v)
                } else {
                    clusters.append([v])
                }
            }
            // Ignore columns holding a single stray line (a title, a badge).
            let solid = clusters.filter { $0.count >= 2 }
            l.textColumnCount = solid.count
            if solid.count >= 3 {
                let centres = solid.map { $0.reduce(0, +) / Float($0.count) }.sorted()
                var gaps: [Float] = []
                for i in 1..<centres.count { gaps.append(centres[i] - centres[i - 1]) }
                let m = gaps.reduce(0, +) / Float(gaps.count)
                if m > 0 {
                    let sd = sqrt(gaps.map { ($0 - m) * ($0 - m) }
                                      .reduce(0, +) / Float(gaps.count))
                    l.columnsEvenlySpaced = sd / m < 0.35
                }
            }
        }

        l.hasTopBar = obs.contains { $0.boundingBox.minY > 0.955 }
        l.hasBottomBar = obs.contains { $0.boundingBox.maxY < 0.075 }

        return l
    }

    /// `9:41`, `09:41`, `9:41 AM`, and the full-width-colon variants some
    /// keyboards produce. Deliberately narrow: a false positive here would push
    /// real game captures into the app-screenshot bucket.
    private static func looksLikeClock(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "：", with: ":")
            .uppercased()
            .replacingOccurrences(of: " AM", with: "")
            .replacingOccurrences(of: " PM", with: "")
        guard t.count >= 3, t.count <= 5, t.contains(":") else { return false }
        let parts = t.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              parts[1].count == 2, h >= 0, h <= 23, m >= 0, m <= 59
        else { return false }
        return true
    }

    private static func median(_ v: [Float]) -> Float {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[s.count / 2]
    }
}
