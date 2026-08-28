import Foundation

// MARK: - Pending deletion

struct PendingItem: Codable, Identifiable, Hashable, Sendable {
    var id: String                // localIdentifier
    var markedAt: Date
    var bytes: Int64
    var category: CleanupCategory
    var executeAfter: Date        // grace period expiry
}

// MARK: - History

/// One executed cleanup. Recorded per run rather than only as a running total,
/// because "am I making progress" is a question about a trend, and a single
/// accumulator cannot answer it.
struct DeletionEvent: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var date: Date
    var count: Int
    var bytes: Int64
    /// Freed bytes per category, keyed by `CleanupCategory.rawValue`.
    var bytesByCategory: [String: Int64]
    var countByCategory: [String: Int]

    var topCategory: CleanupCategory? {
        guard let key = bytesByCategory.max(by: { $0.value < $1.value })?.key else { return nil }
        return CleanupCategory(rawValue: key)
    }
}

/// A reading of how big the library is, taken at the end of each scan. This is
/// the series that actually answers the user's question — freed bytes is the
/// effort, library size is the outcome.
struct LibrarySnapshot: Codable, Identifiable, Hashable, Sendable {
    var id: Date { date }
    var date: Date
    var assetCount: Int
    var bytes: Int64
}

// MARK: - Settings

enum GracePeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case immediate, oneDay, oneWeek, oneMonth
    var id: String { rawValue }

    var title: String {
        switch self {
        case .immediate: return "立即执行"
        case .oneDay:    return "1 天后"
        case .oneWeek:   return "7 天后"
        case .oneMonth:  return "30 天后"
        }
    }
    var interval: TimeInterval {
        switch self {
        case .immediate: return 0
        case .oneDay:    return 86_400
        case .oneWeek:   return 7 * 86_400
        case .oneMonth:  return 30 * 86_400
        }
    }
}

struct ProtectionRules: Codable, Sendable, Equatable {
    var skipFavorites = true
    var skipWithLocation = false
    var skipRecentDays = 3          // never propose anything shot in the last N days
    var skipLivePhotos = false
    var skipEdited = true
    var skipDocuments = true        // keep receipts / tickets / QR codes out of the deck

    static let `default` = ProtectionRules()
}

struct AppSettings: Codable, Sendable, Equatable {
    var grace: GracePeriod = .oneWeek
    var rules = ProtectionRules.default
    var hideWhilePending = false
    var stageInAlbum = false
    var enableLearning = true
    var deckBatchSize = 60          // one "session" of cards, so the task feels finite
    var includeVideos = true
    var similarityStrictness: Double = 0.5   // 0 = loose (more groups), 1 = strict

    static let `default` = AppSettings()
}

// MARK: - Disk store

/// One binary-plist file per collection. The heavy one is the fingerprint cache
/// (~80 bytes/asset), which at 100k photos is ~8 MB and loads in well under a
/// second — no database engine required, and nothing to go wrong on migration.
final class Store {

    static let shared = Store()

    private let dir: URL
    private let queue = DispatchQueue(label: "store.io", qos: .utility)

    private(set) var fingerprints: [String: Fingerprint] = [:]
    private(set) var visionCache: [String: VisionFeatures] = [:]
    private(set) var pending: [String: PendingItem] = [:]
    private(set) var protectedIDs: Set<String> = []
    private(set) var settings: AppSettings = .default
    private(set) var classifier = OnlineClassifier()
    private(set) var deletability = DeletabilityModel()
    private(set) var lifetimeDeletedBytes: Int64 = 0
    private(set) var lifetimeDeletedCount: Int = 0
    private(set) var appLabels: [AppLabel] = []
    private(set) var history: [DeletionEvent] = []
    private(set) var librarySnapshots: [LibrarySnapshot] = []

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        dir = base.appendingPathComponent("AlbumCompact", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    private func url(_ name: String) -> URL { dir.appendingPathComponent("\(name).plist") }

    private func read<T: Decodable>(_ name: String, as: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? PropertyListDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, _ name: String) {
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        guard let data = try? enc.encode(value) else { return }
        let target = url(name)
        queue.async { try? data.write(to: target, options: .atomic) }
    }

    private func load() {
        if let fp = read("fingerprints", as: [String: Fingerprint].self) {
            // Drop rows written by an older hashing algorithm.
            fingerprints = fp.filter { $0.value.version == Fingerprint.currentVersion }
        }
        visionCache = (read("vision", as: [String: VisionFeatures].self) ?? [:])
            .filter { $0.value.version == VisionFeatures.currentVersion }
        if let p = read("pending", as: [PendingItem].self) {
            pending = Dictionary(uniqueKeysWithValues: p.map { ($0.id, $0) })
        }
        protectedIDs = Set(read("protected", as: [String].self) ?? [])
        settings = read("settings", as: AppSettings.self) ?? .default
        classifier = read("classifier", as: OnlineClassifier.self) ?? OnlineClassifier()
        deletability = read("deletability", as: DeletabilityModel.self) ?? DeletabilityModel()
        let stats = read("stats", as: [String: Int64].self) ?? [:]
        lifetimeDeletedBytes = stats["bytes"] ?? 0
        lifetimeDeletedCount = Int(stats["count"] ?? 0)
        // Centroids are only meaningful against the FeaturePrint revision they
        // were built with. If the OS moved, drop them rather than silently
        // computing nonsense similarities.
        appLabels = (read("appLabels", as: [AppLabel].self) ?? [])
            .filter { $0.revision == VisionAnalyzer.featurePrintRevision }
        history = (read("history", as: [DeletionEvent].self) ?? [])
            .sorted { $0.date < $1.date }
        librarySnapshots = (read("librarySnapshots", as: [LibrarySnapshot].self) ?? [])
            .sorted { $0.date < $1.date }
    }

    // MARK: mutations

    /// These two caches are rewritten wholesale, and at a real library size the
    /// vision cache is tens of megabytes (768 floats per screenshot). Writing it
    /// once per 24-photo batch — as the scan used to — means re-encoding the whole
    /// file hundreds of times, which was measured stalling for seconds.
    /// So merges are cheap and in-memory; the flush is coalesced.
    func mergeFingerprints(_ new: [String: Fingerprint]) {
        guard !new.isEmpty else { return }
        fingerprints.merge(new) { _, b in b }
        markDirty("fingerprints")
    }

    func mergeVision(_ new: [String: VisionFeatures]) {
        guard !new.isEmpty else { return }
        visionCache.merge(new) { _, b in b }
        markDirty("vision")
    }

    private var dirty = Set<String>()
    private let dirtyLock = NSLock()
    private var flushScheduled = false

    private func markDirty(_ name: String) {
        dirtyLock.lock()
        dirty.insert(name)
        let schedule = !flushScheduled
        if schedule { flushScheduled = true }
        dirtyLock.unlock()
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in self?.flushDirty() }
    }

    /// Write out whatever changed. Called on a timer, and explicitly when a scan
    /// ends or the app leaves the foreground.
    func flushDirty() {
        dirtyLock.lock()
        let names = dirty
        dirty.removeAll()
        flushScheduled = false
        dirtyLock.unlock()
        for n in names {
            switch n {
            case "fingerprints": write(fingerprints, "fingerprints")
            case "vision":       write(visionCache, "vision")
            default: break
            }
        }
    }

    /// Purge cache rows for assets that no longer exist in the library.
    func pruneCaches(livingIDs: Set<String>) {
        let beforeF = fingerprints.count
        fingerprints = fingerprints.filter { livingIDs.contains($0.key) }
        visionCache = visionCache.filter { livingIDs.contains($0.key) }
        pending = pending.filter { livingIDs.contains($0.key) }
        protectedIDs = protectedIDs.filter { livingIDs.contains($0) }
        if fingerprints.count != beforeF {
            write(fingerprints, "fingerprints")
            write(visionCache, "vision")
            savePending()
            write(Array(protectedIDs), "protected")
        }
    }

    func mark(_ snapshot: AssetSnapshot, category: CleanupCategory) {
        let after = Date().addingTimeInterval(settings.grace.interval)
        pending[snapshot.id] = PendingItem(id: snapshot.id, markedAt: Date(),
                                           bytes: snapshot.byteSize,
                                           category: category, executeAfter: after)
        savePending()
    }

    func unmark(_ id: String) {
        pending.removeValue(forKey: id)
        savePending()
    }

    func clearPending(ids: [String]) {
        for id in ids { pending.removeValue(forKey: id) }
        savePending()
    }

    func protectAsset(_ id: String) {
        protectedIDs.insert(id)
        pending.removeValue(forKey: id)
        write(Array(protectedIDs), "protected")
        savePending()
    }

    func unprotect(_ id: String) {
        protectedIDs.remove(id)
        write(Array(protectedIDs), "protected")
    }

    func update(settings newValue: AppSettings) {
        settings = newValue
        write(settings, "settings")
    }

    func learn(embedding: Embedding, label: CleanupCategory) {
        guard settings.enableLearning else { return }
        classifier.train(embedding, label: label)
        if classifier.sampleCount % 5 == 0 { write(classifier, "classifier") }
    }

    /// Called on every swipe: the decision itself is the training label.
    func learnDeletability(embedding: Embedding, willDelete: Bool) {
        guard settings.enableLearning else { return }
        deletability.train(embedding, willDelete: willDelete)
        if deletability.sampleCount % 5 == 0 { write(deletability, "deletability") }
    }

    func flushClassifier() {
        write(classifier, "classifier")
        write(deletability, "deletability")
    }

    func resetClassifier() {
        classifier.reset()
        deletability.reset()
        write(classifier, "classifier")
        write(deletability, "deletability")
    }

    /// Record an executed cleanup. Takes the pending rows rather than bare totals
    /// so the per-category breakdown survives — it is gone the moment the tray is
    /// cleared, and the dashboard needs it.
    func recordDeletion(items: [PendingItem], actualBytes: Int64? = nil) {
        guard !items.isEmpty else { return }
        var byBytes: [String: Int64] = [:]
        var byCount: [String: Int] = [:]
        for i in items {
            byBytes[i.category.rawValue, default: 0] += i.bytes
            byCount[i.category.rawValue, default: 0] += 1
        }
        let bytes = actualBytes ?? items.reduce(0) { $0 + $1.bytes }
        history.append(DeletionEvent(date: Date(), count: items.count, bytes: bytes,
                                     bytesByCategory: byBytes, countByCategory: byCount))
        lifetimeDeletedCount += items.count
        lifetimeDeletedBytes += bytes
        write(history, "history")
        write(["bytes": lifetimeDeletedBytes, "count": Int64(lifetimeDeletedCount)], "stats")
    }

    /// One reading per calendar day — a rescan five minutes later is the same fact,
    /// and an unbounded series would grow with every launch.
    func recordLibrarySnapshot(assetCount: Int, bytes: Int64) {
        guard assetCount > 0 else { return }
        #if DEBUG
        // A seeded demo library is 60+ GB; the simulator's real one is 44 MB.
        // Letting the real reading land on top of the seeded series would put a
        // cliff at the right edge that looks like a charting bug.
        if DebugLaunch.seedHistory { return }
        #endif
        let snap = LibrarySnapshot(date: Date(), assetCount: assetCount, bytes: bytes)
        let cal = Calendar.current
        if let last = librarySnapshots.last, cal.isDate(last.date, inSameDayAs: snap.date) {
            librarySnapshots[librarySnapshots.count - 1] = snap
        } else {
            librarySnapshots.append(snap)
        }
        if librarySnapshots.count > 400 {
            librarySnapshots.removeFirst(librarySnapshots.count - 400)
        }
        write(librarySnapshots, "librarySnapshots")
    }

    // MARK: app labels

    /// Seed from the bundled centroid library the first time the app runs. Only
    /// adds names the user does not already have, so it can never overwrite a
    /// label the user made or renamed.
    func seedFromBundledLibrary() {
        guard let lib = BundledAppLibrary.loadFromBundle() else { return }
        let existing = Set(appLabels.map(\.name))
        let fresh = lib.asLabels().filter { !existing.contains($0.name) }
        guard !fresh.isEmpty else { return }
        appLabels.append(contentsOf: fresh)
        write(appLabels, "appLabels")
        #if DEBUG
        NSLog("ALBUMCOMPACT 从内置质心库载入 %d 个 App", fresh.count)
        #endif
    }

    /// Name a cluster. If the name already exists, the cluster's centroid is
    /// appended to it — one app legitimately has several distinct screens, and
    /// averaging them into a single centroid would blur it into nothing.
    func nameCluster(_ cluster: AppCluster, as name: String,
                     category: CleanupCategory? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let i = appLabels.firstIndex(where: { $0.name == trimmed }) {
            appLabels[i].centroids.append(cluster.centroid)
            appLabels[i].sampleCount += cluster.memberIDs.count
            if appLabels[i].category == nil { appLabels[i].category = category }
        } else {
            appLabels.append(AppLabel(name: trimmed,
                                      centroids: [cluster.centroid],
                                      sampleCount: cluster.memberIDs.count,
                                      revision: cluster.revision,
                                      category: category))
        }
        write(appLabels, "appLabels")
    }

    func updateLabel(_ label: AppLabel) {
        guard let i = appLabels.firstIndex(where: { $0.id == label.id }) else { return }
        appLabels[i] = label
        write(appLabels, "appLabels")
    }

    func deleteLabel(_ id: UUID) {
        appLabels.removeAll { $0.id == id }
        write(appLabels, "appLabels")
    }

    func clearHistory() {
        history = []
        librarySnapshots = []
        lifetimeDeletedBytes = 0
        lifetimeDeletedCount = 0
        write(history, "history")
        write(librarySnapshots, "librarySnapshots")
        write(["bytes": Int64(0), "count": Int64(0)], "stats")
    }

    #if DEBUG
    /// The Simulator cannot produce FeaturePrint vectors, so app clustering can
    /// never run there. This fabricates labels from filename prefixes purely so
    /// the screens can be laid out and reviewed.
    func seedDemoAppLabels(from snapshots: [AssetSnapshot]) {
        guard appLabels.isEmpty else { return }
        let names = ["微信": "chat", "原神": "game", "支付宝": "receipt"]
        for (display, prefix) in names {
            let members = snapshots.filter { $0.filename.hasPrefix(prefix) }
            guard members.count >= 2 else { continue }
            appLabels.append(AppLabel(
                name: display,
                centroids: [[Float](repeating: 0, count: 768)],
                sampleCount: members.count,
                revision: VisionAnalyzer.featurePrintRevision,
                category: prefix == "chat" ? .chatScreenshot
                        : prefix == "game" ? .gameScreenshot : .documentShot,
                preferDelete: prefix != "receipt",
                preferKeep: prefix == "receipt"))
        }
        write(appLabels, "appLabels")
    }

    /// Seed plausible history so the dashboard can be checked without waiting
    /// weeks for real data to accumulate.
    func seedDemoHistory() {
        guard history.isEmpty else { return }
        let day: TimeInterval = 86_400
        let now = Date()
        var libBytes: Int64 = 78_000_000_000
        var libCount = 41_800
        var snaps: [LibrarySnapshot] = []
        var events: [DeletionEvent] = []

        // 16 weeks of readings, with a cleanup on roughly every third one.
        for w in stride(from: 112, through: 0, by: -4) {
            let d = now.addingTimeInterval(-Double(w) * day)
            libBytes += Int64(360_000_000 + (w % 5) * 90_000_000)   // photos keep arriving
            libCount += 190 + (w % 7) * 22
            if w % 12 == 4 || w == 0 {
                let mix: [(CleanupCategory, Int64, Int)] = [
                    (.duplicate,      Int64(1_150_000_000 + w * 7_000_000), 210 + w),
                    (.chatScreenshot, Int64(430_000_000 + w * 3_000_000),   380 + w * 2),
                    (.gameScreenshot, Int64(280_000_000 + w * 2_000_000),   120 + w),
                    (.screenshot,     Int64(160_000_000),                    90),
                    (.blurry,         Int64(95_000_000),                     34)
                ]
                let bytes = mix.reduce(Int64(0)) { $0 + $1.1 }
                let cnt = mix.reduce(0) { $0 + $1.2 }
                events.append(DeletionEvent(
                    date: d, count: cnt, bytes: bytes,
                    bytesByCategory: Dictionary(uniqueKeysWithValues: mix.map { ($0.0.rawValue, $0.1) }),
                    countByCategory: Dictionary(uniqueKeysWithValues: mix.map { ($0.0.rawValue, $0.2) })))
                libBytes -= bytes
                libCount -= cnt
            }
            snaps.append(LibrarySnapshot(date: d, assetCount: libCount, bytes: libBytes))
        }
        history = events.sorted { $0.date < $1.date }
        librarySnapshots = snaps
        lifetimeDeletedBytes = events.reduce(0) { $0 + $1.bytes }
        lifetimeDeletedCount = events.reduce(0) { $0 + $1.count }
        write(history, "history")
        write(librarySnapshots, "librarySnapshots")
        write(["bytes": lifetimeDeletedBytes, "count": Int64(lifetimeDeletedCount)], "stats")
    }
    #endif

    private func savePending() { write(Array(pending.values), "pending") }

    var pendingBytes: Int64 { pending.values.reduce(0) { $0 + $1.bytes } }

    var duePending: [PendingItem] {
        let now = Date()
        return pending.values.filter { $0.executeAfter <= now }
                             .sorted { $0.markedAt < $1.markedAt }
    }
}
