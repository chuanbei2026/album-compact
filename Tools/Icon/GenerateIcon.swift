import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let S: CGFloat = 1024

func ctx(_ n: Int) -> CGContext {
    CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
}
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: Double = 1) -> CGColor {
    CGColor(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255, alpha: a)
}
func save(_ img: CGImage, _ name: String) {
    let d = CGImageDestinationCreateWithURL(
        outDir.appendingPathComponent(name) as CFURL,
        UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil)
    CGImageDestinationFinalize(d)
}
func rr(_ r: CGRect, _ rad: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
}

/// A Polaroid-style card: white border, inset image well with the classic thicker
/// bottom margin. This is the only shape that still reads as "a photo" once the
/// icon is 40 px tall — a plain rectangle reads as a form field.
func polaroid(_ c: CGContext, center: CGPoint, w: CGFloat, rot: CGFloat,
              well: (CGContext, CGRect) -> Void, paper: CGColor = rgb(250, 251, 253)) {
    let h = w * 1.17                       // portrait, like a real print
    let r = CGRect(x: center.x - w/2, y: center.y - h/2, width: w, height: h)
    c.saveGState()
    c.translateBy(x: center.x, y: center.y)
    c.rotate(by: rot)
    c.translateBy(x: -center.x, y: -center.y)

    c.setShadow(offset: CGSize(width: 0, height: -13), blur: 30, color: rgb(3, 12, 24, 0.36))
    c.setFillColor(paper)
    c.addPath(rr(r, w * 0.085))
    c.fillPath()
    c.setShadow(offset: .zero, blur: 0, color: nil)

    let pad = w * 0.085
    let wellRect = CGRect(x: r.minX + pad, y: r.minY + pad * 2.6,
                          width: r.width - pad * 2, height: r.height - pad * 3.9)
    c.saveGState()
    c.addPath(rr(wellRect, w * 0.035))
    c.clip()
    well(c, wellRect)
    c.restoreGState()
    c.restoreGState()
}

/// A tiny stylised landscape — sky wash, hill, sun. Decoration at large sizes;
/// at 40 px only its colour survives, which is exactly what it is there for.
func landscape(_ c: CGContext, _ r: CGRect) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(96, 200, 214), rgb(36, 132, 152)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.maxY),
                         end: CGPoint(x: r.minX, y: r.minY), options: [])
    c.setFillColor(rgb(255, 214, 120))
    let sr = r.width * 0.15
    c.fillEllipse(in: CGRect(x: r.minX + r.width * 0.62, y: r.minY + r.height * 0.63,
                             width: sr, height: sr))
    c.setFillColor(rgb(24, 96, 104))
    c.beginPath()
    c.move(to: CGPoint(x: r.minX, y: r.minY))
    c.addLine(to: CGPoint(x: r.minX + r.width * 0.34, y: r.minY + r.height * 0.52))
    c.addLine(to: CGPoint(x: r.minX + r.width * 0.66, y: r.minY + r.height * 0.16))
    c.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.46))
    c.addLine(to: CGPoint(x: r.maxX, y: r.minY))
    c.closePath()
    c.fillPath()
}
func flat(_ color: CGColor) -> (CGContext, CGRect) -> Void {
    { c, r in c.setFillColor(color); c.fill(r) }
}

/// The same picture under the app's delete tint: still recognisably a photo,
/// unmistakably marked. A blank coral rectangle would just be a coral rectangle.
func tintedLandscape(_ c: CGContext, _ r: CGRect) {
    landscape(c, r)
    c.setFillColor(rgb(255, 96, 104, 0.74))
    c.fill(r)
}

func background(_ c: CGContext) {
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(30, 62, 102), rgb(13, 92, 96)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(255, 255, 255, 0.12), rgb(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(glow, startCenter: CGPoint(x: S*0.52, y: S*0.54), startRadius: 0,
                         endCenter: CGPoint(x: S*0.52, y: S*0.54), endRadius: S*0.5, options: [])
}

// ---------------------------------------------------------------- variants

/// A · the pile, with the duplicate on its way out to the left
func variantA(_ c: CGContext) {
    background(c)
    let cw: CGFloat = 400
    polaroid(c, center: CGPoint(x: S*0.625, y: S*0.560), w: cw, rot:  0.17,
             well: flat(rgb(212, 222, 233)), paper: rgb(227, 233, 241))
    polaroid(c, center: CGPoint(x: S*0.588, y: S*0.515), w: cw, rot: 0.06,
             well: flat(rgb(226, 234, 242)))
    polaroid(c, center: CGPoint(x: S*0.565, y: S*0.470), w: cw, rot: -0.05, well: landscape)
    // the copy on its way out — tinted, tilted, already half gone
    polaroid(c, center: CGPoint(x: S*0.235, y: S*0.605), w: cw * 0.86, rot: -0.40,
             well: tintedLandscape, paper: rgb(255, 240, 240))
}

/// B · the pile alone, with the mint "checked and safe" badge
func variantB(_ c: CGContext) {
    background(c)
    let cw: CGFloat = 404
    polaroid(c, center: CGPoint(x: S*0.545, y: S*0.555), w: cw, rot:  0.19,
             well: flat(rgb(212, 222, 233)), paper: rgb(227, 233, 241))
    polaroid(c, center: CGPoint(x: S*0.505, y: S*0.512), w: cw, rot: 0.065,
             well: flat(rgb(226, 234, 242)))
    polaroid(c, center: CGPoint(x: S*0.478, y: S*0.468), w: cw, rot: -0.055, well: landscape)

    let cx = S*0.755, cy = S*0.255, rad: CGFloat = 116
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: rgb(3, 12, 24, 0.4))
    c.setFillColor(rgb(58, 214, 152))
    c.fillEllipse(in: CGRect(x: cx-rad, y: cy-rad, width: rad*2, height: rad*2))
    c.restoreGState()
    c.setStrokeColor(rgb(10, 46, 36))
    c.setLineWidth(29); c.setLineCap(.round); c.setLineJoin(.round)
    c.beginPath()
    c.move(to: CGPoint(x: cx-50, y: cy+4))
    c.addLine(to: CGPoint(x: cx-13, y: cy-35))
    c.addLine(to: CGPoint(x: cx+54, y: cy+43))
    c.strokePath()
}

/// C · two identical prints, the copy dissolving — the dedupe idea, literally
func variantC(_ c: CGContext) {
    background(c)
    let cw: CGFloat = 356
    // the copy: same picture, faded, offset back
    c.saveGState()
    c.setAlpha(0.34)
    polaroid(c, center: CGPoint(x: S*0.655, y: S*0.585), w: cw, rot: 0.20, well: landscape)
    c.restoreGState()
    c.saveGState()
    c.setAlpha(0.62)
    polaroid(c, center: CGPoint(x: S*0.575, y: S*0.53), w: cw, rot: 0.10, well: landscape)
    c.restoreGState()
    // the keeper
    polaroid(c, center: CGPoint(x: S*0.435, y: S*0.455), w: cw, rot: -0.075, well: landscape)
}

let variants: [(String, (CGContext) -> Void)] = [("A", variantA), ("B", variantB), ("C", variantC)]

for (name, draw) in variants {
    let c = ctx(Int(S)); draw(c)
    save(c.makeImage()!, "v\(name)_1024.png")
    for n in [180, 120, 80, 60, 40] {
        let sc = ctx(n)
        sc.interpolationQuality = .high
        sc.scaleBy(x: CGFloat(n)/S, y: CGFloat(n)/S)
        draw(sc)
        save(sc.makeImage()!, "v\(name)_\(n).png")
    }
    print("variant \(name) done")
}

// contact sheet
let sh = ctx(1000)
sh.setFillColor(rgb(22, 24, 28)); sh.fill(CGRect(x: 0, y: 0, width: 1000, height: 1000))
func place(_ n: String, _ x: CGFloat, _ y: CGFloat, _ s: CGFloat) {
    guard let src = CGImageSourceCreateWithURL(outDir.appendingPathComponent(n) as CFURL, nil),
          let im = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
    sh.draw(im, in: CGRect(x: x, y: y, width: s, height: s))
}
func label(_ s: String, _ x: CGFloat, _ y: CGFloat, _ sz: CGFloat = 22) {
    let f = NSFont(name: "Helvetica-Bold", size: sz) ?? NSFont.systemFont(ofSize: sz)
    let a = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: NSColor.white])
    sh.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(CTLineCreateWithAttributedString(a), sh)
}
var yy: CGFloat = 740
for (name, _) in variants {
    var xx: CGFloat = 100
    place("v\(name)_1024.png", xx, yy, 210); xx += 240
    for n in [180, 120, 80, 60, 40] {
        place("v\(name)_\(n).png", xx, yy + (210 - CGFloat(n))/2, CGFloat(n))
        xx += CGFloat(n) + 30
    }
    label(name, 50, yy + 96, 34)
    yy -= 250
}
label("1024        180      120     80    60   40", 100, 700, 18)
save(sh.makeImage()!, "sheet2.png")
print("sheet done")
