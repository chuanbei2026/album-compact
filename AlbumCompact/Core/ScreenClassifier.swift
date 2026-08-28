import Foundation

/// Scores for each learnable category, 0…1, summing to roughly 1.
typealias CategoryScores = [CleanupCategory: Double]

/// Cold-start classifier. Pure hand-written rules over free metadata + OCR
/// layout + colour statistics. No model, no training data, works on install.
///
/// Its job is to be *good enough to bootstrap*: whatever it gets wrong, the user
/// corrects with a swipe, and `OnlineClassifier` learns from that correction.
enum RuleClassifier {

    static func classify(snapshot: AssetSnapshot,
                         fingerprint: Fingerprint?,
                         vision: VisionFeatures?) -> (CleanupCategory, Double, [String]) {

        var reasons: [String] = []

        if snapshot.isScreenRecording {
            return (.screenRecording, 0.95, ["录屏文件"])
        }
        if snapshot.isVideo {
            return (.largeVideo, 0.5, ["视频"])
        }

        // Out-of-focus check comes first. A soft, low-detail frame is a bad photo
        // no matter what its pixel dimensions happen to be — and several classic
        // screenshot resolutions (2048x1536, 1080x1920) are also ordinary export
        // sizes, so letting the aspect-ratio guess run first mislabels blur as
        // a game capture.
        if !snapshot.isScreenshot, let fp = fingerprint,
           fp.sharpness < 0.16, fp.edgeDensity < 0.12 {
            return (.blurry, 0.55 + Double(0.16 - fp.sharpness), ["对焦模糊、细节很少"])
        }

        // The PhotoKit flag is authoritative. The resolution fallback exists for
        // screenshots that lost the flag (AirDropped, re-saved, exported), but on
        // its own it produces false positives, so it needs corroborating UI
        // evidence: flat blocks of colour, or actual on-screen text.
        var looksLikeScreen = snapshot.isScreenshot
        if looksLikeScreen {
            reasons.append(String(localized: "系统标记为截图"))
        } else {
            switch deviceResolutionMatch(snapshot) {
            case .phone:
                // A ~2.16:1 pixel ratio is not something a camera produces. The
                // dimensions alone are conclusive here, and they have to be —
                // a game capture has neither flat UI blocks nor readable text,
                // so demanding corroboration would simply lose that category.
                looksLikeScreen = true
                reasons.append(String(localized: "尺寸正好是手机屏幕分辨率"))
            case .ambiguous:
                // 4:3 and 16:9 are classic iPad / legacy screenshot sizes but also
                // completely ordinary photo and export sizes, so these need a
                // second signal before we treat them as a capture.
                let flatUI = (fingerprint?.flatness ?? 0) > 0.35
                let hasText = (vision?.layout.lineCount ?? 0) >= 4
                           && (vision?.layout.textAreaFraction ?? 0) > 0.015
                       || (vision?.layout.hasStatusBarClock ?? false)
                if flatUI || hasText {
                    looksLikeScreen = true
                    reasons.append(String(localized: "尺寸与屏幕一致，且画面带界面元素"))
                }
            case .none:
                // No resolution match at all. This is where cropped screenshots
                // and images re-saved by messaging apps land — a real library is
                // full of them at sizes like 924×1126 or 779×308, and every one
                // was being dropped.
                //
                // The evidence that separates them from a *photograph of* a
                // document is size: a phone camera shoots 12–24 MP, while a
                // cropped or re-compressed screenshot is a fraction of that. So
                // require small dimensions on top of the text and flatness that
                // say "this is a user interface".
                let smallEnoughToBeACapture = snapshot.pixelCount < 4_000_000
                let textHeavy = (vision?.layout.lineCount ?? 0) >= 8
                             && (vision?.layout.textAreaFraction ?? 0) > 0.04
                let flatUI = (fingerprint?.flatness ?? 0) > 0.40
                if smallEnoughToBeACapture, textHeavy, flatUI, !snapshot.hasLocation {
                    looksLikeScreen = true
                    reasons.append(String(localized: "尺寸不像相机、文字密集且画面平坦 — 可能是裁剪过的截图"))
                }
            }
        }
        guard looksLikeScreen else { return (.screenshot, 0.0, []) }

        guard let v = vision else {
            return (.screenshot, 0.45, reasons)
        }
        let L = v.layout
        let fp = fingerprint

        var scores: CategoryScores = [
            .chatScreenshot: 0, .gameScreenshot: 0,
            .documentShot: 0, .webShot: 0, .mapScreenshot: 0,
            .systemScreenshot: 0, .screenshot: 0.20
        ]

        // ---- chat ----
        // Many short lines, alternating left/right, a nav bar on top and an
        // input field at the bottom, flat low-saturation UI.
        var chat = 0.0
        // A chat bubble layout needs BOTH of two things, so they multiply rather
        // than add:
        //   * text present on both the left and the right (alignmentBimodality)
        //   * one of those sides flush against the right margin (rightHugging)
        //
        // Bimodality alone is not evidence of a conversation. Map labels sit at
        // arbitrary x positions and scored 0.69 on it — enough to beat the map
        // category on its own screenshots. Outgoing bubbles hugging the right
        // edge is the property maps and receipts do not have.
        //
        // And a left/right split only means bubbles if the rows are NOT paired,
        // or a two-column form (order details, a receipt) reads as a chat.
        let notTabular = Double(1 - min(1, L.pairedRowFraction * 1.5))
        let flushRight = Double(min(1, L.rightHuggingFraction * 2.5))
        chat += Double(L.alignmentBimodality) * flushRight * 1.9 * notTabular
        // A small residual so a chat whose outgoing messages are all short still
        // registers, without letting bimodality carry the verdict by itself.
        chat += Double(L.alignmentBimodality) * 0.25 * notTabular
        if L.hasStatusBarClock { chat += 0.22 }
        chat += Double(L.shortLineFraction) * 0.5
        if L.lineCount >= 8 { chat += 0.35 }
        if L.hasTopBar && L.hasBottomBar { chat += 0.45; reasons.append(String(localized: "顶栏 + 底部输入框")) }
        if let f = fp {
            if f.flatness > 0.55 { chat += 0.35 }
            if f.saturation < 0.22 { chat += 0.25 }
        }
        if L.alignmentBimodality > 0.45 && notTabular > 0.6 {
            reasons.append(String(localized: "左右交替的气泡排版"))
        }
        scores[.chatScreenshot] = chat

        // ---- game ----
        // Rich colour, high edge density, landscape, very little text.
        var game = 0.0
        if let f = fp {
            game += Double(f.saturation) * 1.3
            game += Double(f.edgeDensity) * 0.9
            if f.flatness < 0.28 { game += 0.4 }
        }
        // The status bar is the cleanest divider available. A game runs full
        // screen with the clock hidden; every ordinary app screenshot keeps it.
        if L.hasStatusBarClock {
            game -= 0.85
            reasons.append(String(localized: "左上角有系统时钟 — 是 App 界面而非全屏游戏"))
        } else if snapshot.aspect > 1.2 {
            game += 0.35
            reasons.append(String(localized: "横屏且没有状态栏 — 像全屏游戏"))
        }
        if L.textAreaFraction < 0.03 && (fp?.edgeDensity ?? 0) > 0.25 {
            game += 0.5; reasons.append(String(localized: "画面复杂、几乎没有文字"))
        } else if L.textAreaFraction < 0.06 {
            game += 0.2
        }
        if snapshot.aspect > 1.2 { game += 0.45; reasons.append(String(localized: "横屏截图")) }
        if v.labels.contains(where: { gameishLabels.contains($0) }) { game += 0.3 }
        scores[.gameScreenshot] = game

        // ---- document / receipt / ticket ----
        var doc = 0.0
        // Only trust the digit ratio once there is enough text for it to mean
        // something; two digits out of four characters is noise, not a receipt.
        let digitsTrustworthy = L.lineCount >= 6 && L.textAreaFraction > 0.012
        if digitsTrustworthy { doc += Double(L.digitFraction) * 1.5 }
        // A real document is dense with text. A Settings page is regular but
        // *sparse* — it shares brightness, flatness and row regularity with a
        // receipt, and text density is what actually separates them (measured:
        // Settings 4.3% of the frame, a receipt 8.3%+).
        let textDense = L.textAreaFraction > 0.06
        if textDense { doc += Double(L.gapRegularity) * 0.6 }
        doc += Double(L.pairedRowFraction) * 1.1
        if L.textAreaFraction > 0.06 && notTabular < 0.5 { doc += 0.5 }
        // "Bright and unsaturated" describes every white interface, so it only
        // counts alongside the digits that make something a receipt or a ticket.
        if let f = fp, f.brightness > 0.75, f.saturation < 0.15,
           L.digitFraction > 0.15 { doc += 0.4 }
        if v.labels.contains(where: { docishLabels.contains($0) }) { doc += 0.45 }
        if L.hasStatusBarClock { doc += 0.18 }
        if digitsTrustworthy && L.digitFraction > 0.22 {
            reasons.append(String(localized: "数字密集，可能是单据/票据"))
        }
        if L.pairedRowFraction > 0.4 { reasons.append(String(localized: "「字段 + 数值」的两栏排版")) }
        scores[.documentShot] = doc

        // ---- web / social feed ----
        var web = 0.0
        if L.lineCount >= 12 && L.shortLineFraction < 0.5 { web += 0.7 }
        if L.textAreaFraction > 0.14 && L.alignmentBimodality < 0.25 { web += 0.5 }
        if L.hasTopBar && !L.hasBottomBar { web += 0.25 }
        if let f = fp, f.flatness > 0.5, f.saturation < 0.3 { web += 0.2 }
        scores[.webShot] = web

        // ---- map ----
        //
        // There is no hand-written rule here, on purpose.
        //
        // Three successive attempts were tried and each failed on real data: a
        // "pale road base" matched every white interface; requiring muted blue
        // matched a Home Screen wallpaper; requiring green as well still left
        // Settings pages and receipts trading places. Colour statistics simply do
        // not answer "is this a map" — the question is about what an app looks
        // like, and that is exactly what the FeaturePrint backbone encodes.
        //
        // So 地图截图 is a **head-only category**: the learned classifier predicts
        // it once it has seen a labelled cluster, and until then the app says so
        // rather than guessing from pixels.

        // ---- iOS itself: Settings, Home Screen, Control Centre ----
        //
        // Two very different looks, one category. The status bar has to be there
        // (this is the system UI, it never hides it), and then either:
        //   * one column of evenly spaced rows, flat and grey  → Settings-like
        //   * a regular grid of short labels over a wallpaper  → Home Screen
        var system = 0.0
        if L.hasStatusBarClock {
            let singleColumn = L.textColumnCount <= 1
            let gridOfLabels = L.textColumnCount >= 3 && L.columnsEvenlySpaced
            if singleColumn, L.gapRegularity > 0.55, L.lineCount >= 6 {
                system += 0.85
                // Regular rows *and* sparse text is the Settings signature.
                if L.textAreaFraction < 0.06 { system += 0.35 }
                if let f = fp, f.flatness > 0.55, f.saturation < 0.18 { system += 0.45 }
                if L.pairedRowFraction < 0.25 { system += 0.20 }
                reasons.append(String(localized: "单列等距的设置行 + 系统状态栏"))
            }
            if gridOfLabels, L.shortLineFraction > 0.7 {
                system += 1.05
                // Several labels sharing a baseline *is* a grid row.
                if L.pairedRowFraction > 0.5 { system += 0.40 }
                reasons.append(String(localized: "图标标签排成规则网格 — 像主屏幕"))
            }
        }
        scores[.systemScreenshot] = system

        let best = scores.max { $0.value < $1.value }!
        // Confidence as the margin over the runner-up, not the share of the total.
        // A share shrinks every time a category is added — adding 「地图截图」 dropped
        // every other confidence by a third without anything actually becoming
        // less certain. The margin is what "把握" should mean, and it is stable.
        let runnerUp = scores.filter { $0.key != best.key }.values.max() ?? 0
        let denom = best.value + runnerUp
        let confidence = denom <= 0 ? 0.4 : min(0.97, best.value / denom)

        // Below this we don't pretend to know — just call it a screenshot.
        if best.value < 0.55 {
            return (.screenshot, 0.5, reasons)
        }
        return (best.key, max(0.4, confidence), reasons)
    }

    private enum ResolutionMatch { case phone, ambiguous, none }

    /// Screenshots keep the screen's exact pixel dimensions. A screenshot that
    /// was AirDropped or re-saved loses the PhotoKit subtype flag but keeps its
    /// resolution, so this is the fallback — split by how trustworthy the match is.
    private static func deviceResolutionMatch(_ s: AssetSnapshot) -> ResolutionMatch {
        let w = min(s.pixelWidth, s.pixelHeight)
        let h = max(s.pixelWidth, s.pixelHeight)
        guard w > 0 else { return .none }
        if phoneScreens.contains(where: { min($0.0, $0.1) == w && max($0.0, $0.1) == h }) {
            return .phone
        }
        if ambiguousScreens.contains(where: { min($0.0, $0.1) == w && max($0.0, $0.1) == h }) {
            return .ambiguous
        }
        return .none
    }

    /// Tall ratios no camera sensor produces (≈19.5:9 and 16:9-on-phone).
    ///
    /// The last two rows came from a real 12 930-photo library: 1260×2736 (iPhone
    /// Air) accounted for 83 screenshots and was missing here. A hard-coded table
    /// always lags new hardware, which is why the OCR fallback below matters more
    /// than the table does.
    private static let phoneScreens: [(Int, Int)] = [
        (1179, 2556), (1290, 2796), (1206, 2622), (1320, 2868),   // 15 / 16 / 17 family
        (1170, 2532), (1284, 2778), (1125, 2436), (1242, 2688),   // 11 – 14
        (828, 1792), (1242, 2208), (750, 1334), (640, 1136),
        (1260, 2736), (1206, 2622), (1290, 2796)                  // iPhone Air / 16 / 17
    ]

    /// 4:3 and 16:9 — real iPad / legacy screenshot sizes, but also perfectly
    /// ordinary photo and export dimensions, so they only count with corroboration.
    private static let ambiguousScreens: [(Int, Int)] = [
        (1620, 2160), (1668, 2388), (2048, 2732), (1536, 2048),
        (1640, 2360), (1488, 2266), (2064, 2752), (1024, 1366),
        (1080, 1920), (1440, 2560),
        (1668, 2420), (1668, 2388), (1032, 1376)                  // iPad Pro / Air M-series
    ]

    private static let gameishLabels: Set<String> = [
        "video_game", "toy", "cartoon", "animation", "illustration",
        "fantasy", "sword", "armor", "car_racing", "spacecraft"
    ]
    private static let docishLabels: Set<String> = [
        "document", "text", "paper", "receipt", "menu", "ticket",
        "book_jacket", "envelope", "business_card", "barcode", "qr_code"
    ]
}
