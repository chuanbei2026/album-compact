import Foundation
import Photos

enum DeletionOutcome {
    case success(count: Int, bytes: Int64)
    case cancelled
    case failed(String)
}

/// Executes the actual removal.
///
/// Important truths this app must not hide from the user:
/// * PhotoKit *always* shows a system confirmation sheet — one sheet per batch,
///   never per photo. We cannot delete silently, and that's a good thing.
/// * Deleted assets land in the system "Recently Deleted" album for 30 days.
///   Storage is only reclaimed when that expires or the user empties it.
/// * A third-party app cannot wake itself up days later to delete something.
///   So the "delete after N days" feature is a local queue + a reminder
///   notification, not a background deletion. The UI says so plainly.
enum DeletionService {

    static func delete(ids: [String]) async -> DeletionOutcome {
        guard !ids.isEmpty else { return .success(count: 0, bytes: 0) }
        let assets = PhotoLibraryService.shared.assets(for: ids)
        guard !assets.isEmpty else { return .success(count: 0, bytes: 0) }

        let bytes = assets.reduce(Int64(0)) {
            $0 + PhotoLibraryService.makeSnapshot($1).byteSize
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
            return .success(count: assets.count, bytes: bytes)
        } catch {
            let ns = error as NSError
            // 3072 == user tapped Cancel on the system sheet.
            if ns.code == 3072 { return .cancelled }
            return .failed(ns.localizedDescription)
        }
    }

    /// Hide marked assets from the main library while they wait out the grace
    /// period. Fully reversible and does not touch the bytes.
    static func setHidden(_ hidden: Bool, ids: [String]) async -> Bool {
        let assets = PhotoLibraryService.shared.assets(for: ids)
        guard !assets.isEmpty else { return true }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for a in assets {
                    let r = PHAssetChangeRequest(for: a)
                    r.isHidden = hidden
                }
            }
            return true
        } catch { return false }
    }

    /// Park pending deletions in a visible album so the user can double-check
    /// them from the stock Photos app.
    static func addToStagingAlbum(ids: [String], albumTitle: String) async -> Bool {
        guard let album = await PhotoLibraryService.shared.ensureAlbum(named: albumTitle)
        else { return false }
        let assets = PhotoLibraryService.shared.assets(for: ids)
        guard !assets.isEmpty else { return true }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                guard let req = PHAssetCollectionChangeRequest(for: album) else { return }
                req.addAssets(assets as NSArray)
            }
            return true
        } catch { return false }
    }
}
