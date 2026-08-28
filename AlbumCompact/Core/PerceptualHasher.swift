import Foundation
import CoreGraphics
import Accelerate

/// Turns one `CGImage` into a `Fingerprint`. Everything here is pure CPU on a
/// tiny (32x32 / 9x8) buffer, so it costs microseconds per photo — the real
/// cost of a scan is thumbnail *decoding*, not hashing.
enum PerceptualHasher {

    // Precomputed 32-point DCT-II basis: cosTable[k][n] = cos(π(2n+1)k / 64)
    private static let dctSize = 32
    private static let cosTable: [[Float]] = {
        var t = [[Float]](repeating: [Float](repeating: 0, count: dctSize), count: dctSize)
        for k in 0..<dctSize {
            for n in 0..<dctSize {
                t[k][n] = Float(cos(Double.pi * Double(2 * n + 1) * Double(k) / Double(2 * dctSize)))
            }
        }
        return t
    }()

    static func fingerprint(from image: CGImage) -> Fingerprint? {
        guard let gray32 = grayscale(image, width: 32, height: 32),
              let gray9x8 = grayscale(image, width: 9, height: 8),
              let rgb = rgba(image, width: 32, height: 32)
        else { return nil }

        let d = differenceHash(gray9x8)
        let p = dctHash(gray32)
        let sharp = laplacianVariance(gray32, side: 32)
        let (sat, flat, edge, bright) = colorStats(rgb, side: 32, gray: gray32)

        return Fingerprint(dHash: d, pHash: p, contentHash: contentHash(gray32, rgb),
                           sharpness: sharp, saturation: sat, flatness: flat,
                           edgeDensity: edge, brightness: bright)
    }

    /// FNV-1a. Quantising the grayscale to 8 bits first keeps the hash stable
    /// against the tiny rounding differences between two decodes of the same
    /// file, while still changing for any visible difference.
    private static func contentHash(_ gray: [Float], _ rgba: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        @inline(__always) func mix(_ byte: UInt8) {
            h = (h ^ UInt64(byte)) &* 0x100000001b3
        }
        for v in gray { mix(UInt8(max(0, min(255, v * 255)))) }
        for i in stride(from: 0, to: rgba.count, by: 4) {
            mix(rgba[i]); mix(rgba[i + 1]); mix(rgba[i + 2])
        }
        return h
    }

    // MARK: dHash — compare each pixel with its right neighbour on a 9x8 grid

    private static func differenceHash(_ g: [Float]) -> UInt64 {
        var bits: UInt64 = 0
        var i = 0
        for row in 0..<8 {
            for col in 0..<8 {
                let a = g[row * 9 + col]
                let b = g[row * 9 + col + 1]
                if a > b { bits |= (1 << UInt64(i)) }
                i += 1
            }
        }
        return bits
    }

    // MARK: pHash — 32x32 DCT, keep the 8x8 low-frequency block, threshold at its median

    private static func dctHash(_ g: [Float]) -> UInt64 {
        let n = dctSize
        // rows
        var rowPass = [Float](repeating: 0, count: n * n)
        for r in 0..<n {
            let base = r * n
            for k in 0..<8 {                       // only the 8 lowest columns matter
                var s: Float = 0
                let ck = cosTable[k]
                for c in 0..<n { s += g[base + c] * ck[c] }
                rowPass[base + k] = s
            }
        }
        // columns
        var block = [Float](repeating: 0, count: 64)
        for k in 0..<8 {
            let ck = cosTable[k]
            for c in 0..<8 {
                var s: Float = 0
                for r in 0..<n { s += rowPass[r * n + c] * ck[r] }
                block[k * 8 + c] = s
            }
        }
        // median of the 63 coefficients excluding DC
        var tail = Array(block[1...])
        tail.sort()
        let median = tail[tail.count / 2]

        var bits: UInt64 = 0
        for i in 0..<64 where block[i] > median { bits |= (1 << UInt64(i)) }
        return bits
    }

    // MARK: quality / style statistics

    private static func laplacianVariance(_ g: [Float], side: Int) -> Float {
        var vals = [Float]()
        vals.reserveCapacity((side - 2) * (side - 2))
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let c = g[y * side + x]
                let l = 4 * c - g[y * side + x - 1] - g[y * side + x + 1]
                            - g[(y - 1) * side + x] - g[(y + 1) * side + x]
                vals.append(l)
            }
        }
        guard !vals.isEmpty else { return 0 }
        var mean: Float = 0, sd: Float = 0
        vsMeanAndSD(vals, &mean, &sd)
        // Normalise into a friendly 0…1 range; 0.15 sd ≈ visibly sharp at 32px.
        return min(1, sd / 0.15)
    }

    private static func colorStats(_ rgba: [UInt8], side: Int, gray: [Float])
        -> (saturation: Float, flatness: Float, edgeDensity: Float, brightness: Float) {

        let count = side * side
        var satSum: Float = 0
        var lumaSum: Float = 0
        var buckets = [Int: Int]()                     // 4-bit-per-channel colour histogram

        for i in 0..<count {
            let r = Float(rgba[i * 4 + 0]) / 255
            let g = Float(rgba[i * 4 + 1]) / 255
            let b = Float(rgba[i * 4 + 2]) / 255
            let mx = max(r, max(g, b)), mn = min(r, min(g, b))
            satSum += mx <= 0 ? 0 : (mx - mn) / mx
            lumaSum += 0.299 * r + 0.587 * g + 0.114 * b
            let key = (Int(r * 15) << 8) | (Int(g * 15) << 4) | Int(b * 15)
            buckets[key, default: 0] += 1
        }

        let top = buckets.values.sorted(by: >).prefix(8).reduce(0, +)
        let flatness = Float(top) / Float(count)

        var strong = 0
        for y in 0..<(side - 1) {
            for x in 0..<(side - 1) {
                let c = gray[y * side + x]
                let gx = abs(gray[y * side + x + 1] - c)
                let gy = abs(gray[(y + 1) * side + x] - c)
                if gx + gy > 0.12 { strong += 1 }
            }
        }
        let edge = Float(strong) / Float((side - 1) * (side - 1))

        return (satSum / Float(count), flatness, edge, lumaSum / Float(count))
    }

    // MARK: pixel extraction

    /// Downsample to `width x height` single-channel float in 0…1.
    static func grayscale(_ image: CGImage, width: Int, height: Int) -> [Float]? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &bytes, width: width, height: height,
                                 bitsPerComponent: 8, bytesPerRow: width,
                                 space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes.map { Float($0) / 255.0 }
    }

    static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &bytes, width: width, height: height,
                                 bitsPerComponent: 8, bytesPerRow: width * 4,
                                 space: cs, bitmapInfo: info)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    private static func vsMeanAndSD(_ v: [Float], _ mean: inout Float, _ sd: inout Float) {
        var m: Float = 0
        vDSP_meanv(v, 1, &m, vDSP_Length(v.count))
        var diff = [Float](repeating: 0, count: v.count)
        var negM = -m
        vDSP_vsadd(v, 1, &negM, &diff, 1, vDSP_Length(v.count))
        var ss: Float = 0
        vDSP_svesq(diff, 1, &ss, vDSP_Length(v.count))
        mean = m
        sd = sqrt(ss / Float(v.count))
    }
}
