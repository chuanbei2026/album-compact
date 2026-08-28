import Foundation
import Photos

#if DEBUG
/// Answers one factual question: does PhotoKit record which app a screenshot came
/// from? Rather than guessing, this enumerates every Objective-C property on
/// `PHAsset` (public and private) plus the asset's resources and EXIF, and prints
/// anything whose name or value looks app-related.
///
/// Run with `-dumpAssetMeta`. DEBUG only — it touches private API surface purely
/// to find out what exists, and nothing in the shipping app depends on it.
enum AssetMetadataProbe {

    static func run(limit: Int = 4) {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let all = PHAsset.fetchAssets(with: opts)

        NSLog("PROBE ===== PHAsset 属性全表 =====")
        dumpProperties(of: PHAsset.self)

        var shown = 0
        all.enumerateObjects { asset, _, stop in
            guard shown < limit else { stop.pointee = true; return }
            shown += 1
            let res = PHAssetResource.assetResources(for: asset)
            NSLog("PROBE ----- asset #%d  %@  screenshot=%@ -----",
                  shown, res.first?.originalFilename ?? "?",
                  asset.mediaSubtypes.contains(.photoScreenshot) ? "Y" : "N")
            probeKeys(on: asset)
            for r in res {
                NSLog("PROBE   resource type=%ld uti=%@ name=%@",
                      r.type.rawValue, r.uniformTypeIdentifier, r.originalFilename)
                probeKeys(on: r, keys: ["assetLocalIdentifier", "cloudPlaceholderKind",
                                        "originalFilename", "fileSize", "privateFileURL"])
            }
        }
        NSLog("PROBE ===== 结束 =====")
    }

    /// Every Obj-C declared property on the class and its superclasses.
    private static func dumpProperties(of cls: AnyClass) {
        var current: AnyClass? = cls
        while let c = current, c != NSObject.self {
            var count: UInt32 = 0
            if let list = class_copyPropertyList(c, &count) {
                var names: [String] = []
                for i in 0..<Int(count) {
                    names.append(String(cString: property_getName(list[i])))
                }
                free(list)
                let sorted = names.sorted()
                // Log-line truncation would hide exactly the names we are looking
                // for, so emit in small chunks.
                for chunk in stride(from: 0, to: sorted.count, by: 10) {
                    let part = sorted[chunk..<min(chunk + 10, sorted.count)]
                    NSLog("PROBE ALL %@", part.joined(separator: ", "))
                }
                // And call out anything that could name an originating app.
                let needles = ["bundle", "app", "source", "import", "creator", "origin",
                               "syndicat", "saved", "share", "provenance", "agent"]
                let hits = sorted.filter { n in
                    let l = n.lowercased()
                    return needles.contains { l.contains($0) }
                }
                if !hits.isEmpty {
                    NSLog("PROBE HIT %@", hits.joined(separator: ", "))
                }
            }
            current = class_getSuperclass(c)
        }
    }

    /// Candidate keys for "where did this asset come from". Anything that answers
    /// the question would have to look like one of these.
    private static let candidateKeys = [
        // "which app did this come from"
        "syndicatedAppDisplayName", "isSyndicatedAssetSavedToUserLibrary",
        "syndicationState", "syndicationEligibility",
        "sourceType", "savedAssetType", "creationDateSource",
        // Apple's own stored analysis — if this is readable it is free semantics
        "allSceneClassifications", "curationScore", "contentType",
        "avalancheKind", "avalanchePickType", "playbackStyle",
        "uniformTypeIdentifier", "originalColorSpace", "mediaSubtypes",
        "adjustmentFormatIdentifier", "customUserTitle"
    ]

    private static func probeKeys(on object: NSObject, keys: [String]? = nil) {
        for key in keys ?? candidateKeys {
            guard object.responds(to: NSSelectorFromString(key)) else { continue }
            let v = (try? valueSafely(object, key)) ?? nil
            var desc = String(describing: v ?? "nil")
            if desc.count > 320 { desc = String(desc.prefix(320)) + "…" }
            NSLog("PROBE   %@ = %@", key, desc)
        }
    }

    private static func valueSafely(_ o: NSObject, _ k: String) throws -> Any? {
        o.value(forKey: k)
    }
}
#endif
