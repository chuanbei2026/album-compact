// Synthetic demo library for App Store screenshots.
//
// Store screenshots must never contain the owner's real photos — those images
// become public. This draws a library from scratch that exercises every detector
// the app has: exact copies, quality variants, bursts, and the screenshot
// categories.
//
// Everything is procedural and brand-free. Nothing here imitates a real app,
// service, or document: the "chat" and "map" scenes are generic layouts whose
// only job is to produce the text geometry the classifier reads.
//
// EXIF DateTimeOriginal is written deliberately. Moment grouping is indexed by
// time (a 10-second window), not by hash — real burst frames sit at dHash 11 /
// pHash 20, well beyond what the hash index can recall — so without timestamps
// the burst screen would be empty.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: deterministic randomness

/// Seeded so a regenerated library produces the same screenshots.
struct Rng {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        return state &* 2685821657736338717
    }
    mutating func d() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func d(_ lo: Double, _ hi: Double) -> Double { lo + d() * (hi - lo) }
    mutating func i(_ lo: Int, _ hi: Int) -> Int { lo + Int(d() * Double(hi - lo + 1)) }
}

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSString(string: "~/Desktop/album-sweeper-demo-media").expandingTildeInPath
try? FileManager.default.createDirectory(atPath: outDir,
                                         withIntermediateDirectories: true)

// MARK: drawing helpers

func context(_ w: Int, _ h: Int) -> CGContext {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                     bytesPerRow: 0, space: cs,
                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
}

extension CGContext {
    func fill(_ r: CGRect, _ c: (Double, Double, Double), _ a: Double = 1) {
        setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: a))
        fill(r)
    }
    func circle(_ x: Double, _ y: Double, _ rad: Double,
                _ c: (Double, Double, Double), _ a: Double = 1) {
        setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: a))
        fillEllipse(in: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2))
    }
    func roundRect(_ r: CGRect, _ radius: Double,
                   _ c: (Double, Double, Double), _ a: Double = 1) {
        let p = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius,
                       transform: nil)
        setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: a))
        addPath(p); fillPath()
    }
    /// Real glyphs, not grey bars — the chat and document classifiers read text
    /// geometry out of OCR, so painted rectangles would teach them nothing.
    func text(_ s: String, _ x: Double, _ y: Double, size: Double,
              _ c: (Double, Double, Double), font: String = "PingFangSC-Regular") {
        let f = CTFontCreateWithName(font as CFString, size, nil)
        let color = CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        let attr = NSAttributedString(string: s, attributes: [
            .init(kCTFontAttributeName as String): f,
            .init(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, self)
    }
    func textWidth(_ s: String, size: Double, font: String = "PingFangSC-Regular") -> Double {
        let f = CTFontCreateWithName(font as CFString, size, nil)
        let attr = NSAttributedString(string: s,
                                      attributes: [.init(kCTFontAttributeName as String): f])
        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr),
                                          nil, nil, nil)
    }
    /// Fine grain so JPEG cannot compress a synthetic image down to nothing —
    /// the home screen shows real byte counts, and flat gradients would make
    /// the recoverable figure absurdly small.
    func grain(_ w: Int, _ h: Int, _ rng: inout Rng, amount: Double = 0.05) {
        let step = 4
        for y in stride(from: 0, to: h, by: step) {
            for x in stride(from: 0, to: w, by: step) {
                let v = rng.d(-amount, amount)
                setFillColor(CGColor(srgbRed: 0.5 + v, green: 0.5 + v, blue: 0.5 + v,
                                     alpha: 0.14))
                fill(CGRect(x: Double(x), y: Double(y),
                            width: Double(step), height: Double(step)))
            }
        }
    }
}


/// The coarse structure that makes two photos distinguishable.
///
/// Without this every scene collapsed: dHash is a 9×8 grid, and procedural
/// gradients look identical once reduced to 72 cells, so 22 unrelated images
/// landed in one group at distance 0. Large seed-placed regions perturb exactly
/// the frequencies the hash reads. `shift` translates them, which is what makes
/// a burst sit beyond the copy thresholds (dHash ≤ 2) but inside the moment
/// ones (dHash ≤ 12) — the same span real burst frames occupy.
func bigStructure(_ c: CGContext, _ w: Int, _ h: Int,
                  _ rng: inout Rng, shift: Double) {
    let W = Double(w), H = Double(h)
    let n = rng.i(4, 6)
    for _ in 0..<n {
        let cx = rng.d(-0.1, 1.1) * W + shift * W * 0.035
        let cy = rng.d(-0.1, 1.1) * H + shift * H * 0.020
        let rad = rng.d(0.14, 0.40) * min(W, H)
        let bright = rng.d() > 0.5
        let v = rng.d(0.55, 0.95)
        // soft edge, so it reads as depth rather than as a pasted circle
        for ring in stride(from: 6, through: 1, by: -1) {
            let f = Double(ring) / 6
            c.circle(cx, cy, rad * f,
                     bright ? (v, v * 0.96, v * 0.88) : (v * 0.22, v * 0.24, v * 0.30),
                     0.10)
        }
    }
    // one dominant band, orientation chosen by seed
    let horizontal = rng.d() > 0.5
    let p = rng.d(0.15, 0.85)
    let thick = rng.d(0.10, 0.26)
    let v = rng.d(0.2, 0.9)
    c.fill(horizontal
           ? CGRect(x: 0, y: (p + shift * 0.012) * H, width: W, height: thick * H)
           : CGRect(x: (p + shift * 0.012) * W, y: 0, width: thick * W, height: H),
           (v, v * 0.9, v * 0.82), 0.16)
}

// MARK: scenes — ordinary photos, the ones a user keeps

func landscape(_ w: Int, _ h: Int, seed: UInt64, shift: Double = 0) -> CGImage {
    var rng = Rng(seed)
    let c = context(w, h), W = Double(w), H = Double(h)
    let hue = rng.d(0, 1)
    for i in 0..<90 {                                    // sky gradient
        let t = Double(i) / 90
        c.fill(CGRect(x: 0, y: H * (1 - t) - H / 90, width: W, height: H / 90 + 2),
               (0.30 + 0.55 * t * (0.6 + hue * 0.4), 0.45 + 0.42 * t, 0.72 + 0.24 * t))
    }
    c.circle(W * (0.24 + shift * 0.03), H * 0.78, W * 0.075, (1.0, 0.95, 0.78))
    for layer in 0..<3 {                                 // ridges
        let base = H * (0.28 - Double(layer) * 0.06)
        let dark = 0.34 - Double(layer) * 0.09
        c.beginPath()
        c.move(to: CGPoint(x: 0, y: 0))
        var x = 0.0
        while x <= W {
            let peak = base + sin(x / W * (5 + Double(layer) * 4) + Double(layer) + shift * 0.2)
                * H * (0.05 + 0.02 * Double(layer))
            c.addLine(to: CGPoint(x: x, y: peak)); x += W / 60
        }
        c.addLine(to: CGPoint(x: W, y: 0)); c.closePath()
        c.setFillColor(CGColor(srgbRed: dark, green: dark + 0.06, blue: dark + 0.04, alpha: 1))
        c.fillPath()
    }
    bigStructure(c, w, h, &rng, shift: shift)
    c.grain(w, h, &rng)
    return c.makeImage()!
}

func cityscape(_ w: Int, _ h: Int, seed: UInt64, shift: Double = 0) -> CGImage {
    var rng = Rng(seed)
    let c = context(w, h), W = Double(w), H = Double(h)
    c.fill(CGRect(x: 0, y: 0, width: W, height: H), (0.10, 0.12, 0.20))
    for i in 0..<160 { c.circle(rng.d(0, W), rng.d(H * 0.55, H), rng.d(1, 3) * W / 900,
                                (1, 1, 0.92), rng.d(0.2, 0.9)) }
    var x = -W * 0.05
    while x < W {
        let bw = rng.d(W * 0.07, W * 0.17), bh = rng.d(H * 0.16, H * 0.62)
        c.fill(CGRect(x: x + shift * 2, y: 0, width: bw, height: bh), (0.16, 0.17, 0.24))
        var wy = bh - H * 0.03
        while wy > H * 0.03 {
            var wx = x + bw * 0.12
            while wx < x + bw * 0.86 {
                if rng.d() > 0.35 {
                    c.fill(CGRect(x: wx + shift * 2, y: wy, width: bw * 0.10, height: H * 0.011),
                           (1.0, 0.86, 0.52), rng.d(0.45, 1.0))
                }
                wx += bw * 0.18
            }
            wy -= H * 0.032
        }
        x += bw * 1.06
    }
    bigStructure(c, w, h, &rng, shift: shift)
    c.grain(w, h, &rng)
    return c.makeImage()!
}

func stillLife(_ w: Int, _ h: Int, seed: UInt64, shift: Double = 0) -> CGImage {
    var rng = Rng(seed)
    let c = context(w, h), W = Double(w), H = Double(h)
    c.fill(CGRect(x: 0, y: 0, width: W, height: H), (0.90, 0.87, 0.82))
    c.circle(W * 0.5, H * 0.48, min(W, H) * 0.36, (0.98, 0.97, 0.95))
    c.circle(W * 0.5, H * 0.48, min(W, H) * 0.33, (0.94, 0.92, 0.89))
    for i in 0..<7 {
        let a = Double(i) / 7 * .pi * 2 + shift * 0.15
        c.circle(W * 0.5 + cos(a) * min(W, H) * 0.16,
                 H * 0.48 + sin(a) * min(W, H) * 0.16,
                 min(W, H) * rng.d(0.045, 0.085),
                 (rng.d(0.55, 0.95), rng.d(0.3, 0.7), rng.d(0.2, 0.45)))
    }
    for i in 0..<40 { c.circle(rng.d(0, W), rng.d(0, H), rng.d(2, 9) * W / 900,
                               (0.7, 0.65, 0.6), 0.25) }
    bigStructure(c, w, h, &rng, shift: shift)
    c.grain(w, h, &rng)
    return c.makeImage()!
}

// MARK: screenshots — the clutter, drawn at device resolution on purpose
// (the classifier treats an exact device-resolution match as conclusive)

let PHONE_W = 1320, PHONE_H = 2868

func statusBar(_ c: CGContext, _ W: Double, _ H: Double,
               dark: Bool, clock: String = "9:41") {
    let fg = dark ? (0.97, 0.97, 0.97) : (0.06, 0.06, 0.06)
    c.text(clock, W * 0.09, H - 118, size: 46, fg, font: "SFProText-Semibold")
    for i in 0..<4 {                                     // signal bars
        c.roundRect(CGRect(x: W * 0.79 + Double(i) * 20, y: H - 118,
                           width: 13, height: 12 + Double(i) * 9), 3, fg)
    }
    c.roundRect(CGRect(x: W * 0.90, y: H - 122, width: 62, height: 30), 8, fg, 0.35)
    c.roundRect(CGRect(x: W * 0.902, y: H - 120, width: 48, height: 26), 6, fg)
}

func chatShot(seed: UInt64, zh: Bool) -> CGImage {
    var rng = Rng(seed)
    let c = context(PHONE_W, PHONE_H)
    let W = Double(PHONE_W), H = Double(PHONE_H)
    c.fill(CGRect(x: 0, y: 0, width: W, height: H), (0.94, 0.94, 0.96))
    statusBar(c, W, H, dark: false)
    c.fill(CGRect(x: 0, y: H - 210, width: W, height: 90), (0.98, 0.98, 0.99))
    c.text(zh ? "群聊 · 6 人" : "Group · 6 people", W * 0.32, H - 185, size: 40,
           (0.15, 0.15, 0.18), font: "PingFangSC-Medium")

    let mine   = ["好的", "在路上了", "收到，等你消息", "哈哈哈", "这个我看过", "明天几点"]
    let theirs = ["刚到楼下", "你先点单吧", "我大概二十分钟", "我也这么觉得",
                  "那家店周一休息", "位置发你了"]
    let mineEn   = ["OK", "On my way", "Got it, ping me", "Ha", "Seen it", "What time"]
    let theirsEn = ["Just got downstairs", "Order without me",
                    "Twenty minutes or so", "Same here",
                    "They're closed Mondays", "Sent you the pin"]
    var y = H - 300
    while y > 420 {
        let right = rng.d() > 0.45          // two alignment modes = bimodality,
                                            // and the right column hugs the edge
        let pool = right ? (zh ? mine : mineEn) : (zh ? theirs : theirsEn)
        let s = pool[rng.i(0, pool.count - 1)]
        let tw = c.textWidth(s, size: 44)
        let bw = min(tw + 90, W * 0.68), bh = 116.0
        let x = right ? W - bw - W * 0.055 : W * 0.055
        c.roundRect(CGRect(x: x, y: y - bh, width: bw, height: bh), 34,
                    right ? (0.52, 0.85, 0.44) : (1, 1, 1))
        c.text(s, x + 45, y - bh + 42, size: 44, (0.08, 0.08, 0.10))
        if !right { c.circle(W * 0.055 - 40, y - bh + 58, 34, (0.72, 0.76, 0.82)) }
        y -= bh + rng.d(28, 66)
    }
    c.roundRect(CGRect(x: W * 0.05, y: 150, width: W * 0.9, height: 110), 55,
                (1, 1, 1))
    return c.makeImage()!
}

func gameShot(seed: UInt64, zh: Bool) -> CGImage {
    var rng = Rng(seed)
    let c = context(PHONE_W, PHONE_H)
    let W = Double(PHONE_W), H = Double(PHONE_H)
    for i in 0..<80 {                                    // saturated backdrop
        let t = Double(i) / 80
        c.fill(CGRect(x: 0, y: H * t, width: W, height: H / 80 + 2),
               (0.06 + 0.5 * t, 0.02 + 0.16 * t, 0.28 + 0.42 * (1 - t)))
    }
    for i in 0..<26 {
        c.roundRect(CGRect(x: rng.d(-W * 0.1, W), y: rng.d(0, H * 0.55),
                           width: rng.d(W * 0.1, W * 0.4), height: rng.d(40, 260)),
                    18, (0.05, 0.03, 0.14), rng.d(0.4, 0.9))
    }
    for i in 0..<40 { c.circle(rng.d(0, W), rng.d(H * 0.3, H), rng.d(3, 14),
                               (1, 0.85, 0.35), rng.d(0.3, 1)) }
    statusBar(c, W, H, dark: true)
    // HUD
    c.roundRect(CGRect(x: W * 0.06, y: H - 300, width: W * 0.46, height: 44), 22,
                (0, 0, 0), 0.5)
    c.roundRect(CGRect(x: W * 0.06, y: H - 300, width: W * 0.46 * rng.d(0.3, 0.95),
                       height: 44), 22, (0.92, 0.22, 0.26))
    c.text(zh ? "第 \(rng.i(3, 48)) 关" : "Stage \(rng.i(3, 48))",
           W * 0.06, H - 380, size: 52, (1, 1, 1), font: "PingFangSC-Semibold")
    c.text("\(rng.i(1000, 99999))", W * 0.62, H - 380, size: 62, (1, 0.92, 0.3),
           font: "SFProText-Bold")
    for i in 0..<3 {
        c.circle(W * (0.24 + Double(i) * 0.26), 300, 92, (1, 1, 1), 0.16)
        c.circle(W * (0.24 + Double(i) * 0.26), 300, 78, (0.30, 0.72, 0.95), 0.85)
    }
    return c.makeImage()!
}

func documentShot(seed: UInt64, zh: Bool) -> CGImage {
    var rng = Rng(seed)
    let c = context(PHONE_W, PHONE_H)
    let W = Double(PHONE_W), H = Double(PHONE_H)
    c.fill(CGRect(x: 0, y: 0, width: W, height: H), (0.99, 0.99, 0.98))
    statusBar(c, W, H, dark: false)
    c.text(zh ? "订单明细" : "Order details", W * 0.08, H - 320, size: 62,
           (0.1, 0.1, 0.12), font: "PingFangSC-Semibold")
    let rowsZh = ["小计", "运费", "优惠", "税费", "合计", "支付方式", "下单时间", "单号"]
    let rowsEn = ["Subtotal", "Shipping", "Discount", "Tax", "Total",
                  "Payment", "Placed", "Order no."]
    var y = H - 440
    for r in (zh ? rowsZh : rowsEn) {                    // paired rows, left label
        c.text(r, W * 0.08, y, size: 46, (0.35, 0.35, 0.40))
        let v = "\(rng.i(3, 260)).\(rng.i(10, 99))"
        c.text(v, W * 0.52, y, size: 46, (0.10, 0.10, 0.12))
        y -= 104
        c.fill(CGRect(x: W * 0.08, y: y + 62, width: W * 0.84, height: 2),
               (0.90, 0.90, 0.92))
    }
    var ly = y - 40
    while ly > 260 {                                     // dense left-aligned body
        let n = rng.i(14, 30)
        c.text(String(repeating: zh ? "说明文字 " : "line of text ", count: max(1, n / 6)),
               W * 0.08, ly, size: 36, (0.45, 0.45, 0.5))
        ly -= 70
    }
    return c.makeImage()!
}

func mapShot(seed: UInt64, zh: Bool) -> CGImage {
    var rng = Rng(seed)
    let c = context(PHONE_W, PHONE_H)
    let W = Double(PHONE_W), H = Double(PHONE_H)
    c.fill(CGRect(x: 0, y: 0, width: W, height: H), (0.91, 0.90, 0.86))
    for i in 0..<26 {                                    // blocks
        c.roundRect(CGRect(x: rng.d(0, W), y: rng.d(0, H),
                           width: rng.d(90, 340), height: rng.d(90, 300)), 8,
                    (0.85, 0.86, 0.81))
    }
    for i in 0..<7 {                                     // roads
        let vertical = rng.d() > 0.5
        let p = rng.d(0, vertical ? W : H), t = rng.d(14, 40)
        c.fill(vertical ? CGRect(x: p, y: 0, width: t, height: H)
                        : CGRect(x: 0, y: p, width: W, height: t), (1, 1, 1))
    }
    c.fill(CGRect(x: 0, y: H * 0.30, width: W, height: 26), (0.98, 0.83, 0.35))
    c.circle(W * 0.5, H * 0.56, 26, (0.20, 0.45, 0.95))
    c.circle(W * 0.5, H * 0.56, 90, (0.20, 0.45, 0.95), 0.18)
    statusBar(c, W, H, dark: false)
    c.roundRect(CGRect(x: W * 0.05, y: 200, width: W * 0.9, height: 220), 40, (1, 1, 1))
    c.text(zh ? "步行 12 分钟" : "12 min walk", W * 0.10, 330, size: 52,
           (0.1, 0.1, 0.12), font: "PingFangSC-Semibold")
    c.text(zh ? "约 900 米 · 路线较平缓" : "About 0.6 mi · mostly flat",
           W * 0.10, 250, size: 38, (0.42, 0.42, 0.47))
    return c.makeImage()!
}

func homeScreenShot(seed: UInt64) -> CGImage {
    var rng = Rng(seed)
    let c = context(PHONE_W, PHONE_H)
    let W = Double(PHONE_W), H = Double(PHONE_H)
    for i in 0..<80 {
        let t = Double(i) / 80
        c.fill(CGRect(x: 0, y: H * t, width: W, height: H / 80 + 2),
               (0.16 + 0.22 * t, 0.14 + 0.30 * t, 0.34 + 0.30 * t))
    }
    statusBar(c, W, H, dark: true)
    for row in 0..<6 {
        for col in 0..<4 {
            let x = W * 0.09 + Double(col) * W * 0.213
            let y = H * 0.74 - Double(row) * H * 0.112
            c.roundRect(CGRect(x: x, y: y, width: W * 0.152, height: W * 0.152),
                        W * 0.038,
                        (rng.d(0.2, 0.95), rng.d(0.2, 0.9), rng.d(0.25, 0.95)))
        }
    }
    c.roundRect(CGRect(x: W * 0.09, y: 180, width: W * 0.82, height: W * 0.19),
                W * 0.05, (1, 1, 1), 0.22)
    return c.makeImage()!
}

// MARK: writing, with an EXIF capture time

let base = Date(timeIntervalSince1970: 1_753_000_000)   // fixed, so runs match
var written = 0
var manifest: [String] = []

func write(_ img: CGImage, _ name: String, secondsAgo: Double, quality: Double = 0.9) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    guard let dst = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
    let d = base.addingTimeInterval(-secondsAgo)
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
    fmt.timeZone = TimeZone(identifier: "America/Los_Angeles")
    let stamp = fmt.string(from: d)
    let props: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: quality,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: stamp,
            kCGImagePropertyExifDateTimeDigitized: stamp,
        ],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFDateTime: stamp,
            kCGImagePropertyTIFFModel: "iPhone 15 Pro",
        ],
    ]
    CGImageDestinationAddImage(dst, img, props as CFDictionary)
    CGImageDestinationFinalize(dst)
    written += 1
    manifest.append(name)
}

/// Byte-identical copies. This is the only tier the app pre-ticks, so the
/// screenshot of that screen has to have real material.
func writeCopies(_ img: CGImage, _ stem: String, count: Int, secondsAgo: Double) {
    write(img, "\(stem)-1.jpg", secondsAgo: secondsAgo)
    let src = URL(fileURLWithPath: outDir).appendingPathComponent("\(stem)-1.jpg")
    for n in 2...count {
        let dst = URL(fileURLWithPath: outDir).appendingPathComponent("\(stem)-\(n).jpg")
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: src, to: dst)
        written += 1
        manifest.append("\(stem)-\(n).jpg")
    }
}

let PHOTO_W = 3024, PHOTO_H = 4032
var t = 0.0
func advance(_ s: Double) -> Double { t += s; return t }

print("生成到 \(outDir)")

// keepers — an ordinary library, so the app is not shown wanting to delete all
for i in 0..<14 {
    let seed = UInt64(9000 + i)
    let img: CGImage
    switch i % 3 {
    case 0:  img = landscape(PHOTO_W, PHOTO_H, seed: seed)
    case 1:  img = cityscape(PHOTO_W, PHOTO_H, seed: seed)
    default: img = stillLife(PHOTO_W, PHOTO_H, seed: seed)
    }
    write(img, "keep-\(i).jpg", secondsAgo: advance(90_000))
}

// exact copies — 7 groups
for i in 0..<7 {
    let seed = UInt64(100 + i)
    let img = i % 2 == 0 ? landscape(PHOTO_W, PHOTO_H, seed: seed)
                         : cityscape(PHOTO_W, PHOTO_H, seed: seed)
    writeCopies(img, "copy-\(i)", count: i % 3 == 0 ? 3 : 2,
                secondsAgo: advance(40_000))
}

// quality variants — same shot, different resolution and compression
for i in 0..<5 {
    let seed = UInt64(300 + i)
    let full = stillLife(PHOTO_W, PHOTO_H, seed: seed)
    let small = stillLife(PHOTO_W / 3, PHOTO_H / 3, seed: seed)
    let ts = advance(30_000)
    write(full,  "variant-\(i)-full.jpg",  secondsAgo: ts,       quality: 0.95)
    write(small, "variant-\(i)-small.jpg", secondsAgo: ts + 2,   quality: 0.55)
}

// bursts — small progressive change inside a 10-second window
for i in 0..<5 {
    let seed = UInt64(500 + i)
    let n = 4 + i % 3
    let t0 = advance(50_000)
    for f in 0..<n {
        let shift = Double(f) * 1.8
        let img = i % 2 == 0 ? landscape(PHOTO_W, PHOTO_H, seed: seed, shift: shift)
                             : cityscape(PHOTO_W, PHOTO_H, seed: seed, shift: shift)
        write(img, "burst-\(i)-\(f).jpg", secondsAgo: t0 + Double(f) * 1.6)
    }
}

// clutter categories
for i in 0..<9 { write(chatShot(seed: UInt64(700 + i), zh: i % 2 == 0),
                       "chat-\(i).jpg", secondsAgo: advance(9_000)) }
for i in 0..<5 { write(gameShot(seed: UInt64(760 + i), zh: i % 2 == 0),
                       "game-\(i).jpg", secondsAgo: advance(11_000)) }
// Documents, maps and home screens are deliberately NOT in the demo library.
//
// They classify correctly on a real device, where the FeaturePrint head runs.
// The Simulator has no Neural Engine — `VNGenerateImageFeaturePrintRequest`
// always fails there — so only the cold-start rules are left, and a receipt's
// "label left, amount right" layout is exactly the alignment bimodality plus
// right-hugging column the chat rule keys on: all six read as chat screenshots
// at 56–59% confidence.
//
// Store screenshots are taken on the Simulator, so putting them in would show
// six receipts counted as chats. A demo library holding fewer kinds of clutter
// is honest; a category count that is wrong is not. The generators are kept
// above for on-device testing.
_ = documentShot; _ = mapShot; _ = homeScreenShot

let total = manifest.reduce(0) { acc, n in
    let p = (outDir as NSString).appendingPathComponent(n)
    let sz = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? 0
    return acc + (sz ?? 0)
}
print("写出 \(written) 个文件，合计 \(String(format: "%.1f", Double(total) / 1_048_576)) MB")
