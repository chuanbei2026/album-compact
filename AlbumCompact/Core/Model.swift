import Foundation
import Photos

// MARK: - Asset snapshot

/// A `Sendable` value snapshot of a `PHAsset`. `PHAsset` itself is a live,
/// non-Sendable object, so every background stage works on snapshots and only
/// touches `PHAsset` again when it actually needs pixels.
struct AssetSnapshot: Hashable, Identifiable, Codable, Sendable {
    var id: String                 // PHAsset.localIdentifier
    var creationDate: Date
    var modificationDate: Date
    var pixelWidth: Int
    var pixelHeight: Int
    var byteSize: Int64
    var isFavorite: Bool
    var isHidden: Bool
    var hasLocation: Bool
    var isVideo: Bool
    var duration: Double
    var burstID: String?
    var subtypes: UInt
    var filename: String
    /// True when PhotoKit carries adjustment data for the asset — i.e. the user
    /// actually edited it. `modificationDate` is useless for this: PhotoKit bumps
    /// it on plain import, so it would flag an entire freshly synced library.
    var hasAdjustments: Bool = false

    var pixelCount: Int { pixelWidth * pixelHeight }
    var aspect: Double {
        pixelHeight == 0 ? 1 : Double(pixelWidth) / Double(pixelHeight)
    }
    var mediaSubtypes: PHAssetMediaSubtype { PHAssetMediaSubtype(rawValue: subtypes) }
    var isScreenshot: Bool { mediaSubtypes.contains(.photoScreenshot) }
    var isLivePhoto: Bool { mediaSubtypes.contains(.photoLive) }
    var isPanorama: Bool { mediaSubtypes.contains(.photoPanorama) }
    var isPortrait: Bool { mediaSubtypes.contains(.photoDepthEffect) }
    var isScreenRecording: Bool {
        guard isVideo else { return false }
        let f = filename.uppercased()
        return f.hasPrefix("RPREPLAY") || f.contains("SCREENRECORD") || f.contains("屏幕录制")
    }
}

// MARK: - Fingerprint

/// Everything we derive from a single cheap thumbnail decode. One row per asset,
/// cached on disk so a rescan is nearly free.
struct Fingerprint: Codable, Sendable, Hashable {
    var dHash: UInt64          // 64-bit difference hash  (structure)
    var pHash: UInt64          // 64-bit DCT hash         (low-frequency content)
    /// FNV-1a over the full 32x32 grayscale + 32x32 RGB buffers (~4 KB of
    /// signal). A 64-bit *perceptual* hash cannot justify the claim "these are
    /// the same pixels" — it deliberately throws detail away, and two different
    /// screenshots of the same app can collide on it. This does justify it, and
    /// it gates the only one-tap-destructive path in the app.
    var contentHash: UInt64 = 0
    var sharpness: Float       // Laplacian variance, 0…1-ish
    var saturation: Float      // mean HSV saturation 0…1
    var flatness: Float        // fraction of pixels in the top color buckets (UI-ness)
    var edgeDensity: Float     // fraction of strong-gradient pixels
    var brightness: Float      // mean luma 0…1
    var version: Int = Fingerprint.currentVersion

    static let currentVersion = 8
}

@inline(__always)
func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
    (a ^ b).nonzeroBitCount
}

// MARK: - Categories

enum CleanupCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case duplicate          // handled by its own screen, not the swipe deck
    case screenshot         // generic screenshot, no better guess
    case chatScreenshot     // messaging app capture
    case gameScreenshot     // game / app capture with rich graphics
    case documentShot       // receipt, ticket, QR, form — usually worth KEEPING
    case webShot            // article / web page / social feed capture
    case mapScreenshot      // Maps / navigation capture
    case systemScreenshot   // iOS itself: Settings, Home Screen, Control Center
    case other              // surfaced but doesn't fit anything above
    case screenRecording
    case blurry             // out-of-focus real photo
    case largeVideo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .duplicate:       return String(localized: "重复照片")
        case .screenshot:      return String(localized: "截图")
        case .chatScreenshot:  return String(localized: "聊天截图")
        case .gameScreenshot:  return String(localized: "游戏截图")
        case .documentShot:    return String(localized: "单据 / 证件")
        case .webShot:         return String(localized: "网页 / 社交截图")
        case .mapScreenshot:   return String(localized: "地图截图")
        case .systemScreenshot: return String(localized: "系统截图")
        case .other:           return String(localized: "其他")
        case .screenRecording: return String(localized: "录屏")
        case .blurry:          return String(localized: "模糊废片")
        case .largeVideo:      return String(localized: "大体积视频")
        }
    }

    var systemImage: String {
        switch self {
        case .duplicate:       return "square.on.square"
        case .screenshot:      return "iphone"
        case .chatScreenshot:  return "bubble.left.and.bubble.right"
        case .gameScreenshot:  return "gamecontroller"
        case .documentShot:    return "doc.text.viewfinder"
        case .webShot:         return "safari"
        case .mapScreenshot:   return "map"
        case .systemScreenshot: return "gearshape"
        case .other:           return "questionmark.square.dashed"
        case .screenRecording: return "record.circle"
        case .blurry:          return "camera.metering.unknown"
        case .largeVideo:      return "film"
        }
    }

    /// Categories where the default assumption is "you probably want this gone".
    var isDeletionCandidate: Bool {
        switch self {
        case .documentShot: return false
        default:            return true
        }
    }

    /// Categories the on-device classifier head can learn.
    static var learnable: [CleanupCategory] {
        // Everything the user can relabel a card to — and therefore everything
        // the on-device head can learn. `.other` matters here: without an
        // "it's none of these" option the user has nowhere to put a wrong guess,
        // and the model never hears about it.
        [.chatScreenshot, .gameScreenshot, .documentShot, .webShot,
         .mapScreenshot, .systemScreenshot, .screenshot, .other]
    }
}

// MARK: - Candidate

/// One card in the swipe deck.
struct Candidate: Identifiable, Hashable, Sendable {
    var snapshot: AssetSnapshot
    var category: CleanupCategory
    var confidence: Double        // 0…1, drives queue ordering
    var reasons: [String]         // human-readable "why is this here"

    var id: String { snapshot.id }
}

// MARK: - Duplicate group

/// Two genuinely different problems, deliberately not one gradient.
///
/// * `identical` / `copy` — **the same picture, stored more than once.** There is
///   nothing to choose; the extras are waste. Safe to clear in one tap.
/// * `moment` — **different pictures of the same scene.** A burst, or a few shots
///   taken seconds apart. These are not waste: one of them is the good one, and
///   only the user knows which. They get a screen built for choosing, never a
///   one-tap sweep.
///
/// Measured on real files, a true copy sits at Hamming distance ≤ 1 (dHash) and 0
/// (pHash). Loosening past that adds no real copies and does add false pairs — two
/// different receipts collide at d=0/p=2 — so the copy tiers stay tight and the
/// moment tier is decided by **metadata**, not by hash distance.
enum DuplicateTier: Int, Codable, Sendable, Comparable {
    case identical = 0      // same pixels, stored twice
    case copy      = 1      // re-encoded / resized copy of the same capture
    case moment    = 2      // same scene, different shots — pick one

    static func < (l: DuplicateTier, r: DuplicateTier) -> Bool { l.rawValue < r.rawValue }

    var title: String {
        switch self {
        case .identical: return "完全一致"
        case .copy:      return "同一张的副本"
        case .moment:    return "同一时刻多张"
        }
    }
    var blurb: String {
        switch self {
        case .identical: return String(localized: "内容哈希与尺寸完全相同 — 就是同一张图存了两遍")
        case .copy:      return String(localized: "同一次拍摄的重编码 / 缩放副本，画面一致")
        case .moment:    return String(localized: "连拍或几秒内的多张 — 需要你挑出留哪一张")
        }
    }
    /// Copies can be swept. A moment cannot: choosing is the whole task.
    var canOneTapClean: Bool { self != .moment }
    /// Does this group need the side-by-side picker instead of a list row?
    var needsPicking: Bool { self == .moment }
}

struct DuplicateGroup: Identifiable, Sendable {
    var id: String { members.first?.id ?? UUID().uuidString }
    var tier: DuplicateTier
    var members: [AssetSnapshot]     // sorted best-keeper first
    var keeperID: String
    var keeperReason: String

    var discardable: [AssetSnapshot] { members.filter { $0.id != keeperID } }
    var reclaimableBytes: Int64 { discardable.reduce(0) { $0 + $1.byteSize } }
}
