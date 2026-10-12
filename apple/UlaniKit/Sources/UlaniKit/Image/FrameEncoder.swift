import CoreGraphics
import Foundation
import ImageIO

/// How a picture is fitted to the 800x480 panel.
public enum FitMode: String, Sendable, CaseIterable {
    /// Aspect-fill, centre crop (the default for photos).
    case cover
    /// Aspect-fit, letterboxed on white.
    case contain
}

/// Photos -> frames (as in image.py): decode at a sensible size with the EXIF orientation
/// applied, flatten on white in sRGB, fit to 800x480, map to the 7 colours, pack.
public enum FrameEncoder {
    /// Long side of a decoded photo: >= 2x the panel, so a 200 MP photo decodes small.
    static let maxPixelSize = 2400
    /// Short side of a decoded photo, at least: 2x the panel height, like Python's
    /// `draft((1600, 960))`, so `cover` scales even a wide panorama down, never up.
    static let minShortSide = 2 * Frame.height
    /// Upper bound for the long side of a panorama, so even an extreme strip decodes small
    /// (at most 8192 x 960 pixels).
    static let maxPixelSizeCap = 8192

    /// Decodes image data (JPEG, HEIC, PNG, ...) with its EXIF orientation applied, scaled
    /// down to `maxPixelSize` on the long side (more for a panorama, see `decodeSize`).
    public static func loadImage(data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw UlaniError.protocolError("unsupported image")
        }
        return try thumbnail(of: source, name: nil)
    }

    /// Like `loadImage(data:)`, reading the file at `url`.
    public static func loadImage(url: URL) throws -> CGImage {
        let name = url.lastPathComponent
        if url.isFileURL && !FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) {
            throw UlaniError.protocolError("\(name): cannot read the file")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw UlaniError.protocolError("\(name): unsupported image")
        }
        return try thumbnail(of: source, name: name)
    }

    /// Any image -> the frame to upload. `cover` crops, `contain` letterboxes on white.
    /// `dither` selects Stucki error diffusion over plain nearest colour; `strength` scales
    /// the diffused error (1 = full; the apps offer 1, 0.8, 0.65 and 0.5).
    public static func encode(_ image: CGImage, fit: FitMode = .cover, dither: Bool = true,
                              strength: Double = 1.0) -> Frame {
        Frame(packed: quantize(render(image, fit: fit), dither: dither, strength: strength))
    }

    // MARK: steps

    private static func thumbnail(of source: CGImageSource, name: String?) throws -> CGImage {
        let unsupported = UlaniError.protocolError(name.map { "\($0): unsupported image" } ?? "unsupported image")
        guard CGImageSourceGetCount(source) > 0 else { throw unsupported }
        // The header's pixel size (stored orientation; only long vs short side matters).
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,  // never the embedded preview
            kCGImageSourceCreateThumbnailWithTransform: true,    // applies the EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeSize(
                width: properties?[kCGImagePropertyPixelWidth] as? Int ?? 0,
                height: properties?[kCGImagePropertyPixelHeight] as? Int ?? 0),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw unsupported
        }
        return image
    }

    /// The long-side limit for decoding a `width` x `height` picture: `maxPixelSize`, raised
    /// (up to `maxPixelSizeCap`) until the short side keeps `minShortSide` pixels. ImageIO
    /// never scales up, so a limit above the picture's size decodes it at full size.
    static func decodeSize(width: Int, height: Int) -> Int {
        let long = max(width, height), short = min(width, height)
        guard short > 0 else { return maxPixelSize }  // size unknown
        let keepShortSide = (long * minShortSide + short - 1) / short  // rounded up
        return min(maxPixelSizeCap, max(maxPixelSize, keepShortSide))
    }

    /// `image` drawn onto an opaque white 800x480 sRGB canvas: RGBA8, row 0 = top.
    static func render(_ image: CGImage, fit: FitMode) -> [UInt8] {
        let width = Frame.width, height = Frame.height
        // Opaque white first: transparent pixels flatten onto it, and with an opaque
        // canvas the premultiplied result needs no un-premultiplying.
        var pixels = [UInt8](repeating: 0xFF, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            // Cannot fail for these constant, valid parameters.
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .high
            context.draw(image, in: placement(width: image.width, height: image.height, fit: fit))
        }
        return pixels
    }

    /// Where a `width` x `height` picture goes on the panel, in CoreGraphics coordinates
    /// (origin bottom-left; the bitmap's first row is still the top).
    static func placement(width: Int, height: Int, fit: FitMode) -> CGRect {
        let panelW = Double(Frame.width), panelH = Double(Frame.height)
        let w = Double(width), h = Double(height)
        switch fit {
        case .cover:  // like ImageOps.fit: scale to fill, centre crop
            let scale = max(panelW / w, panelH / h)
            return CGRect(x: (panelW - w * scale) / 2, y: (panelH - h * scale) / 2,
                          width: w * scale, height: h * scale)
        case .contain:  // like image.fit: integer size rounded half to even, floor-centred
            let scale = min(panelW / w, panelH / h)
            let innerW = max(1, min(Frame.width, Int((w * scale).rounded(.toNearestOrEven))))
            let innerH = max(1, min(Frame.height, Int((h * scale).rounded(.toNearestOrEven))))
            let left = (Frame.width - innerW) / 2, top = (Frame.height - innerH) / 2
            return CGRect(x: left, y: Frame.height - top - innerH, width: innerW, height: innerH)
        }
    }

    /// Opaque RGBA8 panel pixels -> packed frame bytes (first pixel in the high nibble).
    static func quantize(_ rgba: [UInt8], dither: Bool, strength: Double = 1.0) -> [UInt8] {
        let width = Frame.width, height = Frame.height
        precondition(rgba.count == width * height * 4, "expected \(width)x\(height) RGBA8")
        var rgb = [Int](repeating: 0, count: width * height * 3)
        for p in 0..<(width * height) {
            rgb[3 * p] = Int(rgba[4 * p])
            rgb[3 * p + 1] = Int(rgba[4 * p + 1])
            rgb[3 * p + 2] = Int(rgba[4 * p + 2])
        }
        let indices = dither
            ? stucki(rgb, width: width, height: height, strength: strength)
            : (0..<(width * height)).map { nearest(rgb[3 * $0], rgb[3 * $0 + 1], rgb[3 * $0 + 2]) }
        var packed = [UInt8](repeating: 0, count: Frame.byteCount)
        for p in stride(from: 0, to: indices.count, by: 2) {
            packed[p >> 1] = indices[p] << 4 | indices[p + 1]
        }
        return packed
    }

    /// Stucki's error-diffusion kernel: (weight, dx, dy), weights out of 42.
    static let stuckiKernel: [(weight: Int, dx: Int, dy: Int)] = [
        (8, 1, 0), (4, 2, 0),
        (2, -2, 1), (4, -1, 1), (8, 0, 1), (4, 1, 1), (2, 2, 1),
        (1, -2, 2), (2, -1, 2), (4, 0, 2), (2, 1, 2), (1, 2, 2),
    ]

    /// Palette indices of a `width` x `height` image given as Int RGB triples (row 0 = top).
    ///
    /// Pixels are visited left to right, top to bottom. Each takes the nearest palette
    /// colour; its error (pixel minus colour, per channel) goes to the kernel's neighbours
    /// inside the image, each receiving `Int(error * weight / 42 * strength)`. A neighbour
    /// pushed out of range keeps its hue: a negative channel lifts all three by
    /// `Int(255 * -low / (255 - low))`, a channel above 255 scales all three by `255 / high`
    /// (truncated), and then each is clamped to 0...255. All of this is integer and
    /// truncation exact, so every implementation of it gives the same indices.
    static func stucki(_ rgb: [Int], width: Int, height: Int, strength: Double = 1.0) -> [UInt8] {
        precondition(rgb.count == width * height * 3, "expected \(width)x\(height) RGB")
        let taps = stuckiKernel.map { (factor: Double($0.weight) / 42.0 * strength, dx: $0.dx, dy: $0.dy) }
        var pixels = rgb
        var indices = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBufferPointer { px in
            paletteRGB.withUnsafeBufferPointer { pal in
                for y in 0..<height {
                    for x in 0..<width {
                        let p = (y * width + x) * 3
                        let index = nearest(px[p], px[p + 1], px[p + 2])
                        indices[y * width + x] = index
                        let c = Int(index) * 3
                        let er = px[p] - pal[c], eg = px[p + 1] - pal[c + 1], eb = px[p + 2] - pal[c + 2]
                        if er == 0 && eg == 0 && eb == 0 { continue }  // nothing to spread
                        for tap in taps {
                            let tx = x + tap.dx, ty = y + tap.dy
                            guard tx >= 0, tx < width, ty < height else { continue }
                            let q = (ty * width + tx) * 3
                            let kept = keepInRange(px[q] + Int(Double(er) * tap.factor),
                                                   px[q + 1] + Int(Double(eg) * tap.factor),
                                                   px[q + 2] + Int(Double(eb) * tap.factor))
                            px[q] = kept.r
                            px[q + 1] = kept.g
                            px[q + 2] = kept.b
                        }
                    }
                }
            }
        }
        return indices
    }

    /// A colour pushed out of 0...255 by diffused error, brought back while keeping its hue:
    /// a negative channel lifts all three by `Int(255 * -low / (255 - low))`, then a channel
    /// above 255 scales all three by `255 / high` (truncated), then each is clamped.
    @inline(__always)
    static func keepInRange(_ r: Int, _ g: Int, _ b: Int) -> (r: Int, g: Int, b: Int) {
        var r = r, g = g, b = b
        let low = min(r, g, b)
        if low < 0 {
            let lift = Int(Double(255 * -low) / Double(255 - low))
            r += lift; g += lift; b += lift
        }
        let high = max(r, g, b)
        if high > 255 {
            let scale = 255.0 / Double(high)
            r = Int(Double(r) * scale); g = Int(Double(g) * scale); b = Int(Double(b) * scale)
        }
        return (min(max(r, 0), 255), min(max(g, 0), 255), min(max(b, 0), 255))
    }

    /// The palette as flat Int RGB triples, for `nearest`.
    private static let paletteRGB: [Int] = Palette.colours.flatMap { [Int($0.r), Int($0.g), Int($0.b)] }

    /// Same result as `Palette.nearestIndex` (smallest squared distance, lowest index on a
    /// tie), without its per-call overhead: this runs for every pixel, also in debug builds.
    @inline(__always)
    static func nearest(_ r: Int, _ g: Int, _ b: Int) -> UInt8 {
        paletteRGB.withUnsafeBufferPointer { pal in
            var best = 0, bestDistance = Int.max, i = 0
            while i < pal.count {
                let dr = r - pal[i], dg = g - pal[i + 1], db = b - pal[i + 2]
                let distance = dr * dr + dg * dg + db * db
                if distance < bestDistance { best = i; bestDistance = distance }
                i += 3
            }
            return UInt8(best / 3)
        }
    }
}

extension Frame {
    /// The encoder's own output: exactly `byteCount` packed bytes, every nibble a palette index.
    fileprivate init(packed: [UInt8]) {
        precondition(packed.count == Frame.byteCount)
        bytes = Data(packed)
    }
}
