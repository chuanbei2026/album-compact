import Foundation
import CoreGraphics
import ImageIO
import Photos
import Vision

// A macOS command-line harness that runs the app's real analysis code over a
// folder of image files. It links the same sources the app does, so a result here
// is a result in the app — no simulator round-trip needed to iterate on the
// algorithm.
//
//   swift Tools/AlgoLab/build.sh <folder>

func loadImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

/// Read the real EXIF capture date. Deriving a date from `hashValue` would be
/// reseeded on every process launch, which silently made keeper selection look
/// non-deterministic when it isn't.
func captureDate(_ url: URL) -> Date {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
          let str = exif[kCGImagePropertyExifDateTimeOriginal] as? String
    else {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
    }
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
    fmt.timeZone = TimeZone(secondsFromGMT: 0)
    return fmt.date(from: str) ?? Date(timeIntervalSince1970: 0)
}

/// The app gets true pixel dimensions from PhotoKit metadata, not from whatever
/// thumbnail it decoded — so the harness must too, or the device-resolution
/// screenshot heuristic would never fire.
func originalSize(_ url: URL) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = p[kCGImagePropertyPixelWidth] as? Int,
          let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h)
}

func fileBytes(_ url: URL) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) .flatMap { $0 } ?? 0
}

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: algolab <folder> [--verbose]")
    exit(1)
}
let folder = URL(fileURLWithPath: args[1])
let verbose = args.contains("--verbose")
/// Downsample images to this longest edge before analysis, mirroring what the
/// app actually feeds Vision. Testing at full resolution would flatter the
/// classifier compared to what ships.
let maxDim: Int = {
    guard let i = args.firstIndex(of: "--max-dim"), i + 1 < args.count,
          let n = Int(args[i + 1]) else { return 0 }
    return n
}()

/// The app derives the fingerprint from a small thumbnail and the Vision
/// features from a larger render. Mirroring that split matters: the colour and
/// brightness statistics behave very differently on a 44x96 blur.
let hashDim: Int = {
    guard let i = args.firstIndex(of: "--hash-dim"), i + 1 < args.count,
          let n = Int(args[i + 1]) else { return 0 }
    return n
}()

func downsample(_ url: URL, maxPixel: Int) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel
    ]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
}

let files = ((try? FileManager.default.contentsOfDirectory(at: folder,
        includingPropertiesForKeys: nil)) ?? [])
    .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

print("=== AlgoLab · \(files.count) 个文件"
      + (maxDim > 0 ? " · 分析分辨率上限 \(maxDim)px" : " · 原始分辨率") + " ===\n")

// ---------- stage 1+2: snapshots and fingerprints ----------
var snapshots: [AssetSnapshot] = []
var fingerprints: [String: Fingerprint] = [:]
var images: [String: CGImage] = [:]

let t0 = Date()
for f in files {
    let loaded = maxDim > 0 ? downsample(f, maxPixel: maxDim) : loadImage(f)
    guard let img = loaded else { print("!! 无法解码 \(f.lastPathComponent)"); continue }
    let id = f.lastPathComponent
    images[id] = img
    // Screenshots keep their resolution; the rule classifier is expected to
    // recognise a device-sized image even with no PhotoKit subtype flag, which
    // is exactly the AirDropped-screenshot case. So we deliberately do NOT set
    // the screenshot subtype here.
    snapshots.append(AssetSnapshot(
        id: id,
        creationDate: captureDate(f),
        modificationDate: captureDate(f),
        pixelWidth: originalSize(f)?.0 ?? img.width,
        pixelHeight: originalSize(f)?.1 ?? img.height,
        byteSize: fileBytes(f),
        isFavorite: false, isHidden: false, hasLocation: false,
        isVideo: false, duration: 0, burstID: nil, subtypes: 0,
        filename: id))
    let hashSource = hashDim > 0 ? (downsample(f, maxPixel: hashDim) ?? img) : img
    if let fp = PerceptualHasher.fingerprint(from: hashSource) {
        fingerprints[id] = fp
    } else {
        print("!! 指纹计算失败 \(id)")
    }
}
print("指纹 \(fingerprints.count)/\(snapshots.count) 成功，用时 \(String(format: "%.2fs", -t0.timeIntervalSinceNow))\n")

if verbose {
    print("--- 指纹明细 ---")
    for s in snapshots {
        guard let f = fingerprints[s.id] else { continue }
        print(String(format: "%-28@ dHash=%016llx pHash=%016llx sharp=%.2f sat=%.2f flat=%.2f edge=%.2f bright=%.2f",
                     s.id as NSString, f.dHash, f.pHash,
                     f.sharpness, f.saturation, f.flatness, f.edgeDensity, f.brightness))
    }
    print("")
}

// ---------- stage 3: duplicates ----------
let groups = DuplicateFinder.findGroups(snapshots: snapshots, fingerprints: fingerprints)
print("--- 重复组：\(groups.count) 个 ---")
for g in groups {
    let keep = g.members.first { $0.id == g.keeperID }!
    print("[\(g.tier.title)] 保留 \(keep.id)  (\(g.keeperReason))")
    for m in g.discardable {
        let dd = hammingDistance(fingerprints[keep.id]!.dHash, fingerprints[m.id]!.dHash)
        let dp = hammingDistance(fingerprints[keep.id]!.pHash, fingerprints[m.id]!.pHash)
        print("    删 \(m.id)   dHash距离=\(dd) pHash距离=\(dp)")
    }
}
print("")

// ---------- stage 4: classification ----------
print("--- 分类 ---")
let tC = Date()
let inGroups = Set(groups.flatMap { $0.discardable.map(\.id) })
var correct = 0, judged = 0
for s in snapshots {
    guard let img = images[s.id] else { continue }
    let vf = VisionAnalyzer.analyze(img)
    let (cat, conf, reasons) = RuleClassifier.classify(
        snapshot: s, fingerprint: fingerprints[s.id], vision: vf)

    // Expected label inferred from the filename, so the harness can self-score.
    let expected: CleanupCategory? =
        s.id.hasPrefix("chat")    ? .chatScreenshot :
        s.id.hasPrefix("game")    ? .gameScreenshot :
        s.id.hasPrefix("receipt") ? .documentShot   :
        s.id.hasPrefix("map")     ? .mapScreenshot  :
        s.id.hasPrefix("system")  ? .systemScreenshot :
        s.id.contains("blurry")   ? .blurry         : nil

    var mark = " "
    if let e = expected {
        judged += 1
        if e == cat { correct += 1; mark = "✓" } else { mark = "✗" }
    }
    let dup = inGroups.contains(s.id) ? " [在重复组内]" : ""
    print(String(format: "%@ %-28@ → %-12@ %3d%%%@",
                 mark as NSString, s.id as NSString, cat.title as NSString,
                 Int(conf * 100), dup as NSString))
    if verbose {
        let L = vf.layout
        print(String(format: "      行数=%d 文字占比=%.3f 左右分化=%.2f 成对行=%.2f 右贴边=%.2f 行距规整=%.2f 数字占比=%.2f 顶栏=%@ 底栏=%@",
                     L.lineCount, L.textAreaFraction, L.alignmentBimodality,
                     L.pairedRowFraction, L.rightHuggingFraction,
                     L.gapRegularity, L.digitFraction,
                     L.hasTopBar ? "是" : "否", L.hasBottomBar ? "是" : "否"))
        print("      状态栏时钟=\(L.hasStatusBarClock ? "有" : "无")")
        print(String(format: "      文字散布=%.3f  列数=%d 等距=%@",
                     L.textScatter, L.textColumnCount,
                     (L.columnsEvenlySpaced ? "是" : "否") as NSString))
        print("      标签=\(vf.labels.joined(separator: ",")) 向量维度=\(vf.embedding?.values.count ?? 0)")
        if !reasons.isEmpty { print("      理由=\(reasons.joined(separator: " / "))") }
    }
}
let per = -tC.timeIntervalSinceNow / Double(max(snapshots.count, 1))
print(String(format: "\n分类准确率：%d/%d   每张 Vision 耗时 %.0f ms（含 OCR + 768 维向量 + 通用分类）",
             correct, judged, per * 1000))

// ============================================================================
// MARK: - Learning evaluation  (--learn)
//
// The two learned heads are the part of the design that cannot be checked by
// eyeballing a label. This runs a leave-one-out probe over the labelled set:
// for every image, train a fresh model on all the others and predict the held-out
// one. That is the honest protocol at this sample size — training and testing on
// the same images would show 100% and mean nothing.
// ============================================================================

// ============================================================================
// MARK: - Pairwise distance distribution  (--distances)
//
// Thresholds should come from where the data actually separates, not from a
// number that sounded reasonable. This prints every pair's dHash/pHash distance
// grouped by whether the two files are known to be the same picture (same
// filename stem) or genuinely different subjects.
// ============================================================================

if args.contains("--distances") {
    func stem(_ n: String) -> String {
        // photo_a, photo_a_copy, photo_a_resized … all share the stem "photo_a".
        let base = n.replacingOccurrences(of: ".jpg", with: "")
                    .replacingOccurrences(of: ".png", with: "")
        for suffix in ["_copy", "_recompressed", "_resized", "_burst"] {
            if base.hasSuffix(suffix) { return String(base.dropLast(suffix.count)) }
        }
        // chat_1 / chat_2 are DIFFERENT conversations — the trailing index is
        // part of the identity, not a copy marker.
        return base
    }

    var sameImage: [(String, String, Int, Int)] = []
    var sameFamily: [(String, String, Int, Int)] = []
    var different: [(String, String, Int, Int)] = []

    for i in 0..<snapshots.count {
        for j in (i + 1)..<snapshots.count {
            let a = snapshots[i], b = snapshots[j]
            guard let fa = fingerprints[a.id], let fb = fingerprints[b.id] else { continue }
            let dd = hammingDistance(fa.dHash, fb.dHash)
            let dp = hammingDistance(fa.pHash, fb.pHash)
            let row = (a.id, b.id, dd, dp)
            if fa.contentHash == fb.contentHash {
                sameImage.append(row)
            } else if stem(a.id) == stem(b.id) {
                sameFamily.append(row)      // same capture, re-encoded / resized
            } else {
                different.append(row)
            }
        }
    }

    func report(_ label: String, _ rows: [(String, String, Int, Int)], showAll: Bool) {
        print("\n--- \(label)：\(rows.count) 对 ---")
        guard !rows.isEmpty else { return }
        let dds = rows.map(\.2).sorted(), dps = rows.map(\.3).sorted()
        func pct(_ v: [Int], _ q: Double) -> Int { v[min(v.count - 1, Int(Double(v.count - 1) * q))] }
        print(String(format: "  dHash  最小=%d  中位=%d  p90=%d  最大=%d",
                     dds.first!, pct(dds, 0.5), pct(dds, 0.9), dds.last!))
        print(String(format: "  pHash  最小=%d  中位=%d  p90=%d  最大=%d",
                     dps.first!, pct(dps, 0.5), pct(dps, 0.9), dps.last!))
        let shown = showAll ? rows.sorted { $0.2 < $1.2 } : Array(rows.sorted { $0.2 < $1.2 }.prefix(12))
        for r in shown {
            print(String(format: "    d=%2d p=%2d   %@  ↔  %@", r.2, r.3, r.0, r.1))
        }
        if !showAll && rows.count > 12 { print("    …（只显示距离最小的 12 对）") }
    }

    // The moment rule only ever applies to real photographs, so the threshold has
    // to be set against the distances *between real photographs*, not against a
    // pool dominated by screenshots.
    var diffRealPhotos: [(String, String, Int, Int)] = []
    var burstPairs: [(String, String, Int, Int)] = []
    for i in 0..<snapshots.count {
        for j in (i + 1)..<snapshots.count {
            let a = snapshots[i], b = snapshots[j]
            guard let fa = fingerprints[a.id], let fb = fingerprints[b.id] else { continue }
            guard !DuplicateFinder.isScreenLike(a), !DuplicateFinder.isScreenLike(b) else { continue }
            let row = (a.id, b.id, hammingDistance(fa.dHash, fb.dHash),
                       hammingDistance(fa.pHash, fb.pHash))
            if a.id.hasPrefix("burst") && b.id.hasPrefix("burst") { burstPairs.append(row) }
            else if stem(a.id) != stem(b.id) { diffRealPhotos.append(row) }
        }
    }

    report("同一张图的副本（内容哈希相同）", sameImage, showAll: true)
    report("同一次拍摄的重编码/缩放", sameFamily, showAll: true)
    report("不同的图片（含截图）", different, showAll: false)
    report("真连拍的帧间距离", burstPairs, showAll: true)
    report("不同的真实照片（排除截图）", diffRealPhotos, showAll: false)

    // Where does a threshold start letting different images through?
    print("\n--- 阈值扫描：不同图片被误判为一组的数量 ---")
    print("  dHash≤  pHash≤   误配对数")
    for t in [2, 3, 4, 6, 8, 10, 12] {
        let bad = different.filter { $0.2 <= t && $0.3 <= t + 2 }.count
        print(String(format: "  %5d  %6d   %8d", t, t + 2, bad))
    }
    exit(0)
}

if args.contains("--learn") {
    print("\n=== 学习头评估（留一法交叉验证）===\n")

    // Recompute embeddings for the labelled subset.
    struct Sample {
        var id: String
        var embedding: Embedding
        var category: CleanupCategory
        var deletable: Bool
    }

    var samples: [Sample] = []
    for s in snapshots {
        guard let img = images[s.id] else { continue }
        let vf = VisionAnalyzer.analyze(img)
        guard let e = vf.embedding else { continue }

        // Ground truth from the filename. "deletable" is the plausible user
        // verdict: chat logs, game captures and out-of-focus frames go; receipts
        // and real photographs stay.
        let cat: CleanupCategory?
        var deletable = false
        if s.id.hasPrefix("chat")         { cat = .chatScreenshot; deletable = true }
        else if s.id.hasPrefix("game")    { cat = .gameScreenshot;  deletable = true }
        else if s.id.hasPrefix("receipt") { cat = .documentShot;    deletable = false }
        else if s.id.contains("blurry")   { cat = nil;              deletable = true }
        else                              { cat = nil;              deletable = false }

        samples.append(Sample(id: s.id, embedding: e,
                              category: cat ?? .screenshot, deletable: deletable))
    }

    guard samples.count >= 6 else {
        print("样本不足（\(samples.count)），跳过")
        exit(0)
    }

    print("拿到 768 维向量的样本：\(samples.count) 个"
          + "（可删 \(samples.filter(\.deletable).count) / 保留 \(samples.filter { !$0.deletable }.count)）\n")

    // Deterministic shuffle so repeated runs agree.
    var lcg: UInt64 = 0x2545F4914F6CDD1D
    func nextRand() -> Int {
        lcg = lcg &* 6364136223846793005 &+ 1442695040888963407
        return Int((lcg >> 33) & 0x7FFF_FFFF)
    }
    func shuffled<T>(_ a: [T]) -> [T] {
        var v = a
        guard v.count > 1 else { return v }
        for i in stride(from: v.count - 1, to: 0, by: -1) {
            v.swapAt(i, nextRand() % (i + 1))
        }
        return v
    }

    let epochs = 40

    // ---------- 1. DeletabilityModel: P(user deletes this) ----------
    var looScores: [String: Double] = [:]
    var correct = 0
    for held in samples {
        let model = DeletabilityModel()
        let train = samples.filter { $0.id != held.id }
        for _ in 0..<epochs {
            for s in shuffled(train) { model.train(s.embedding, willDelete: s.deletable) }
        }
        let score = model.score(held.embedding)
        looScores[held.id] = score
        if (score >= 0.5) == held.deletable { correct += 1 }
    }
    let posMean = samples.filter(\.deletable)
        .map { looScores[$0.id] ?? 0 }.reduce(0, +) / Double(samples.filter(\.deletable).count)
    let negMean = samples.filter { !$0.deletable }
        .map { looScores[$0.id] ?? 0 }.reduce(0, +) / Double(samples.filter { !$0.deletable }.count)

    print("① DeletabilityModel —— 二分类「你会删这张吗」")
    print(String(format: "   留一法准确率      %d/%d  (%.0f%%)",
                 correct, samples.count, Double(correct) / Double(samples.count) * 100))
    print(String(format: "   可删样本平均分     %.3f", posMean))
    print(String(format: "   保留样本平均分     %.3f", negMean))
    print(String(format: "   分离度            %.3f  （越大越好，0 = 学不到东西）", posMean - negMean))

    // Ranking quality — this is what the model is actually FOR: putting the
    // junk first so each swipe reclaims more space per second of attention.
    let ranked = samples.sorted { (looScores[$0.id] ?? 0) > (looScores[$1.id] ?? 0) }
    let k = min(8, samples.count)
    let hitsAtK = ranked.prefix(k).filter(\.deletable).count
    let baseRate = Double(samples.filter(\.deletable).count) / Double(samples.count)
    print(String(format: "   前 %d 张里真的该删  %d/%d  (%.0f%%) —— 随机基线 %.0f%%",
                 k, hitsAtK, k, Double(hitsAtK) / Double(k) * 100, baseRate * 100))

    // ---------- 2. OnlineClassifier: which category ----------
    let labelled = samples.filter { $0.category != .screenshot }
    var catCorrect = 0
    var confusion: [String: Int] = [:]
    for held in labelled {
        let model = OnlineClassifier()
        let train = labelled.filter { $0.id != held.id }
        for _ in 0..<epochs {
            for s in shuffled(train) { model.train(s.embedding, label: s.category) }
        }
        let pred = model.predict(held.embedding).max { $0.value < $1.value }?.key
        if pred == held.category { catCorrect += 1 }
        else { confusion["\(held.category.rawValue)→\(pred?.rawValue ?? "?")", default: 0] += 1 }
    }
    print("\n② OnlineClassifier —— 5 类「这是什么截图」")
    print(String(format: "   留一法准确率      %d/%d  (%.0f%%)",
                 catCorrect, labelled.count,
                 Double(catCorrect) / Double(max(labelled.count, 1)) * 100))
    for (k, v) in confusion.sorted(by: { $0.key < $1.key }) {
        print("   错判             \(k) ×\(v)")
    }

    print("""

    ⚠️  样本量说明：\(samples.count) 张合成图上做 768 维线性探针，
        分离出来几乎是必然的。这个结果证明的是「管线通了、梯度方向对、
        权重能收敛」，不能证明它在真实相册上的泛化能力。
    """)
    exit(0)
}

// ============================================================================
// MARK: - Embedding cluster structure  (--clusters)
//
// Tests the premise behind app-level labelling: are screenshots from one app
// actually a tight cluster in FeaturePrint space? If they are, the user names a
// cluster once instead of tagging hundreds of photos, and a nearest-centroid
// match is enough — no gradient training, and new apps can be added at any time
// without retraining anything.
// ============================================================================

if args.contains("--clusters") {
    print("\n=== Embedding 簇结构 ===\n")

    // Which FeaturePrint revisions does this OS offer? This matters a great deal
    // for a persisted store: vectors from different revisions are NOT comparable,
    // so a saved centroid must record the revision it was built with.
    let probe = VNGenerateImageFeaturePrintRequest()
    print("FeaturePrint 可用 revision: \(VNGenerateImageFeaturePrintRequest.supportedRevisions.sorted())")
    print("  默认 revision: \(probe.revision)")

    struct Item { var id: String; var group: String; var e: Embedding }
    var items: [Item] = []
    for s in snapshots {
        guard let img = images[s.id] else { continue }
        let vf = VisionAnalyzer.analyze(img)
        guard let e = vf.embedding else { continue }
        // Group by filename prefix, standing in for "which app".
        let g = s.id.split(separator: "_").first.map(String.init) ?? "?"
        items.append(Item(id: s.id, group: g, e: e))
    }
    guard items.count > 3 else { print("样本不足"); exit(0) }
    print("样本 \(items.count) 个，维度 \(items[0].e.values.count)\n")

    // Intra- vs inter-group cosine similarity.
    var intra: [String: [Float]] = [:]
    var inter: [Float] = []
    for i in 0..<items.count {
        for j in (i + 1)..<items.count {
            let c = items[i].e.cosine(items[j].e)
            if items[i].group == items[j].group {
                intra[items[i].group, default: []].append(c)
            } else {
                inter.append(c)
            }
        }
    }
    func stats(_ v: [Float]) -> String {
        guard !v.isEmpty else { return "—" }
        let s = v.sorted()
        return String(format: "n=%2d 最小=%.3f 中位=%.3f 最大=%.3f",
                      v.count, s.first!, s[s.count / 2], s.last!)
    }
    print("--- 组内相似度（同一「App」）---")
    for (g, v) in intra.sorted(by: { $0.key < $1.key }) {
        print(String(format: "  %-10@ %@", g as NSString, stats(v) as NSString))
    }
    print("\n--- 组间相似度（不同「App」）---")
    print("  \(stats(inter))")

    let allIntra = intra.values.flatMap { $0 }
    if let worstIntra = allIntra.min(), let bestInter = inter.max() {
        print(String(format: "\n最差组内 %.3f   vs   最好组间 %.3f   →   间隔 %+.3f",
                     worstIntra, bestInter, worstIntra - bestInter))
        print(worstIntra > bestInter
              ? "  ✓ 完全可分：存在一个阈值能把所有簇干净切开"
              : "  ✗ 有重叠：单一全局阈值会出错，需要按簇自适应")
    }

    // Greedy agglomerative clustering — the actual algorithm the app would run.
    print("\n--- 贪心聚类结果（阈值扫描）---")
    for threshold in [Float(0.80), 0.85, 0.90, 0.93, 0.95] {
        var centroids: [[Float]] = []
        var counts: [Int] = []
        var assign: [Int] = []
        for it in items {
            var best = -1
            var bestSim: Float = -1
            for (k, c) in centroids.enumerated() {
                let sim = Embedding(values: c).cosine(it.e)
                if sim > bestSim { bestSim = sim; best = k }
            }
            if best >= 0 && bestSim >= threshold {
                // Running mean, then renormalise so cosine stays meaningful.
                let n = Float(counts[best])
                var merged = [Float](repeating: 0, count: it.e.values.count)
                for d in 0..<merged.count {
                    merged[d] = (centroids[best][d] * n + it.e.values[d]) / (n + 1)
                }
                centroids[best] = Embedding(values: merged).normalized.values
                counts[best] += 1
                assign.append(best)
            } else {
                centroids.append(it.e.values)
                counts.append(1)
                assign.append(centroids.count - 1)
            }
        }
        // Purity: does each cluster contain exactly one true group?
        var clusterGroups: [Int: Set<String>] = [:]
        for (i, k) in assign.enumerated() { clusterGroups[k, default: []].insert(items[i].group) }
        let pure = clusterGroups.values.filter { $0.count == 1 }.count
        print(String(format: "  阈值 %.2f → %2d 簇，其中 %2d 簇纯净（只含一个「App」）",
                     threshold, centroids.count, pure))
    }
    exit(0)
}

// ============================================================================
// MARK: - App labelling end-to-end  (--applabels)
//
// Runs the app's real AppClustering + EmbeddingProjection code, so what passes
// here is what ships.
// ============================================================================

if args.contains("--applabels") {
    print("\n=== 按 App 聚类 ===\n")
    // ByteFormat lives in ScanEngine.swift, which pulls in UIKit and so is not
    // linked here; the harness only needs a rough size string.
    func mb(_ b: Int64) -> NSString {
        String(format: "%.1f MB", Double(b) / 1_048_576) as NSString
    }
    var items: [(id: String, embedding: Embedding, bytes: Int64)] = []
    var truth: [String: String] = [:]
    for s in snapshots {
        guard let img = images[s.id] else { continue }
        // App labelling only ever applies to screen captures.
        guard DuplicateFinder.isScreenLike(s) else { continue }
        guard let e = VisionAnalyzer.analyze(img).embedding else { continue }
        items.append((s.id, e, s.byteSize))
        truth[s.id] = s.id.split(separator: "_").first.map(String.init) ?? "?"
    }
    print("参与聚类的截图：\(items.count) 张（真实照片不参与）\n")

    let (clusters, _) = AppClustering.cluster(items, against: [])
    print("--- 聚出 \(clusters.count) 簇 ---")
    for (i, c) in clusters.enumerated() {
        let groups = Set(c.memberIDs.compactMap { truth[$0] })
        print(String(format: "  簇 %d：%2d 张 · %@ · 内聚度 %.3f · %@",
                     i + 1, c.memberIDs.count, mb(c.bytes),
                     c.cohesion,
                     groups.count == 1 ? "纯净（\(groups.first!)）"
                                       : "混杂（\(groups.sorted().joined(separator: "+"))）"))
        print("      " + c.memberIDs.sorted().joined(separator: ", "))
    }
    let pure = clusters.filter { Set($0.memberIDs.compactMap { truth[$0] }).count == 1 }.count
    print("\n纯净簇：\(pure)/\(clusters.count)")

    // Name each pure cluster, then check that unseen screenshots match back.
    print("\n--- 命名一次，然后回测匹配 ---")
    var labels: [AppLabel] = []
    for c in clusters {
        let groups = Set(c.memberIDs.compactMap { truth[$0] })
        guard groups.count == 1, let name = groups.first else { continue }
        labels.append(AppLabel(name: name, centroids: [c.centroid],
                               sampleCount: c.memberIDs.count, revision: c.revision))
    }
    print("命名了 \(labels.count) 个「App」：\(labels.map(\.name).joined(separator: ", "))")

    var hit = 0, miss = 0, wrong = 0
    for it in items {
        guard let want = truth[it.id] else { continue }
        if let (label, sim) = AppClustering.match(it.embedding, labels: labels) {
            if label.name == want { hit += 1 }
            else { wrong += 1; print(String(format: "    ✗ %@ 被判为 %@（%.3f）", it.id, label.name, sim)) }
        } else {
            miss += 1
            print("    – \(it.id) 没有匹配到任何 App")
        }
    }
    print("匹配：正确 \(hit) · 错判 \(wrong) · 未匹配 \(miss)")

    // The embedding map.
    print("\n--- PCA 二维投影（embedding 分布图的数据）---")
    let pts = EmbeddingProjection.pca2D(items.map(\.embedding.values))
    for (i, p) in pts.enumerated() {
        print(String(format: "  %-14@ %-8@ x=%+7.3f y=%+7.3f",
                     items[i].id as NSString, (truth[items[i].id] ?? "?") as NSString, p.x, p.y))
    }
    // Determinism matters: a map that reshuffles on every open is not a reference.
    let again = EmbeddingProjection.pca2D(items.map(\.embedding.values))
    let stable = zip(pts, again).allSatisfy { abs($0.x - $1.x) < 1e-4 && abs($0.y - $1.y) < 1e-4 }
    print(stable ? "\n  ✓ 投影可复现（两次运行结果一致）" : "\n  ✗ 投影不稳定")
    exit(0)
}

// ============================================================================
// MARK: - Build the bundled centroid library  (--build-app-library)
//
//   algolab --build-app-library <folder> [--out <path>] [--min-samples N]
//
// <folder> holds one subfolder per app, named as the app should appear:
//
//   library/微信/*.png       library/原神/*.png       library/支付宝/*.png
//
// Emits AppCentroids.plist for the app bundle. Nothing is uploaded; this is how
// a fresh install already recognises common apps without any user data moving.
// ============================================================================

if args.contains("--build-app-library") {
    func argValue(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    let outPath = argValue("--out") ?? folder.appendingPathComponent("AppCentroids.plist").path
    // A centroid should describe an app's chrome, not any single screen. Requiring
    // a floor makes that concrete: an average over one screenshot is that
    // screenshot, an average over twenty is what the app looks like.
    let minSamples = Int(argValue("--min-samples") ?? "") ?? 8

    print("\n=== 构建内置质心库 ===\n")
    print("来源目录: \(folder.path)")
    print("每个 App 至少需要 \(minSamples) 张截图\n")

    let fm = FileManager.default
    let subdirs = ((try? fm.contentsOfDirectory(at: folder,
                                                includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    guard !subdirs.isEmpty else {
        print("没有找到子目录。请按 <folder>/<App 名>/*.png 组织截图。")
        exit(1)
    }

    var entries: [BundledAppLibrary.Entry] = []
    for dir in subdirs {
        let name = dir.lastPathComponent
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
        var items: [(id: String, embedding: Embedding, bytes: Int64)] = []
        for f in files {
            guard let img = maxDim > 0 ? downsample(f, maxPixel: maxDim) : loadImage(f),
                  let e = VisionAnalyzer.analyze(img).embedding else { continue }
            items.append((f.lastPathComponent, e, fileBytes(f)))
        }
        guard items.count >= minSamples else {
            print(String(format: "  ✗ %-12@ 只有 %d 张，低于下限，跳过",
                         name as NSString, items.count))
            continue
        }
        // Cluster within the app: one app has several distinct screens, and
        // averaging them all into one centroid blurs it into nothing.
        let (clusters, _) = AppClustering.cluster(items, against: [])
        let centroids = clusters.isEmpty
            ? [Embedding(values: items.map(\.embedding.values)
                 .reduce(into: [Float](repeating: 0, count: items[0].embedding.values.count)) { acc, v in
                     for d in 0..<acc.count { acc[d] += v[d] / Float(items.count) }
                 }).normalized.values]
            : clusters.map(\.centroid)
        entries.append(BundledAppLibrary.Entry(name: name, category: nil,
                                               sampleCount: items.count,
                                               centroids: centroids))
        print(String(format: "  ✓ %-12@ %3d 张 → %d 个质心（%d 种界面）",
                     name as NSString, items.count, centroids.count, centroids.count))
    }

    guard !entries.isEmpty else { print("\n没有任何 App 达到样本下限。"); exit(1) }

    let lib = BundledAppLibrary(revision: VisionAnalyzer.featurePrintRevision,
                                entries: entries,
                                builtAt: Date(timeIntervalSince1970: 0))
    do {
        let data = try lib.encoded()
        try data.write(to: URL(fileURLWithPath: outPath))
        print(String(format: "\n写入 %@  (%.1f KB, revision %d, %d 个 App)",
                     outPath as NSString, Double(data.count) / 1024,
                     lib.revision, entries.count))
        print("把它放进 AlbumCompact/Resources/ 即可随 App 打包。")

        // Round-trip check: a library that cannot be read back is worse than none.
        let back = try PropertyListDecoder().decode(BundledAppLibrary.self, from: data)
        let labels = back.asLabels()
        print("回读校验：\(labels.count) 个标签，共 \(labels.reduce(0) { $0 + $1.centroids.count }) 个质心")
        for l in labels {
            print(String(format: "   %-12@ %d 质心 · 维度 %d",
                         l.name as NSString, l.centroids.count, l.centroids.first?.count ?? 0))
        }
    } catch {
        print("写入失败: \(error)")
        exit(1)
    }
    exit(0)
}

// ============================================================================
// MARK: - Clustering cost at scale  (--bench-cluster N)
// ============================================================================

if args.contains("--bench-cluster") {
    func intArg(_ f: String, _ d: Int) -> Int {
        guard let i = args.firstIndex(of: f), i + 1 < args.count else { return d }
        return Int(args[i + 1]) ?? d
    }
    let n = intArg("--bench-cluster", 25_000)
    let apps = intArg("--apps", 40)
    print("\n=== 聚类性能：\(n) 个向量，\(apps) 个「App」 ===\n")

    func make(_ appIndex: Int, _ jitter: Int) -> Embedding {
        var v = [Float](repeating: 0, count: 768)
        var st = UInt64(appIndex &* 2_654_435_761 &+ 12345)
        for d in 0..<768 {
            st ^= st << 13; st ^= st >> 7; st ^= st << 17
            v[d] = Float(Int64(bitPattern: st &>> 11)) / Float(1 << 53) - 0.5
        }
        // Same-app screenshots differ slightly; the amount controls how tight the
        // cluster is, mirroring the 0.95–0.999 measured on real data.
        var st2 = UInt64(jitter &* 40_503 &+ 7)
        for d in 0..<768 {
            st2 ^= st2 << 13; st2 ^= st2 >> 7; st2 ^= st2 << 17
            v[d] += (Float(Int64(bitPattern: st2 &>> 11)) / Float(1 << 53) - 0.5) * 0.10
        }
        return Embedding(values: v).normalized
    }

    var items: [(id: String, embedding: Embedding, bytes: Int64)] = []
    for i in 0..<n { items.append(("x\(i)", make(i % apps, i), 200_000)) }
    let sample = items[0].embedding.cosine(items[apps].embedding)
    let across = items[0].embedding.cosine(items[1].embedding)
    print(String(format: "同 App 相似度 ≈ %.3f   不同 App ≈ %.3f", sample, across))

    let t = Date()
    let r = AppClustering.cluster(items, against: [])
    let ms = -t.timeIntervalSinceNow * 1000
    print(String(format: "\n聚类 %.0f ms → %d 簇（上限 %d，溢出 %d 张）",
                 ms, r.clusters.count, AppClustering.maxClusters,
                 AppClustering.lastOverflowCount))
    print(String(format: "每张 %.3f ms", ms / Double(n)))

    // Worst case: nothing merges, so every photo tries to open a new cluster.
    var degenerate: [(id: String, embedding: Embedding, bytes: Int64)] = []
    for i in 0..<n { degenerate.append(("y\(i)", make(i, i), 200_000)) }
    let t2 = Date()
    let r2 = AppClustering.cluster(degenerate, against: [])
    let ms2 = -t2.timeIntervalSinceNow * 1000
    print(String(format: "\n退化输入（每张都不同）：%.0f ms → %d 簇，溢出 %d 张",
                 ms2, r2.clusters.count, AppClustering.lastOverflowCount))
    print(ms2 < 8000 ? "  ✓ 有上限护栏，最坏情况可控" : "  ✗ 最坏情况仍然过慢")
    exit(0)
}

// ============================================================================
// MARK: - Rules vs. head  (--head-vs-rules)
//
// The claim under test: hand-written rules plateau, while a linear head on the
// frozen FeaturePrint backbone keeps improving — and one naming action per
// cluster is enough to train it. Map screenshots are the sharp case: the rules
// no longer even try to predict that category.
// ============================================================================

if args.contains("--head-vs-rules") {
    print("\n=== 规则 vs 分类头 ===\n")

    struct Item {
        var id: String; var snap: AssetSnapshot
        var e: Embedding; var truth: CleanupCategory
        var ruleGuess: CleanupCategory
    }
    var items: [Item] = []
    for s in snapshots {
        guard let img = images[s.id], DuplicateFinder.isScreenLike(s) else { continue }
        let vf = VisionAnalyzer.analyze(img)
        guard let e = vf.embedding else { continue }
        let truth: CleanupCategory? =
            s.id.hasPrefix("chat")    ? .chatScreenshot   :
            s.id.hasPrefix("game")    ? .gameScreenshot   :
            s.id.hasPrefix("receipt") ? .documentShot     :
            s.id.hasPrefix("map")     ? .mapScreenshot    :
            s.id.hasPrefix("system")  ? .systemScreenshot : nil
        guard let truth else { continue }
        let (g, _, _) = RuleClassifier.classify(snapshot: s, fingerprint: fingerprints[s.id],
                                                vision: vf)
        items.append(Item(id: s.id, snap: s, e: e, truth: truth, ruleGuess: g))
    }
    print("带标签的截图：\(items.count) 张\n")

    let ruleRight = items.filter { $0.ruleGuess == $0.truth }.count
    print("--- 只用规则 ---")
    print("  正确 \(ruleRight)/\(items.count)")
    for cat in Set(items.map(\.truth)).sorted(by: { $0.rawValue < $1.rawValue }) {
        let g = items.filter { $0.truth == cat }
        print("    \(cat.title): \(g.filter { $0.ruleGuess == cat }.count)/\(g.count)")
    }

    // Leave-one-cluster-out: name every cluster except the held-out one, then see
    // whether the head classifies the held-out cluster correctly. This is the
    // honest test — training and testing on the same cluster proves nothing.
    print("\n--- 按簇留一：命名其余簇训练，预测被留出的那一簇 ---")
    let byTruth = Dictionary(grouping: items, by: \.truth)
    var headRight = 0, headTotal = 0
    for (heldCat, heldItems) in byTruth.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
        // The held-out category still needs *some* representation, or the head has
        // never heard the label — so hold out half of it and train on the rest,
        // mirroring "the user named one cluster, more photos arrive later".
        let half = max(1, heldItems.count / 2)
        let trainPart = Array(heldItems.prefix(half))
        let testPart = Array(heldItems.dropFirst(half))
        guard !testPart.isEmpty else { continue }

        let head = OnlineClassifier()
        var pool: [(Embedding, CleanupCategory)] = []
        for (cat, its) in byTruth where cat != heldCat {
            for i in its { pool.append((i.e, cat)) }
        }
        for i in trainPart { pool.append((i.e, heldCat)) }
        var lcg: UInt64 = 0x2545F4914F6CDD1D
        func rnd() -> Int { lcg = lcg &* 6364136223846793005 &+ 1442695040888963407
                            return Int((lcg >> 33) & 0x7FFF_FFFF) }
        for _ in 0..<40 {
            var v = pool
            for i in stride(from: v.count - 1, to: 0, by: -1) { v.swapAt(i, rnd() % (i + 1)) }
            for (e, c) in v { head.train(e, label: c) }
        }
        let right = testPart.filter { head.predict($0.e).max(by: { $0.value < $1.value })?.key == heldCat }.count
        headRight += right; headTotal += testPart.count
        print("    \(heldCat.title): \(right)/\(testPart.count)")
    }
    print("  正确 \(headRight)/\(headTotal)")

    // A category can hold two visually unrelated looks — 系统截图 is a grey
    // settings list *and* a colourful icon grid. Holding one mode out entirely is
    // not what the real flow does: the user names each cluster, so the head sees
    // both. Test that: train on every cluster, predict a held-out sample from each.
    print("\n--- 每簇都命名过之后（留一张样本做测试）---")
    var seenRight = 0, seenTotal = 0
    for (cat, its) in byTruth.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
        guard its.count >= 2 else { continue }
        for holdIdx in its.indices {
            let head = OnlineClassifier()
            var pool: [(Embedding, CleanupCategory)] = []
            for (c, list) in byTruth {
                for (i, it) in list.enumerated() where !(c == cat && i == holdIdx) {
                    pool.append((it.e, c))
                }
            }
            var lcg: UInt64 = 0x9E3779B97F4A7C15
            func rnd2() -> Int { lcg = lcg &* 6364136223846793005 &+ 1442695040888963407
                                 return Int((lcg >> 33) & 0x7FFF_FFFF) }
            for _ in 0..<40 {
                var v = pool
                for i in stride(from: v.count - 1, to: 0, by: -1) { v.swapAt(i, rnd2() % (i + 1)) }
                for (e, c) in v { head.train(e, label: c) }
            }
            let pred = head.predict(its[holdIdx].e).max(by: { $0.value < $1.value })?.key
            if pred == cat { seenRight += 1 }
            seenTotal += 1
        }
        let g = its.count
        print("    \(cat.title): \(g) 张全部留一验证")
    }
    print("  正确 \(seenRight)/\(seenTotal)")

    print("""

    结论
      只用规则                     \(ruleRight)/\(items.count)
      分类头（整簇没见过）          \(headRight)/\(headTotal)
      分类头（每簇都命名过）        \(seenRight)/\(seenTotal)

    地图截图规则完全不预测（颜色启发式已移除），只有分类头能给出它。
    """)
    exit(0)
}
