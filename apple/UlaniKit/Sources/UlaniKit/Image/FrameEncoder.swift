import CoreGraphics
import Foundation
import ImageIO

/// How a picture is fitted to the 800x480 panel.
public enum FitMode: String, Sendable, CaseIterable {
    /// Aspect-fill: the centre, or the chosen `Crop` (the default for photos).
    case cover
    /// Aspect-fit, letterboxed on white.
    case contain
}

/// How photos are dithered: the apps' 顏色 (Colours) setting, kept as "natural", "bright" or
/// "classic".
/// The grain strength applies to both.
public enum Colours: String, Sendable, CaseIterable, Codable {
    /// 自然, the default: hue-sector error diffusion against the panel's measured colours
    /// (shared/DITHER.md).
    case natural
    /// 明亮: 自然 without the cusp move, keeping the photo's lightness (the 自然 of 0.4.0-0.4.1).
    case bright
    /// 經典: Stucki error diffusion against the ideal palette, as before 0.4.
    case classic
}

/// A photo's size in pixels.
public struct PhotoSize: Sendable, Hashable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// `1200x900`.
    public var description: String { "\(width)x\(height)" }
}

/// A decoded photo and the size its crop refers to.
public struct DecodedPhoto: Sendable {
    /// The photo with its EXIF orientation applied, decoded at `FrameEncoder.decodeSize`:
    /// at most the size of `size`, usually smaller.
    public let image: CGImage
    /// The photo's size after EXIF orientation and the 4K cap
    /// (`FrameEncoder.cappedPhotoSize`), from the file's header: what a `Crop`'s fractions,
    /// its minimum and its zoom limit refer to.
    public let size: PhotoSize

    public init(image: CGImage, size: PhotoSize) {
        self.image = image
        self.size = size
    }
}

/// A photo with more pixels than `FrameEncoder.photoPixelLimit` (shared/CROP.md, "Photo size"):
/// refused before decoding, never shrunk.
public struct PhotoTooLarge: Error, Sendable, Equatable, CustomStringConvertible {
    /// Width x height from the file's header.
    public let pixels: Int

    public init(pixels: Int) {
        self.pixels = pixels
    }

    /// Rounded, halves up (shared/vectors/photo-cap-vectors.json).
    public var megapixels: Int { (pixels + 500_000) / 1_000_000 }

    public var description: String { "the photo is over the 50 megapixel limit; shrink it first" }
}

/// Photos -> frames (as in image.py): refuse a photo over 50 MP, decode it at its size capped
/// to 4K with the EXIF orientation applied, flatten on white in sRGB, fit to 800x480, map to
/// the 7 colours, pack.
public enum FrameEncoder {
    /// Header pixels (width x height) above which a photo is refused; exactly this many is
    /// accepted.
    public static let photoPixelLimit = 50_000_000
    /// The largest photo every Paperhue app keeps, after EXIF orientation, for a landscape
    /// or square photo (a portrait one: the other way round). A larger photo is decoded
    /// scaled down to fit, aspect kept; a smaller one is decoded at full size, never scaled
    /// up. Decoding at the full cap keeps a crop zoomed in 8x sharp.
    public static let maxPhotoSize = PhotoSize(width: 3840, height: 2160)

    /// Decodes image data (JPEG, HEIC, PNG, ...) with its EXIF orientation applied, at its
    /// size capped to `maxPhotoSize` (`cappedPhotoSize`). Throws `PhotoTooLarge` for a
    /// photo over `photoPixelLimit`, before decoding anything.
    public static func loadImage(data: Data) throws -> CGImage {
        try loadPhoto(data: data).image
    }

    /// Like `loadImage(data:)`, reading the file at `url`.
    public static func loadImage(url: URL) throws -> CGImage {
        try loadPhoto(url: url).image
    }

    /// Like `loadImage(data:)`, with the size the photo's crop refers to (from its header,
    /// so the photo is decoded once).
    public static func loadPhoto(data: Data) throws -> DecodedPhoto {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw UlaniError.protocolError("unsupported image")
        }
        return try thumbnail(of: source, name: nil)
    }

    /// Like `loadPhoto(data:)`, reading the file at `url`.
    public static func loadPhoto(url: URL) throws -> DecodedPhoto {
        let name = url.lastPathComponent
        if url.isFileURL && !FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) {
            throw UlaniError.protocolError("\(name): cannot read the file")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw UlaniError.protocolError("\(name): unsupported image")
        }
        return try thumbnail(of: source, name: name)
    }

    /// Any image -> the frame to upload. `cover` crops: the centre, or `crop` (a crop
    /// `validated` for the photo) when given; `contain` letterboxes on white and ignores
    /// `crop`. `dither` selects error diffusion (`colours`: 自然 or 經典 Stucki) over plain
    /// nearest colour; `strength` scales the diffused error (1 = full; the apps offer 1, 0.8,
    /// 0.65 and 0.5).
    public static func encode(_ image: CGImage, fit: FitMode = .cover, crop: Crop? = nil, dither: Bool = true,
                              strength: Double = 1.0, colours: Colours = .classic) -> Frame {
        let rgba = render(image, fit: fit, crop: crop)
        if dither && colours != .classic {
            return Frame(packed: natural(rgba, strength: strength, cusp: colours == .natural))
        }
        return Frame(packed: quantize(rgba, dither: dither, strength: strength))
    }

    /// 自然: opaque RGBA8 panel pixels -> packed frame bytes, the error scaled by `strength`.
    static func natural(_ rgba: [UInt8], strength: Double, cusp: Bool = true) -> [UInt8] {
        let width = Frame.width, height = Frame.height
        precondition(rgba.count == width * height * 4, "expected \(width)x\(height) RGBA8")
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for p in 0..<(width * height) {
            rgb[3 * p] = rgba[4 * p]
            rgb[3 * p + 1] = rgba[4 * p + 1]
            rgb[3 * p + 2] = rgba[4 * p + 2]
        }
        return [UInt8](Frame.pack(Natural.indices(rgb, width: width, height: height, strength: strength, cusp: cusp)))
    }

    // MARK: steps

    private static func thumbnail(of source: CGImageSource, name: String?) throws -> DecodedPhoto {
        let unsupported = UlaniError.protocolError(name.map { "\($0): unsupported image" } ?? "unsupported image")
        guard CGImageSourceGetCount(source) > 0 else { throw unsupported }
        // The header's pixel size, in stored orientation (the cap and the decode size depend
        // only on the long and the short side).
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        try checkPixels(width: width, height: height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,  // never the embedded preview
            kCGImageSourceCreateThumbnailWithTransform: true,    // applies the EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeSize(width: width, height: height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw unsupported
        }
        guard width > 0, height > 0 else {  // size unknown: the decoded image's
            return DecodedPhoto(image: image, size: cappedPhotoSize(width: image.width, height: image.height))
        }
        // Orientations 5-8 turn the photo a quarter. The decoded image, already turned,
        // decides if the two disagree.
        let turned = (properties?[kCGImagePropertyOrientation] as? Int).map { (5...8).contains($0) } ?? false
        var oriented = turned ? PhotoSize(width: height, height: width) : PhotoSize(width: width, height: height)
        if (image.width > image.height && oriented.width < oriented.height)
            || (image.width < image.height && oriented.width > oriented.height) {
            oriented = PhotoSize(width: oriented.height, height: oriented.width)
        }
        return DecodedPhoto(image: image, size: cappedPhotoSize(width: oriented.width, height: oriented.height))
    }

    /// Throws `PhotoTooLarge` for a photo of more than `photoPixelLimit` pixels, by its
    /// header's size, so nothing is decoded.
    static func checkPixels(width: Int, height: Int) throws(PhotoTooLarge) {
        if width * height > photoPixelLimit { throw PhotoTooLarge(pixels: width * height) }
    }

    /// A `width` x `height` photo (after EXIF orientation) as every app keeps it
    /// (shared/CROP.md, "Photo size"): one that fits `maxPhotoSize` (turned round for a
    /// portrait photo) is untouched; otherwise the side that binds gets the box's edge and
    /// the other floor(x + 0.5), at least 1, in integers so every app gives the same size.
    public static func cappedPhotoSize(width: Int, height: Int) -> PhotoSize {
        let landscape = width >= height
        let boxW = landscape ? maxPhotoSize.width : maxPhotoSize.height
        let boxH = landscape ? maxPhotoSize.height : maxPhotoSize.width
        guard width > boxW || height > boxH else { return PhotoSize(width: width, height: height) }
        if boxW * height <= boxH * width {  // the width binds
            return PhotoSize(width: boxW, height: max(1, (2 * height * boxW + width) / (2 * width)))
        }
        return PhotoSize(width: max(1, (2 * width * boxH + height) / (2 * height)), height: boxH)
    }

    /// The long-side limit for decoding a `width` x `height` picture: the long side of its
    /// capped size (the cap depends only on the long and the short side, so the header's
    /// stored orientation will do). ImageIO never scales up. Size unknown: `maxPhotoSize`'s
    /// short side, which keeps any shape inside the cap.
    static func decodeSize(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return maxPhotoSize.height }
        let capped = cappedPhotoSize(width: width, height: height)
        return max(capped.width, capped.height)
    }

    /// `image` drawn onto an opaque white 800x480 sRGB canvas: RGBA8, row 0 = top.
    static func render(_ image: CGImage, fit: FitMode, crop: Crop? = nil) -> [UInt8] {
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
            context.draw(image, in: placement(width: image.width, height: image.height, fit: fit, crop: crop))
        }
        return pixels
    }

    /// Where a `width` x `height` picture goes on the panel, in CoreGraphics coordinates
    /// (origin bottom-left; the bitmap's first row is still the top). `contain` ignores `crop`.
    static func placement(width: Int, height: Int, fit: FitMode, crop: Crop? = nil) -> CGRect {
        let panelW = Double(Frame.width), panelH = Double(Frame.height)
        let w = Double(width), h = Double(height)
        switch fit {
        case .cover:
            if let crop {
                // Exactly the crop's box fills the panel, stretched to it (its shape is 5:3
                // within a pixel). The whole picture is drawn, so its edges are resampled as
                // without a crop.
                let box = cropBox(crop, width: width, height: height)
                let scaleX = panelW / Double(box.x1 - box.x0), scaleY = panelH / Double(box.y1 - box.y0)
                return CGRect(x: -Double(box.x0) * scaleX, y: -Double(height - box.y1) * scaleY,
                              width: w * scaleX, height: h * scaleY)
            }
            // Like ImageOps.fit: scale to fill, centre crop.
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

    /// `crop`'s box in a `width` x `height` picture (`Crop.box`, rows from the top), kept
    /// inside the picture and at least 1 pixel each way.
    static func cropBox(_ crop: Crop, width: Int, height: Int) -> Crop.Box {
        let box = crop.box(width: width, height: height)
        let x0 = min(max(box.x0, 0), width - 1), y0 = min(max(box.y0, 0), height - 1)
        return Crop.Box(x0: x0, y0: y0, x1: min(max(box.x1, x0 + 1), width), y1: min(max(box.y1, y0 + 1), height))
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
