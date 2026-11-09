import Foundation
import AppKit
import CoreGraphics

/// Decodes Wallpaper Engine `.tex` textures (TEXV0005 / TEXI0001 / TEXB000x).
enum TexDecoder {
    enum Result {
        case image(CGImage, isMask: Bool)
        case video(Data)
    }

    // Raw pixel formats
    static let RGBA8888: Int32 = 0, DXT5: Int32 = 4, DXT3: Int32 = 6, DXT1: Int32 = 7, RG88: Int32 = 8, R8: Int32 = 9
    static let freeImageUnknown: Int32 = -1, freeImageMP4: Int32 = 35

    static func decode(_ data: Data) throws -> Result {
        var r = BinaryReader([UInt8](data))
        let m1 = try r.cString(max: 16)
        guard m1.hasPrefix("TEXV") else { throw PorterError.corrupt("not a TEX file") }
        let m2 = try r.cString(max: 16)
        guard m2.hasPrefix("TEXI") else { throw PorterError.corrupt("bad TEX info header") }

        let format = try r.int32()
        _ = try r.int32()                    // flags
        _ = try r.int()                      // texture width (power of two)
        _ = try r.int()                      // texture height
        let imageWidth = try r.int()
        let imageHeight = try r.int()
        _ = try r.int32()                    // unknown

        let container = try r.cString(max: 16)
        guard container.hasPrefix("TEXB") else { throw PorterError.corrupt("bad TEX container \(container)") }
        var version = Int(container.dropFirst(4)) ?? 1
        let imageCount = try r.int()
        guard imageCount > 0 else { throw PorterError.corrupt("TEX has no images") }

        var freeImageFormat = freeImageUnknown
        var isMP4 = false
        if version == 3 {
            freeImageFormat = try r.int32()
        } else if version >= 4 {
            freeImageFormat = try r.int32()
            isMP4 = try r.int32() == 1
            if !isMP4 { version = 3 }
        }

        let mipCount = try r.int()
        guard mipCount > 0 else { throw PorterError.corrupt("TEX has no mipmaps") }

        // First mipmap is the full-size one.
        var width = 0, height = 0, lz4 = false, decompressedSize = 0
        var payload: [UInt8]
        switch version {
        case 1:
            width = try r.int(); height = try r.int()
            let byteCount = try r.int()
            payload = try r.data(byteCount)
        case 2, 3:
            width = try r.int(); height = try r.int()
            lz4 = try r.int32() == 1
            decompressedSize = try r.int()
            let byteCount = try r.int()
            payload = try r.data(byteCount)
        default: // TEXB0004 with embedded video
            _ = try r.int32(); _ = try r.int32()
            _ = try r.cString()
            _ = try r.int32()
            width = try r.int(); height = try r.int()
            lz4 = try r.int32() == 1
            decompressedSize = try r.int()
            let byteCount = try r.int()
            payload = try r.data(byteCount)
        }

        if lz4 { payload = try LZ4.decompressBlock(payload, size: decompressedSize) }

        if isMP4 || freeImageFormat == freeImageMP4 || looksLikeMP4(payload) {
            return .video(Data(payload))
        }

        if freeImageFormat != freeImageUnknown {
            // Payload is a normal encoded image (PNG/JPEG/…).
            guard let rep = NSBitmapImageRep(data: Data(payload)), let cg = rep.cgImage else {
                throw PorterError.corrupt("embedded image couldn't be decoded")
            }
            return .image(crop(cg, imageWidth, imageHeight), isMask: false)
        }

        guard width > 0, height > 0, width <= 16384, height <= 16384 else {
            throw PorterError.corrupt("bad TEX size \(width)x\(height)")
        }

        let rgba: [UInt8]
        var isMask = false
        switch format {
        case RGBA8888:
            guard payload.count >= width * height * 4 else { throw PorterError.corrupt("RGBA data too short") }
            rgba = Array(payload[0 ..< width * height * 4])
        case DXT1: rgba = DXT.decode(payload, width: width, height: height, kind: .dxt1)
        case DXT3: rgba = DXT.decode(payload, width: width, height: height, kind: .dxt3)
        case DXT5: rgba = DXT.decode(payload, width: width, height: height, kind: .dxt5)
        case RG88:
            isMask = true
            var out = [UInt8](repeating: 255, count: width * height * 4)
            for i in 0 ..< min(width * height, payload.count / 2) {
                let l = payload[i * 2], a = payload[i * 2 + 1]
                out[i * 4] = l; out[i * 4 + 1] = l; out[i * 4 + 2] = l; out[i * 4 + 3] = a
            }
            rgba = out
        case R8:
            isMask = true
            var out = [UInt8](repeating: 255, count: width * height * 4)
            for i in 0 ..< min(width * height, payload.count) {
                let l = payload[i]
                out[i * 4] = l; out[i * 4 + 1] = l; out[i * 4 + 2] = l
            }
            rgba = out
        default:
            throw PorterError.corrupt("unsupported TEX pixel format \(format)")
        }

        guard let cg = makeImage(rgba, width: width, height: height) else {
            throw PorterError.corrupt("couldn't build image")
        }
        return .image(crop(cg, imageWidth, imageHeight), isMask: isMask)
    }

    static func looksLikeMP4(_ b: [UInt8]) -> Bool {
        b.count > 12 && b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70 // "ftyp"
    }

    static func makeImage(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Textures are padded to powers of two; trim back to the real picture size.
    static func crop(_ cg: CGImage, _ w: Int, _ h: Int) -> CGImage {
        guard w > 0, h > 0, w <= cg.width, h <= cg.height, (w < cg.width || h < cg.height) else { return cg }
        return cg.cropping(to: CGRect(x: 0, y: 0, width: w, height: h)) ?? cg
    }
}

/// LZ4 block-format decompressor.
enum LZ4 {
    static func decompressBlock(_ src: [UInt8], size: Int) throws -> [UInt8] {
        guard size > 0, size < 1 << 30 else { throw PorterError.corrupt("bad LZ4 size") }
        var out = [UInt8](repeating: 0, count: size)
        var i = 0, o = 0
        let n = src.count
        try out.withUnsafeMutableBufferPointer { dst in
            try src.withUnsafeBufferPointer { s in
                while i < n {
                    let token = Int(s[i]); i += 1
                    var lit = token >> 4
                    if lit == 15 {
                        while true {
                            guard i < n else { throw PorterError.corrupt("LZ4 literal length") }
                            let b = Int(s[i]); i += 1; lit += b
                            if b != 255 { break }
                        }
                    }
                    guard i + lit <= n, o + lit <= size else { throw PorterError.corrupt("LZ4 literals overflow") }
                    for k in 0 ..< lit { dst[o + k] = s[i + k] }
                    i += lit; o += lit
                    if i >= n { break } // last sequence has literals only

                    guard i + 1 < n else { throw PorterError.corrupt("LZ4 offset") }
                    let offset = Int(s[i]) | Int(s[i + 1]) << 8
                    i += 2
                    guard offset > 0, offset <= o else { throw PorterError.corrupt("LZ4 bad offset") }
                    var match = (token & 15) + 4
                    if token & 15 == 15 {
                        while true {
                            guard i < n else { throw PorterError.corrupt("LZ4 match length") }
                            let b = Int(s[i]); i += 1; match += b
                            if b != 255 { break }
                        }
                    }
                    guard o + match <= size else { throw PorterError.corrupt("LZ4 match overflow") }
                    let from = o - offset
                    for k in 0 ..< match { dst[o + k] = dst[from + k] } // byte-wise: overlap is intended
                    o += match
                }
            }
        }
        return out
    }
}

/// S3TC / DXT block decompression to RGBA8.
enum DXT {
    enum Kind { case dxt1, dxt3, dxt5 }

    static func decode(_ src: [UInt8], width: Int, height: Int, kind: Kind) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let bw = (width + 3) / 4, bh = (height + 3) / 4
        let blockSize = kind == .dxt1 ? 8 : 16
        var alpha = [UInt8](repeating: 255, count: 16)
        var apal = [Int](repeating: 0, count: 8)
        var pr = [Int](repeating: 0, count: 4), pg = pr, pb = pr, pa = pr

        for by in 0 ..< bh {
            for bx in 0 ..< bw {
                let base = (by * bw + bx) * blockSize
                guard base + blockSize <= src.count else { return out }
                var c = base

                switch kind {
                case .dxt1:
                    break
                case .dxt3:
                    c = base + 8
                    for k in 0 ..< 16 {
                        let byte = src[base + k / 2]
                        let nib = k % 2 == 0 ? byte & 0x0F : byte >> 4
                        alpha[k] = nib * 17
                    }
                case .dxt5:
                    c = base + 8
                    let a0 = Int(src[base]), a1 = Int(src[base + 1])
                    apal[0] = a0; apal[1] = a1
                    if a0 > a1 {
                        for j in 1 ... 6 { apal[j + 1] = ((7 - j) * a0 + j * a1) / 7 }
                    } else {
                        for j in 1 ... 4 { apal[j + 1] = ((5 - j) * a0 + j * a1) / 5 }
                        apal[6] = 0; apal[7] = 255
                    }
                    var bits: UInt64 = 0
                    for j in 0 ..< 6 { bits |= UInt64(src[base + 2 + j]) << UInt64(8 * j) }
                    for k in 0 ..< 16 { alpha[k] = UInt8(apal[Int((bits >> UInt64(3 * k)) & 7)]) }
                }

                let c0 = Int(src[c]) | Int(src[c + 1]) << 8
                let c1 = Int(src[c + 2]) | Int(src[c + 3]) << 8
                expand565(c0, &pr[0], &pg[0], &pb[0]); pa[0] = 255
                expand565(c1, &pr[1], &pg[1], &pb[1]); pa[1] = 255
                if kind != .dxt1 || c0 > c1 {
                    pr[2] = (2 * pr[0] + pr[1]) / 3; pg[2] = (2 * pg[0] + pg[1]) / 3; pb[2] = (2 * pb[0] + pb[1]) / 3; pa[2] = 255
                    pr[3] = (pr[0] + 2 * pr[1]) / 3; pg[3] = (pg[0] + 2 * pg[1]) / 3; pb[3] = (pb[0] + 2 * pb[1]) / 3; pa[3] = 255
                } else {
                    pr[2] = (pr[0] + pr[1]) / 2; pg[2] = (pg[0] + pg[1]) / 2; pb[2] = (pb[0] + pb[1]) / 2; pa[2] = 255
                    pr[3] = 0; pg[3] = 0; pb[3] = 0; pa[3] = 0
                }
                let idx = UInt32(src[c + 4]) | UInt32(src[c + 5]) << 8 | UInt32(src[c + 6]) << 16 | UInt32(src[c + 7]) << 24

                for k in 0 ..< 16 {
                    let px = bx * 4 + k % 4, py = by * 4 + k / 4
                    if px >= width || py >= height { continue }
                    let p = Int((idx >> UInt32(2 * k)) & 3)
                    let o = (py * width + px) * 4
                    out[o] = UInt8(pr[p]); out[o + 1] = UInt8(pg[p]); out[o + 2] = UInt8(pb[p])
                    out[o + 3] = kind == .dxt1 ? UInt8(pa[p]) : alpha[k]
                }
            }
        }
        return out
    }

    @inline(__always)
    private static func expand565(_ c: Int, _ r: inout Int, _ g: inout Int, _ b: inout Int) {
        let r5 = (c >> 11) & 31, g6 = (c >> 5) & 63, b5 = c & 31
        r = (r5 << 3) | (r5 >> 2); g = (g6 << 2) | (g6 >> 4); b = (b5 << 3) | (b5 >> 2)
    }
}
