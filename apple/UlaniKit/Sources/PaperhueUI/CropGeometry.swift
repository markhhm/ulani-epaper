import CoreGraphics
import Foundation
import UlaniKit

/// The crop editor's maths, without a view (shared/CROP.md, Editor): the frame over the photo
/// and what moving, resizing, zooming and nudging do to it. Points are fractions of the photo
/// (x of its width, y of its height, from the top left), like `Crop`.
///
/// Every result is a crop `Crop.validated` accepts for `photo`: inside the photo, the panel's
/// shape, at most the centred crop and at least `minimumWidth` wide. Whatever a gesture asks
/// for is clamped to that, never refused.
public struct CropGeometry: Sendable, Hashable {
    public enum Corner: CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight

        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }

        /// The corner diagonally across, which stays put while this one is dragged.
        public var opposite: Corner {
            switch self {
            case .topLeft: .bottomRight
            case .topRight: .bottomLeft
            case .bottomLeft: .topRight
            case .bottomRight: .topLeft
            }
        }
    }

    /// An arrow key.
    public enum Direction: CaseIterable, Sendable {
        case left, right, up, down
    }

    /// The photo after EXIF orientation and the 4K cap (`DecodedPhoto.size`).
    public let photo: PhotoSize
    /// The frame now.
    public private(set) var crop: Crop
    /// What Fill shows without a crop, and the largest frame.
    public let centred: Crop
    /// The narrowest frame, as a fraction of the photo's width (`Crop.minimumWidth`); the
    /// centred crop's width when that is already at the floor.
    public let minimumWidth: Double

    /// What an arrow key moves the frame, as a fraction of the photo: 1 %, with Shift 10 %.
    public static let nudge = 0.01
    public static let largeNudge = 0.1
    /// How much one step of `zoomedIn` / `zoomedOut` (VoiceOver) zooms.
    public static let zoomStep = 1.25
    /// Two crops this close in every value are the same (floating-point noise of zooming
    /// in and out again).
    static let tolerance = 1e-9

    /// The editor for `crop` of a `photo`-sized photo; nil, or a crop that does not suit the
    /// photo, starts at the centred crop.
    public init(photo: PhotoSize, crop: Crop? = nil) {
        precondition(photo.width > 0 && photo.height > 0, "a photo has pixels")
        self.photo = photo
        let centred = Crop.centred(width: photo.width, height: photo.height)
        self.centred = centred
        let floor = Crop.minimumWidth(width: photo.width, height: photo.height)
        // Under the floor already, the floor is the centred width give or take rounding.
        minimumWidth = floor >= centred.width * (1 - Self.tolerance) ? centred.width : floor
        if let crop, (try? crop.validated(width: photo.width, height: photo.height)) != nil {
            self.crop = crop
        } else {
            self.crop = centred
        }
    }

    // MARK: state

    /// What OK stores: nil (the default) for the centred crop, else the frame.
    public var result: Crop? { isCentred ? nil : crop }

    /// The frame is the centred crop, give or take floating-point noise.
    public var isCentred: Bool {
        abs(crop.left - centred.left) <= Self.tolerance && abs(crop.top - centred.top) <= Self.tolerance
            && abs(crop.width - centred.width) <= Self.tolerance && abs(crop.height - centred.height) <= Self.tolerance
    }

    /// How far the frame is zoomed in: 1 for the centred crop's size, up to `maximumZoom`.
    public var zoom: Double { centred.width / crop.width }
    public var maximumZoom: Double { centred.width / minimumWidth }
    /// False for a photo whose centred crop is already the smallest allowed.
    public var canZoom: Bool { minimumWidth < centred.width }

    /// The frame's centre.
    public var centre: CGPoint { CGPoint(x: crop.left + crop.width / 2, y: crop.top + crop.height / 2) }

    /// Where `corner` of the frame is.
    public func point(of corner: Corner) -> CGPoint {
        CGPoint(x: corner.isLeft ? crop.left : crop.left + crop.width,
                y: corner.isTop ? crop.top : crop.top + crop.height)
    }

    // MARK: changes

    /// Back to the centred crop (OK then stores nil).
    public func reset() -> CropGeometry {
        var reset = self
        reset.crop = centred
        return reset
    }

    /// The frame moved by `dx` of the photo's width and `dy` of its height, up to the edges.
    public func moved(dx: Double, dy: Double) -> CropGeometry {
        placed(left: crop.left + dx, top: crop.top + dy, width: crop.width, height: crop.height)
    }

    /// An arrow key: `nudge` of the photo that way, `largeNudge` with Shift.
    public func nudged(_ direction: Direction, large: Bool = false) -> CropGeometry {
        let step = large ? Self.largeNudge : Self.nudge
        return switch direction {
        case .left: moved(dx: -step, dy: 0)
        case .right: moved(dx: step, dy: 0)
        case .up: moved(dx: 0, dy: -step)
        case .down: moved(dx: 0, dy: step)
        }
    }

    /// `corner` dragged to `target` while the opposite corner stays put: the frame's
    /// diagonal follows the pointer (projected onto it, in photo pixels), clamped between
    /// the minimum size, the centred crop's size and the photo's edges.
    public func resized(_ corner: Corner, to target: CGPoint) -> CropGeometry {
        let anchor = point(of: corner.opposite)
        let w = Double(photo.width), h = Double(photo.height)
        // How far the pointer is beyond the anchor in the corner's direction, in photo pixels.
        let along = max(0, (corner.isLeft ? anchor.x - target.x : target.x - anchor.x) * w)
        let down = max(0, (corner.isTop ? anchor.y - target.y : target.y - anchor.y) * h)
        let aspect = Double(Frame.width) / Double(Frame.height)
        let heightPx = (aspect * along + down) / (aspect * aspect + 1)
        // Room between the anchor and the photo's edges, as widths.
        let roomX = corner.isLeft ? anchor.x : 1 - anchor.x
        let roomY = width(forHeight: corner.isTop ? anchor.y : 1 - anchor.y)
        let width = clampedWidth(min(aspect * heightPx / w, roomX, roomY))
        let height = height(forWidth: width)
        return placed(left: corner.isLeft ? anchor.x - width : anchor.x,
                      top: corner.isTop ? anchor.y - height : anchor.y, width: width, height: height)
    }

    /// `corner` of the frame moved by `dx`, `dy` (a corner handle dragged from where it was).
    public func dragged(_ corner: Corner, dx: Double, dy: Double) -> CropGeometry {
        let start = point(of: corner)
        return resized(corner, to: CGPoint(x: start.x + dx, y: start.y + dy))
    }

    /// Zoomed in `factor` times (below 1: out) about `anchor`, which keeps its place in the
    /// frame (a point outside the frame counts as the nearest point inside it).
    public func zoomed(by factor: Double, about anchor: CGPoint) -> CropGeometry {
        guard factor.isFinite, factor > 0 else { return self }
        return scaled(toWidth: crop.width / factor, about: anchor)
    }

    /// Zoomed to `zoom` (1 = the centred crop's size, see `zoom`) about `anchor`.
    public func zoomed(to zoom: Double, about anchor: CGPoint) -> CropGeometry {
        guard zoom.isFinite, zoom > 0 else { return self }
        return scaled(toWidth: centred.width / zoom, about: anchor)
    }

    /// One `zoomStep` in or out about the frame's centre (VoiceOver's adjust actions).
    public func zoomedIn() -> CropGeometry { zoomed(by: Self.zoomStep, about: centre) }
    public func zoomedOut() -> CropGeometry { zoomed(by: 1 / Self.zoomStep, about: centre) }

    /// The zoom factor for a scroll of `delta` (positive: away from the user, which zooms
    /// in): points from a trackpad (`precise`), else lines of a mouse wheel, 10 % a line.
    public static func zoomFactor(scrolled delta: Double, precise: Bool) -> Double {
        guard delta.isFinite else { return 1 }
        return exp((precise ? delta : delta * 10) * 0.01)
    }

    // MARK: helpers

    private func scaled(toWidth width: Double, about anchor: CGPoint) -> CropGeometry {
        let width = clampedWidth(width), height = height(forWidth: width)
        let x = min(max(anchor.x, crop.left), crop.left + crop.width)
        let y = min(max(anchor.y, crop.top), crop.top + crop.height)
        return placed(left: x - (x - crop.left) * (width / crop.width),
                      top: y - (y - crop.top) * (height / crop.height), width: width, height: height)
    }

    /// Between `minimumWidth` and the centred crop's width (NaN: the centred width).
    private func clampedWidth(_ width: Double) -> Double {
        guard !width.isNaN else { return centred.width }
        return max(min(width, centred.width), minimumWidth)
    }

    /// The height that gives a `width`-wide frame the panel's shape; the centred crop's own
    /// height at its width, so zooming all the way out gives exactly the centred crop.
    private func height(forWidth width: Double) -> Double {
        if width >= centred.width { return centred.height }
        return width * Double(photo.width) * Double(Frame.height) / Double(Frame.width) / Double(photo.height)
    }

    private func width(forHeight height: Double) -> Double {
        height * Double(photo.height) * Double(Frame.width) / Double(Frame.height) / Double(photo.width)
    }

    /// The frame at `left`, `top`, pushed back inside the photo where it reaches out.
    private func placed(left: Double, top: Double, width: Double, height: Double) -> CropGeometry {
        var placed = self
        placed.crop = Crop(left: Self.clamp(left, size: width), top: Self.clamp(top, size: height),
                           width: width, height: height)
        return placed
    }

    /// `start` of a span `size` long, inside 0-1; at 0 when `size` is (by rounding) over 1.
    private static func clamp(_ start: Double, size: Double) -> Double {
        guard start.isFinite else { return 0 }
        return max(0, min(start, 1 - size))
    }
}

/// Where the crop editor draws the photo and the frame in a view of `size` points: the photo
/// scaled to fit, centred, `inset` points from the edges (room for the corner handles).
public struct CropCanvas: Sendable, Hashable {
    /// What a click or a drag starts on.
    public enum Hit: Sendable, Hashable {
        /// A corner handle: the drag resizes.
        case corner(CropGeometry.Corner)
        /// Inside the frame: the drag moves it.
        case inside
        case outside
    }

    /// The photo's place in the view.
    public let imageFrame: CGRect

    public init(photo: PhotoSize, size: CGSize, inset: CGFloat = 12) {
        let room = CGSize(width: max(0, size.width - 2 * inset), height: max(0, size.height - 2 * inset))
        let scale = min(room.width / CGFloat(photo.width), room.height / CGFloat(photo.height))
        let width = CGFloat(photo.width) * scale, height = CGFloat(photo.height) * scale
        imageFrame = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    /// `crop` in view points.
    public func rect(of crop: Crop) -> CGRect {
        CGRect(x: imageFrame.minX + crop.left * imageFrame.width, y: imageFrame.minY + crop.top * imageFrame.height,
               width: crop.width * imageFrame.width, height: crop.height * imageFrame.height)
    }

    /// The point of the photo (fractions) under view point `point`, not clamped.
    public func fraction(at point: CGPoint) -> CGPoint {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: (point.x - imageFrame.minX) / imageFrame.width,
                       y: (point.y - imageFrame.minY) / imageFrame.height)
    }

    /// A drag of `translation` points, as fractions of the photo.
    public func fractions(of translation: CGSize) -> CGSize {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return .zero }
        return CGSize(width: translation.width / imageFrame.width, height: translation.height / imageFrame.height)
    }

    /// What `point` is on: the nearest corner handle within `handle` points (less on a small
    /// frame, so its middle still moves it), else inside the frame or not.
    public func hit(_ point: CGPoint, crop: Crop, handle: CGFloat = 12) -> Hit {
        let frame = rect(of: crop)
        let reach = min(handle, min(frame.width, frame.height) / 3)
        let corners = CropGeometry.Corner.allCases.map { corner in
            (corner, CGPoint(x: corner.isLeft ? frame.minX : frame.maxX, y: corner.isTop ? frame.minY : frame.maxY))
        }
        let near = corners
            .filter { abs($0.1.x - point.x) <= reach && abs($0.1.y - point.y) <= reach }
            .min { hypot($0.1.x - point.x, $0.1.y - point.y) < hypot($1.1.x - point.x, $1.1.y - point.y) }
        if let near { return .corner(near.0) }
        return frame.contains(point) ? .inside : .outside
    }
}
