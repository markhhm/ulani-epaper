import Foundation

/// The part of a photo that fills the panel in `cover` mode (shared/CROP.md; Python:
/// `image.Crop`): a rectangle with the panel's 800:480 shape, as fractions 0-1 of the photo
/// after EXIF orientation and the 4K cap (`DecodedPhoto.size`). No crop (nil) is the
/// centred Fill, rendered exactly as before; `contain` ignores the crop.
public struct Crop: Sendable, Hashable, CustomStringConvertible {
    public var left: Double
    public var top: Double
    public var width: Double
    public var height: Double

    /// A crop is at least this many photo pixels high (or as high as `centred`, if that is
    /// lower) ...
    public static let minimumHeight = 100
    /// ... and at least 1/`maximumZoom` of `centred`'s width.
    public static let maximumZoom = 8

    public init(left: Double, top: Double, width: Double, height: Double) {
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }

    /// `(left, top, width, height)`, like Python's tuple.
    public var description: String { "(\(left), \(top), \(width), \(height))" }

    /// The panel's width over its height.
    private static let aspect = Double(Frame.width) / Double(Frame.height)

    /// The largest centred rectangle with the panel's shape in a `width` x `height` photo:
    /// what `cover` shows without a crop (Python: `default_crop`, computed in the same order
    /// so the fractions are the same doubles). Reset goes back to no crop, not to this.
    public static func centred(width: Int, height: Int) -> Crop {
        let w = Double(width), h = Double(height)
        if w / h > aspect {  // wider than the panel: full height, sides cut
            let share = h * aspect / w
            return Crop(left: (1 - share) / 2, top: 0, width: share, height: 1)
        }
        let share = w / aspect / h
        return Crop(left: 0, top: (1 - share) / 2, width: 1, height: share)
    }

    /// The narrowest crop `validated` accepts in a `width` x `height` photo, as a fraction
    /// of its width (the zoom limit): `minimumHeight` pixels high, or `centred` itself when
    /// that is lower, and `1 / maximumZoom` of `centred`'s width.
    public static func minimumWidth(width: Int, height: Int) -> Double {
        let centred = Self.centred(width: width, height: height)
        let lowest = min(Double(minimumHeight), centred.height * Double(height))  // photo pixels
        return max(lowest * aspect / Double(width), centred.width / Double(maximumZoom))
    }

    /// Pixel columns `x0..<x1` and rows `y0..<y1` of an image.
    public struct Box: Sendable, Hashable {
        public var x0: Int
        public var y0: Int
        public var x1: Int
        public var y1: Int

        public init(x0: Int, y0: Int, x1: Int, y1: Int) {
            self.x0 = x0
            self.y0 = y0
            self.x1 = x1
            self.y1 = y1
        }
    }

    /// The crop in the pixels of a `width` x `height` image, the one actually resized
    /// (Python: `crop_box`): each edge is `floor(v + 0.5)` in Double, exactly as written
    /// (round half up, not to even), so every implementation gets the same box.
    public func box(width: Int, height: Int) -> Box {
        let w = Double(width), h = Double(height)
        return Box(x0: Self.roundHalfUp(left * w), y0: Self.roundHalfUp(top * h),
                   x1: Self.roundHalfUp((left + self.width) * w), y1: Self.roundHalfUp((top + self.height) * h))
    }

    /// `floor(value + 0.5)`; never traps (a crop that is not finite has no sensible box).
    private static func roundHalfUp(_ value: Double) -> Int {
        let rounded = (value + 0.5).rounded(.down)
        return rounded.isNaN ? 0 : Int(min(max(rounded, -0x1p52), 0x1p52))
    }

    /// This crop if it suits a `width` x `height` photo (after EXIF orientation and the 4K
    /// cap), else `CropError` (Python: `check_crop`, the same tests and tolerances): finite,
    /// inside the photo (1e-9 slack), the panel's shape within 1 pixel, and at least
    /// `minimumWidth` (as `minimumHeight` pixels with 1e-6 slack, as the width with 1e-9).
    @discardableResult
    public func validated(width photoWidth: Int, height photoHeight: Int) throws(CropError) -> Crop {
        precondition(photoWidth > 0 && photoHeight > 0, "a photo has pixels")
        guard [left, top, width, height].allSatisfy(\.isFinite), left >= 0, top >= 0, width > 0, height > 0,
              left + width <= 1 + 1e-9, top + height <= 1 + 1e-9 else {
            throw .outside(self)
        }
        let w = Double(photoWidth), h = Double(photoHeight)
        if abs(width * w - height * h * Double(Frame.width) / Double(Frame.height)) > 1 {
            throw .wrongShape(width: width * w, height: height * h)
        }
        let centred = Self.centred(width: photoWidth, height: photoHeight)
        if height * h < min(Double(Self.minimumHeight), centred.height * h) - 1e-6
            || width < centred.width / Double(Self.maximumZoom) - 1e-9 {
            throw .tooSmall
        }
        return self
    }
}

/// Why a crop does not suit a photo (`Crop.validated`). `description` is the English text,
/// Python's ValueError message.
public enum CropError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A value is not finite, the size is not positive, or it reaches outside the photo.
    case outside(Crop)
    /// Not the panel's shape; the crop's size in photo pixels.
    case wrongShape(width: Double, height: Double)
    /// Under `Crop.minimumWidth`.
    case tooSmall

    public var description: String {
        switch self {
        case .outside(let crop):
            "the crop must lie inside the photo (fractions 0-1), got \(crop)"
        case .wrongShape(let width, let height):
            "the crop must have the screen's \(Frame.width):\(Frame.height) shape, got "
                + String(format: "%.1f x %.1f px", width, height)
        case .tooSmall:
            "the crop is too small (at most \(Crop.maximumZoom)x zoom and at least "
                + "\(Crop.minimumHeight) photo pixels high)"
        }
    }
}
