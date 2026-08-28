import Foundation
import Photos
import UIKit

/// Image loading for both the analysis pipeline and the UI.
///
/// Two rules make this fast and safe:
/// 1. `isNetworkAccessAllowed = false` — we never trigger an iCloud download.
///    Optimised-storage libraries keep a local preview, which is plenty for
///    hashing and for a full-screen card.
/// 2. Analysis reads are *synchronous* on a background queue, so we get exactly
///    one deterministic result per asset instead of the opportunistic
///    low-res-then-high-res double callback.
final class ThumbnailProvider {

    static let shared = ThumbnailProvider()

    private let manager = PHCachingImageManager()
    private let uiCache = NSCache<NSString, UIImage>()


    /// Injected once from the app's main-actor initialiser. `UIScreen` is
    /// main-actor isolated, so it must not be read from the caching helpers —
    /// those run on background queues during a scan. Writing it once at launch,
    /// before any background work exists, keeps the access safe without dragging
    /// the whole provider onto the main actor.
    nonisolated(unsafe) static var displayScale: CGFloat = 3

    private init() {
        manager.allowsCachingHighQualityImages = false
        uiCache.countLimit = 300
    }

    // MARK: analysis path

    /// Small thumbnail used for perceptual hashing. 96px is more than enough for
    /// a 32x32 DCT and keeps the decode cost near zero.
    func hashingImage(for asset: PHAsset) -> CGImage? {
        analysisImage(for: asset, maxPixel: 96)
    }

    /// Larger render used for OCR — text needs real pixels to be recognised.
    func analysisImage(for asset: PHAsset) -> CGImage? {
        analysisImage(for: asset, maxPixel: 1024)
    }

    /// Two independent paths, because neither is reliable alone:
    ///
    /// 1. `requestImage` is fast when PhotoKit already has a rendered derivative,
    ///    but returns nil when it doesn't and network access is disallowed — which
    ///    is exactly the state of a freshly imported library.
    /// 2. `requestImageDataAndOrientation` hands us the original bytes, which
    ///    `CGImageSourceCreateThumbnailAtIndex` downsamples during decode. Slower
    ///    per call, but it always works for a local asset and never blows up
    ///    memory on a 48MP original.
    private func analysisImage(for asset: PHAsset, maxPixel: Int) -> CGImage? {
        if let img = syncRendered(asset, side: CGFloat(maxPixel))?.cgImage { return img }
        return decodedFromData(asset, maxPixel: maxPixel)
    }

    private func syncRendered(_ asset: PHAsset, side: CGFloat) -> UIImage? {
        let opts = PHImageRequestOptions()
        opts.isSynchronous = true
        // With `isSynchronous`, PhotoKit ignores anything but highQualityFormat.
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = false
        var out: UIImage?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFit,
            options: opts) { img, _ in out = img }
        return out
    }

    private func decodedFromData(_ asset: PHAsset, maxPixel: Int) -> CGImage? {
        let opts = PHImageRequestOptions()
        opts.isSynchronous = true
        opts.isNetworkAccessAllowed = false
        opts.version = .current
        var data: Data?
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: opts) {
            d, _, _, _ in data = d
        }
        guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
    }

    // MARK: UI path

    /// One canonical options object for every display request. PHCachingImageManager
    /// matches a prefetch to a later request on (asset, targetSize, contentMode,
    /// options) — build them differently in two places and the prefetch silently
    /// never hits, which is exactly how a card ends up blank after a swipe.
    private static func displayOptions() -> PHImageRequestOptions {
        let o = PHImageRequestOptions()
        o.deliveryMode = .opportunistic
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = true      // UI may wait; analysis never does
        return o
    }

    private func targetSize(_ side: CGFloat) -> CGSize {
        let px = side * Self.displayScale
        return CGSize(width: px, height: px)
    }

    func cached(_ id: String, side: CGFloat) -> UIImage? {
        uiCache.object(forKey: key(id, side))
    }

    /// Progressive load: yields the fast degraded frame first, then the sharp one.
    ///
    /// The previous version returned a single value and resumed on whichever frame
    /// arrived first — so an asset that wasn't cached yet showed its low-resolution
    /// placeholder *and then never upgraded*. Every photo in the deck looked soft.
    /// A stream lets the view show something immediately and sharpen in place.
    func imageStream(for id: String, side: CGFloat) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            guard let asset = PhotoLibraryService.shared.asset(for: id) else {
                continuation.finish(); return
            }
            let cacheKey = key(id, side)
            let requestID = manager.requestImage(
                for: asset,
                targetSize: targetSize(side),
                contentMode: .aspectFit,
                options: Self.displayOptions()
            ) { [weak self] img, info in
                guard let img else {
                    if ((info?[PHImageResultIsDegradedKey] as? Bool) ?? false) == false {
                        continuation.finish()
                    }
                    return
                }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded { self?.uiCache.setObject(img, forKey: cacheKey) }
                continuation.yield(img)
                if !degraded { continuation.finish() }
            }
            continuation.onTermination = { @Sendable _ in
                PHImageManager.default().cancelImageRequest(requestID)
            }
        }
    }

    /// Warm the pipeline for the cards just ahead of the user in the deck.
    func startCaching(ids: [String], side: CGFloat) {
        let assets = PhotoLibraryService.shared.assets(for: ids)
        guard !assets.isEmpty else { return }
        manager.startCachingImages(for: assets, targetSize: targetSize(side),
                                   contentMode: .aspectFit,
                                   options: Self.displayOptions())
    }

    func stopCaching(ids: [String], side: CGFloat) {
        let assets = PhotoLibraryService.shared.assets(for: ids)
        guard !assets.isEmpty else { return }
        manager.stopCachingImages(for: assets, targetSize: targetSize(side),
                                  contentMode: .aspectFit,
                                  options: Self.displayOptions())
    }

    func stopAllCaching() { manager.stopCachingImagesForAllAssets() }

    private func key(_ id: String, _ side: CGFloat) -> NSString {
        "\(id)@\(Int(side))" as NSString
    }
}
