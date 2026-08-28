import Foundation
import Photos
import UIKit

enum LibraryAuthState: Equatable {
    case undetermined, denied, limited, authorized
}

/// Thin wrapper over PhotoKit: authorisation, enumeration, and byte accounting.
final class PhotoLibraryService {

    static let shared = PhotoLibraryService()
    private init() {}

    // MARK: authorisation

    var authState: LibraryAuthState { Self.currentState }

    /// Static so the authorization callback — a `@Sendable` closure — never has to
    /// capture the (non-Sendable) service instance.
    static var currentState: LibraryAuthState {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized:    return .authorized
        case .limited:       return .limited
        case .denied,
             .restricted:    return .denied
        case .notDetermined: return .undetermined
        @unknown default:    return .undetermined
        }
    }

    func requestAccess() async -> LibraryAuthState {
        await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
                cont.resume(returning: PhotoLibraryService.currentState)
            }
        }
    }

    // MARK: enumeration

    /// All assets, newest first. Cheap — PhotoKit fetch results are lazy.
    func fetchAllAssets() -> PHFetchResult<PHAsset> {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.includeHiddenAssets = false
        opts.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        return PHAsset.fetchAssets(with: opts)
    }

    func asset(for localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    func assets(for ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var out: [PHAsset] = []
        result.enumerateObjects { a, _, _ in out.append(a) }
        return out
    }

    /// Snapshot a fetch result into `Sendable` value types on a background queue.
    func snapshot(_ result: PHFetchResult<PHAsset>,
                  progress: ((Int, Int) -> Void)? = nil) -> [AssetSnapshot] {
        var out: [AssetSnapshot] = []
        out.reserveCapacity(result.count)
        let total = result.count
        result.enumerateObjects { asset, idx, _ in
            out.append(Self.makeSnapshot(asset))
            if idx % 500 == 0 { progress?(idx, total) }
        }
        return out
    }

    /// Snapshot an asset's metadata.
    ///
    /// `PHAssetResource.assetResources(for:)` costs roughly a millisecond per
    /// asset, and calling it for every photo made the metadata pass take **20.2 s
    /// on a real 12 930-photo library** — the very first thing the user waits on.
    /// It is only actually needed for two things:
    ///
    ///  * the original filename, which only matters for videos (screen-recording
    ///    detection), and there are two orders of magnitude fewer of those;
    ///  * the exact byte size, which is only shown for assets that end up in a
    ///    result — refined later by `refineSizes`, estimated until then.
    ///
    /// So the fast path skips it entirely for photos.
    static func makeSnapshot(_ a: PHAsset, fetchResources: Bool? = nil) -> AssetSnapshot {
        let wantResources = fetchResources ?? (a.mediaType == .video)
        let resources = wantResources ? PHAssetResource.assetResources(for: a) : []
        let name = resources.first?.originalFilename ?? ""
        return AssetSnapshot(
            id: a.localIdentifier,
            creationDate: a.creationDate ?? a.modificationDate ?? .distantPast,
            modificationDate: a.modificationDate ?? .distantPast,
            pixelWidth: a.pixelWidth,
            pixelHeight: a.pixelHeight,
            byteSize: wantResources ? byteSize(resources: resources, asset: a)
                                    : estimatedBytes(a),
            isFavorite: a.isFavorite,
            isHidden: a.isHidden,
            hasLocation: a.location != nil,
            isVideo: a.mediaType == .video,
            duration: a.duration,
            burstID: a.burstIdentifier,
            subtypes: a.mediaSubtypes.rawValue,
            filename: name,
            // Only report an edit when we actually looked. The tempting fallback —
            // "modificationDate is much later than creationDate" — is the exact
            // heuristic this project already rejected: PhotoKit bumps that date on
            // plain import, so it flagged 6 000 untouched photos as edited and
            // silently dropped them from the queue. Unknown must mean `false`
            // here: showing a photo the user then keeps costs one swipe, while
            // wrongly skipping it costs them the chance to clean it up at all.
            hasAdjustments: wantResources
                ? resources.contains { $0.type == .adjustmentData }
                : false
        )
    }

    /// PhotoKit has no public byte-size API. `PHAssetResource` exposes it via
    /// KVC on a documented-but-not-public key that has been stable for a decade;
    /// if it ever disappears we fall back to an estimate from dimensions so the
    /// UI never shows zero.
    static func byteSize(resources: [PHAssetResource], asset: PHAsset) -> Int64 {
        var total: Int64 = 0
        for r in resources {
            if let n = r.value(forKey: "fileSize") as? NSNumber {
                total += n.int64Value
            }
        }
        if total > 0 { return total }
        return estimatedBytes(asset)
    }

    static func estimatedBytes(_ a: PHAsset) -> Int64 {
        if a.mediaType == .video {
            // ~9 Mbit/s is a reasonable average for iPhone 1080p/4K mixed capture.
            return Int64(a.duration * 9_000_000 / 8)
        }
        // HEIC lands around 0.35 bytes per pixel in practice.
        return Int64(Double(a.pixelWidth * a.pixelHeight) * 0.35)
    }

    /// Replace estimated sizes with exact ones for a bounded set of assets — the
    /// ones about to be shown as deletable. Runs off the main thread; costs about
    /// a millisecond each, so the caller must keep the list short.
    func exactSizes(for ids: [String]) -> [String: Int64] {
        guard !ids.isEmpty else { return [:] }
        var out: [String: Int64] = [:]
        for asset in assets(for: ids) {
            let res = PHAssetResource.assetResources(for: asset)
            let size = Self.byteSize(resources: res, asset: asset)
            if size > 0 { out[asset.localIdentifier] = size }
        }
        return out
    }

    // MARK: album helpers

    /// Find or create the album we optionally park pending deletions in, so the
    /// user can see them from the stock Photos app too.
    func ensureAlbum(named title: String) async -> PHAssetCollection? {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title = %@", title)
        let existing = PHAssetCollection.fetchAssetCollections(with: .album,
                                                              subtype: .albumRegular,
                                                              options: opts)
        if let found = existing.firstObject { return found }

        var placeholder: PHObjectPlaceholder?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCollectionChangeRequest
                    .creationRequestForAssetCollection(withTitle: title)
                placeholder = req.placeholderForCreatedAssetCollection
            }
        } catch { return nil }

        guard let id = placeholder?.localIdentifier else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id],
                                                       options: nil).firstObject
    }
}
