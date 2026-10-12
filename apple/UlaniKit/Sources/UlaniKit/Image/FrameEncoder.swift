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

    /// Any image -> the frame to upload. `cover` crops, `contain` letterboxes on white;
    /// `dither` selects Floyd-Steinberg error diffusion over plain nearest colour.
    public static func encode(_ image: CGImage, fit: FitMode = .cover, dither: Bool = true) -> Frame {
        Frame(packed: quantize(render(image, fit: fit), dither: dither))
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
    /// Floyd-Steinberg runs on Float RGB, left to right on every row; each value is clamped
    /// to 0...255 before the nearest-colour lookup and its error taken from the clamped value.
    static func quantize(_ rgba: [UInt8], dither: Bool) -> [UInt8] {
        let width = Frame.width, height = Frame.height
        precondition(rgba.count == width * height * 4, "expected \(width)x\(height) RGBA8")
        var packed = [UInt8](repeating: 0, count: Frame.byteCount)
        let palette = Palette.colours.flatMap { [Float($0.r), Float($0.g), Float($0.b)] }

        rgba.withUnsafeBufferPointer { src in
            packed.withUnsafeMutableBufferPointer { dst in
                func store(_ index: UInt8, at pixel: Int) {
                    if pixel & 1 == 0 { dst[pixel >> 1] = index << 4 } else { dst[pixel >> 1] |= index }
                }
                guard dither else {
                    for p in 0..<(width * height) {
                        store(nearest(Int(src[4 * p]), Int(src[4 * p + 1]), Int(src[4 * p + 2])), at: p)
                    }
                    return
                }
                // Errors for this row and the next, RGB per pixel, one spare pixel on each
                // side so x - 1 and x + 1 never leave the buffer (edge errors are dropped).
                let rowLength = (width + 2) * 3
                var current = UnsafeMutableBufferPointer<Float>.allocate(capacity: rowLength)
                var next = UnsafeMutableBufferPointer<Float>.allocate(capacity: rowLength)
                defer { current.deallocate(); next.deallocate() }
                current.initialize(repeating: 0)
                next.initialize(repeating: 0)
                palette.withUnsafeBufferPointer { pal in
                    for y in 0..<height {
                        for x in 0..<width {
                            let p = y * width + x, s = 4 * p, e = (x + 1) * 3
                            let r = min(max(Float(src[s]) + current[e], 0), 255)
                            let g = min(max(Float(src[s + 1]) + current[e + 1], 0), 255)
                            let b = min(max(Float(src[s + 2]) + current[e + 2], 0), 255)
                            let index = nearest(Int(r.rounded()), Int(g.rounded()), Int(b.rounded()))
                            store(index, at: p)
                            let c = Int(index) * 3
                            diffuse(r - pal[c], channel: 0, at: e, current, next)
                            diffuse(g - pal[c + 1], channel: 1, at: e, current, next)
                            diffuse(b - pal[c + 2], channel: 2, at: e, current, next)
                        }
                        swap(&current, &next)
                        next.update(repeating: 0)
                    }
                }
            }
        }
        return packed
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

    /// Spreads one channel's error: 7/16 right, 3/16 below left, 5/16 below, 1/16 below right.
    @inline(__always)
    private static func diffuse(_ error: Float, channel: Int, at e: Int,
                                _ current: UnsafeMutableBufferPointer<Float>,
                                _ next: UnsafeMutableBufferPointer<Float>) {
        guard error != 0 else { return }
        let i = e + channel
        current[i + 3] += error * (7 / 16)
        next[i - 3] += error * (3 / 16)
        next[i] += error * (5 / 16)
        next[i + 3] += error * (1 / 16)
    }
}

extension Frame {
    /// The encoder's own output: exactly `byteCount` packed bytes, every nibble a palette index.
    fileprivate init(packed: [UInt8]) {
        precondition(packed.count == Frame.byteCount)
        bytes = Data(packed)
    }
}
