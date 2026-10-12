import CoreGraphics
import Foundation
import Testing
import UlaniKit
@testable import PaperhueUI

/// Photo sizes (after the 4K cap) the editor must handle: ordinary, exactly 5:3, panoramas
/// and tall photos up to the cap's extremes, and photos too small to zoom at all.
private let sizes: [PhotoSize] = [
    PhotoSize(width: 1200, height: 900), PhotoSize(width: 900, height: 1600), PhotoSize(width: 1000, height: 600),
    PhotoSize(width: 3840, height: 2160), PhotoSize(width: 2160, height: 3840), PhotoSize(width: 1201, height: 899),
    PhotoSize(width: 3840, height: 480), PhotoSize(width: 480, height: 3840), PhotoSize(width: 3840, height: 1536),
    PhotoSize(width: 3840, height: 38), PhotoSize(width: 38, height: 3840), PhotoSize(width: 3840, height: 1),
    PhotoSize(width: 1, height: 3840), PhotoSize(width: 150, height: 90), PhotoSize(width: 160, height: 100),
    PhotoSize(width: 1, height: 1), PhotoSize(width: 167, height: 100),
]

/// The core accepts the frame (`Crop.validated`), and it has the panel's shape far closer
/// than the core's one pixel.
private func expectValid(_ geometry: CropGeometry, _ comment: String = "",
                         sourceLocation: SourceLocation = #_sourceLocation) {
    let crop = geometry.crop, photo = geometry.photo
    #expect(throws: Never.self, "\(photo) \(crop) \(comment)", sourceLocation: sourceLocation) {
        try crop.validated(width: photo.width, height: photo.height)
    }
    #expect(shapeError(geometry) < 1e-6, "\(photo) \(crop) \(comment)", sourceLocation: sourceLocation)
    #expect(crop.left >= 0 && crop.top >= 0 && crop.left + crop.width <= 1 + 1e-12 && crop.top + crop.height <= 1 + 1e-12,
            "\(photo) \(crop) \(comment)", sourceLocation: sourceLocation)
    #expect(crop.width >= geometry.minimumWidth && crop.width <= geometry.centred.width,
            "\(photo) \(crop) \(comment)", sourceLocation: sourceLocation)
}

/// How far the frame is from the panel's shape, in photo pixels of width.
private func shapeError(_ geometry: CropGeometry) -> Double {
    let crop = geometry.crop, photo = geometry.photo
    return abs(crop.width * Double(photo.width) - crop.height * Double(photo.height) * 800 / 480)
}

/// Every value within `tolerance`.
private func close(_ a: Crop, _ b: Crop, _ tolerance: Double = 1e-12) -> Bool {
    abs(a.left - b.left) <= tolerance && abs(a.top - b.top) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

/// A repeatable random sequence (SplitMix64).
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct CropGeometryTests {
    let photo = PhotoSize(width: 1200, height: 900)

    /// 1200x900 zoomed 2x about the middle: room to move every way.
    var zoomed: CropGeometry { CropGeometry(photo: photo).zoomed(to: 2, about: CGPoint(x: 0.5, y: 0.5)) }

    // MARK: start

    @Test(arguments: sizes)
    func startsAtTheCentredCrop(photo: PhotoSize) {
        let geometry = CropGeometry(photo: photo)
        #expect(geometry.crop == Crop.centred(width: photo.width, height: photo.height))
        #expect(geometry.centred == geometry.crop && geometry.isCentred && geometry.result == nil)
        #expect(geometry.zoom == 1)
        expectValid(geometry)
    }

    @Test func startsAtAGivenCropThatSuitsThePhoto() {
        let crop = zoomed.moved(dx: 0.1, dy: 0.05).crop
        let geometry = CropGeometry(photo: photo, crop: crop)
        #expect(geometry.crop == crop && geometry.result == crop && !geometry.isCentred)
        #expect(abs(geometry.zoom - 2) < 1e-12)
        // One that does not suit it (wrong shape, too small, outside): the centred crop.
        for bad in [Crop(left: 0, top: 0, width: 0.5, height: 0.5), Crop(left: 0.4, top: 0.4, width: 0.05, height: 0.04),
                    Crop(left: 0.6, top: 0.1, width: 0.5, height: 0.4)] {
            #expect(CropGeometry(photo: photo, crop: bad).crop == geometry.centred, "\(bad)")
        }
    }

    // MARK: limits

    @Test(arguments: sizes)
    func zoomStopsAtTheCoresMinimum(photo: PhotoSize) {
        let geometry = CropGeometry(photo: photo)
        let floor = Crop.minimumWidth(width: photo.width, height: photo.height)
        #expect(abs(geometry.minimumWidth - floor) < 1e-12)
        #expect(geometry.maximumZoom >= 1 && geometry.maximumZoom <= Double(Crop.maximumZoom) + 1e-9)
        let deepest = geometry.zoomed(by: 1000, about: CGPoint(x: 0.3, y: 0.6))
        #expect(deepest.crop.width == geometry.minimumWidth)
        #expect(abs(deepest.zoom - geometry.maximumZoom) < 1e-9)
        expectValid(deepest)
        // Zooming out never goes past the centred crop's size.
        let widest = deepest.zoomed(by: 1e-6, about: CGPoint(x: 0.9, y: 0.1))
        #expect(widest.crop.width == geometry.centred.width && widest.crop.height == geometry.centred.height)
        expectValid(widest)
    }

    /// A photo whose centred crop is already under 100 photo pixels high allows no zoom: every
    /// change keeps the centred crop's size.
    @Test(arguments: [PhotoSize(width: 150, height: 90), PhotoSize(width: 160, height: 100),
                      PhotoSize(width: 3840, height: 38), PhotoSize(width: 38, height: 3840), PhotoSize(width: 1, height: 1),
                      PhotoSize(width: 3840, height: 1), PhotoSize(width: 167, height: 100)])
    func tinyPhotosCannotZoom(photo: PhotoSize) {
        let geometry = CropGeometry(photo: photo)
        #expect(!geometry.canZoom && geometry.maximumZoom == 1 && geometry.minimumWidth == geometry.centred.width)
        let changed = [
            geometry.zoomed(by: 4, about: CGPoint(x: 0.2, y: 0.2)), geometry.zoomed(to: 8, about: geometry.centre),
            geometry.zoomedIn(), geometry.resized(.bottomRight, to: CGPoint(x: 0.5, y: 0.5)),
            geometry.dragged(.topLeft, dx: 0.3, dy: 0.3),
        ]
        for result in changed {
            #expect(result.crop.width == geometry.centred.width && result.crop.height == geometry.centred.height)
            expectValid(result)
        }
    }

    @Test func zoomCanBeSetDirectlyAndIsClamped() {
        let geometry = CropGeometry(photo: photo)
        #expect(abs(geometry.zoomed(to: 3, about: geometry.centre).zoom - 3) < 1e-12)
        #expect(geometry.zoomed(to: 0.5, about: geometry.centre).isCentred)
        #expect(abs(geometry.zoomed(to: 100, about: geometry.centre).zoom - geometry.maximumZoom) < 1e-12)
        for bad in [0, -1, .nan, .infinity] {
            #expect(geometry.zoomed(to: bad, about: geometry.centre) == geometry)
            #expect(geometry.zoomed(by: bad, about: geometry.centre) == geometry)
        }
        // 1200x900: at least 100 px high, so 1/7.2 of the centred crop's width.
        #expect(abs(geometry.maximumZoom - 7.2) < 1e-12)
    }

    // MARK: move and nudge

    @Test func moveFollowsTheDragInsideThePhoto() {
        let start = zoomed
        let moved = start.moved(dx: 0.05, dy: -0.02)
        #expect(moved.crop.left == start.crop.left + 0.05 && moved.crop.top == start.crop.top - 0.02)
        #expect(moved.crop.width == start.crop.width && moved.crop.height == start.crop.height)
        expectValid(moved)
    }

    @Test func moveStopsAtEveryEdgeAndCorner() {
        let start = zoomed
        let (w, h) = (start.crop.width, start.crop.height)
        let cases: [(dx: Double, dy: Double, left: Double, top: Double)] = [
            (-5, 0, 0, start.crop.top), (5, 0, 1 - w, start.crop.top), (0, -5, start.crop.left, 0), (0, 5, start.crop.left, 1 - h),
            (-5, -5, 0, 0), (5, -5, 1 - w, 0), (-5, 5, 0, 1 - h), (5, 5, 1 - w, 1 - h),
        ]
        for c in cases {
            let moved = start.moved(dx: c.dx, dy: c.dy)
            #expect(moved.crop == Crop(left: c.left, top: c.top, width: w, height: h), "\(c)")
            expectValid(moved)
        }
    }

    @Test func aPanoramaMovesOnlySidewaysATallPhotoOnlyUpAndDown() {
        let wide = CropGeometry(photo: PhotoSize(width: 3840, height: 480))
        #expect(wide.crop.top == 0 && wide.crop.height == 1)
        #expect(wide.moved(dx: 0, dy: 0.3).crop == wide.crop)
        #expect(wide.moved(dx: -1, dy: -1).crop.left == 0)
        #expect(abs(wide.moved(dx: 1, dy: 1).crop.left + wide.crop.width - 1) < 1e-12)

        let tall = CropGeometry(photo: PhotoSize(width: 480, height: 3840))
        #expect(tall.crop.left == 0 && tall.crop.width == 1)
        #expect(tall.moved(dx: 0.3, dy: 0).crop == tall.crop)
        #expect(tall.moved(dx: 0, dy: -1).crop.top == 0)
        #expect(abs(tall.moved(dx: 0, dy: 1).crop.top + tall.crop.height - 1) < 1e-12)
        expectValid(tall.moved(dx: 0, dy: 1))
    }

    @Test func arrowKeysNudgeOnePercentOrTenWithShift() {
        let start = zoomed
        let (left, top) = (start.crop.left, start.crop.top)
        #expect(start.nudged(.right).crop.left == left + 0.01)
        #expect(start.nudged(.left).crop.left == left - 0.01)
        #expect(start.nudged(.down).crop.top == top + 0.01)
        #expect(start.nudged(.up).crop.top == top - 0.01)
        #expect(start.nudged(.right, large: true).crop.left == left + 0.1)
        #expect(start.nudged(.up, large: true).crop.top == top - 0.1)
        #expect(start.nudged(.left).crop.top == top && start.nudged(.up).crop.left == left)
        // At an edge, up to it and no further.
        var edge = start
        for _ in 0..<10 { edge = edge.nudged(.left, large: true) }
        #expect(edge.crop.left == 0 && edge.nudged(.left).crop.left == 0)
        expectValid(edge)
    }

    // MARK: corner handles

    @Test(arguments: CropGeometry.Corner.allCases)
    func aCornerResizesAboutTheOppositeOne(corner: CropGeometry.Corner) {
        let start = zoomed
        let anchor = start.point(of: corner.opposite)
        for (dx, dy) in [(0.05, 0.05), (-0.05, -0.04), (0.08, -0.01), (-0.02, 0.06), (0.0, 0.0), (0.03, 0.0)] {
            let resized = start.dragged(corner, dx: dx, dy: dy)
            let kept = resized.point(of: corner.opposite)
            #expect(abs(kept.x - anchor.x) < 1e-12 && abs(kept.y - anchor.y) < 1e-12, "\(corner) \(dx) \(dy)")
            expectValid(resized, "\(corner) \(dx) \(dy)")
        }
        // Dragged straight along the diagonal, the corner lands where it was dragged.
        let corner0 = start.point(of: corner)
        let outward = CGPoint(x: corner0.x + (corner0.x - anchor.x) * 0.2, y: corner0.y + (corner0.y - anchor.y) * 0.2)
        let grown = start.resized(corner, to: outward)
        #expect(abs(grown.point(of: corner).x - outward.x) < 1e-12 && abs(grown.point(of: corner).y - outward.y) < 1e-12)
        #expect(abs(grown.crop.width - start.crop.width * 1.2) < 1e-12)
    }

    @Test(arguments: CropGeometry.Corner.allCases)
    func aCornerStopsAtThePhotoTheMinimumAndTheCentredSize(corner: CropGeometry.Corner) {
        let start = zoomed.moved(dx: 0.12, dy: -0.07)
        let anchor = start.point(of: corner.opposite)
        // Far out: up to the photo's edge on the corner's side, the anchor kept.
        let far = start.dragged(corner, dx: corner.isLeft ? -3 : 3, dy: corner.isTop ? -3 : 3)
        let kept = far.point(of: corner.opposite)
        #expect(abs(kept.x - anchor.x) < 1e-12 && abs(kept.y - anchor.y) < 1e-12)
        let reached = far.point(of: corner)
        #expect(abs(reached.x - (corner.isLeft ? 0 : 1)) < 1e-12 || abs(reached.y - (corner.isTop ? 0 : 1)) < 1e-12)
        expectValid(far)
        // Past the opposite corner: the minimum size.
        let past = start.dragged(corner, dx: corner.isLeft ? 3 : -3, dy: corner.isTop ? 3 : -3)
        #expect(past.crop.width == start.minimumWidth)
        expectValid(past)
        // From a corner of the photo, out to the opposite corner: the centred crop's size.
        let fromCorner = zoomed.moved(dx: corner.isLeft ? 5 : -5, dy: corner.isTop ? 5 : -5)
        let biggest = fromCorner.dragged(corner, dx: corner.isLeft ? -3 : 3, dy: corner.isTop ? -3 : 3)
        #expect(biggest.crop.width == biggest.centred.width && biggest.crop.height == biggest.centred.height)
        expectValid(biggest)
    }

    // MARK: zoom

    @Test func zoomKeepsTheAnchorWhereItIsInTheFrame() {
        let start = zoomed
        let anchor = CGPoint(x: start.crop.left + start.crop.width * 0.3, y: start.crop.top + start.crop.height * 0.8)
        for factor in [1.5, 0.7, 1.01] {
            let result = start.zoomed(by: factor, about: anchor)
            #expect(abs(result.crop.width - start.crop.width / factor) < 1e-12)
            #expect(abs((anchor.x - result.crop.left) / result.crop.width - 0.3) < 1e-9)
            #expect(abs((anchor.y - result.crop.top) / result.crop.height - 0.8) < 1e-9)
            expectValid(result)
        }
        // A point outside the frame counts as the nearest point on its edge.
        let outside = start.zoomed(by: 1.5, about: CGPoint(x: -1, y: start.centre.y))
        #expect(abs(outside.crop.left - start.crop.left) < 1e-12)
    }

    @Test(arguments: sizes)
    func zoomingInAndOutAgainReturnsToTheSameFrame(photo: PhotoSize) {
        let start = CropGeometry(photo: photo)
        let moved = start.zoomed(to: min(2, start.maximumZoom), about: start.centre).moved(dx: 0.01, dy: -0.01)
        // The anchor keeps its place in the frame, so even a zoom held back by a limit comes
        // back to the same frame.
        for (from, factor) in [(start, 1.37), (start, 50), (moved, 1.1), (moved, 1 / 1.1)] {
            let anchor = CGPoint(x: from.crop.left + from.crop.width * 0.6, y: from.crop.top + from.crop.height * 0.25)
            var geometry = from
            for _ in 0..<100 {
                geometry = geometry.zoomed(by: factor, about: anchor).zoomed(by: 1 / factor, about: anchor)
                expectValid(geometry)
            }
            #expect(close(geometry.crop, from.crop, 1e-9), "\(photo) \(factor): \(geometry.crop) \(from.crop)")
        }
        // All the way in and out again: the centred crop, which OK stores as nil.
        var geometry = start
        for _ in 0..<20 { geometry = geometry.zoomedIn() }
        for _ in 0..<40 { geometry = geometry.zoomedOut() }
        #expect(geometry.isCentred && geometry.result == nil, "\(photo)")
    }

    @Test func scrollingZoomsInAwayFromTheUser() {
        #expect(CropGeometry.zoomFactor(scrolled: 0, precise: true) == 1)
        #expect(CropGeometry.zoomFactor(scrolled: 10, precise: true) > 1)
        #expect(CropGeometry.zoomFactor(scrolled: -10, precise: true) < 1)
        // A wheel's line is ten trackpad points: about 10 %.
        #expect(CropGeometry.zoomFactor(scrolled: 1, precise: false) == CropGeometry.zoomFactor(scrolled: 10, precise: true))
        #expect(abs(CropGeometry.zoomFactor(scrolled: 1, precise: false) - 1.105) < 0.001)
        #expect(CropGeometry.zoomFactor(scrolled: .nan, precise: true) == 1)
        let zoomed = self.zoomed
        let factor = CropGeometry.zoomFactor(scrolled: 3, precise: false)
        let anchor = zoomed.centre
        #expect(close(zoomed.zoomed(by: factor, about: anchor).zoomed(by: 1 / factor, about: anchor).crop, zoomed.crop, 1e-9))
    }

    // MARK: reset and result

    @Test func resetGoesBackToTheCentredCrop() {
        let edited = zoomed.moved(dx: 0.2, dy: 0.1)
        #expect(edited.result == edited.crop)
        let reset = edited.reset()
        #expect(reset.crop == reset.centred && reset.isCentred && reset.result == nil)
        // Noise left from zooming in and out counts as centred.
        let noisy = CropGeometry(photo: photo, crop: Crop(left: 1e-12, top: 0.1 + 1e-12, width: 1 - 1e-12, height: 0.8))
        #expect(noisy.crop != noisy.centred && noisy.result == nil)
    }

    // MARK: everything at random

    /// Thousands of random moves, nudges, corner drags, zooms and resets on every size: the
    /// core accepts every frame.
    @Test(arguments: sizes)
    func everyChangeGivesACropTheCoreAccepts(photo: PhotoSize) {
        var random = SeededGenerator(state: UInt64(photo.width * 7919 + photo.height))
        var geometry = CropGeometry(photo: photo)
        func point() -> CGPoint {
            CGPoint(x: Double.random(in: -0.5...1.5, using: &random), y: Double.random(in: -0.5...1.5, using: &random))
        }
        for step in 0..<1500 {
            switch Int.random(in: 0..<8, using: &random) {
            case 0: geometry = geometry.moved(dx: .random(in: -1.5...1.5, using: &random), dy: .random(in: -1.5...1.5, using: &random))
            case 1: geometry = geometry.nudged(CropGeometry.Direction.allCases.randomElement(using: &random)!, large: .random(using: &random))
            case 2: geometry = geometry.resized(CropGeometry.Corner.allCases.randomElement(using: &random)!, to: point())
            case 3: geometry = geometry.dragged(CropGeometry.Corner.allCases.randomElement(using: &random)!,
                                                dx: .random(in: -0.3...0.3, using: &random), dy: .random(in: -0.3...0.3, using: &random))
            case 4: geometry = geometry.zoomed(by: exp(.random(in: -3...3, using: &random)), about: point())
            case 5: geometry = geometry.zoomed(to: .random(in: 0.5...10, using: &random), about: point())
            case 6: geometry = Bool.random(using: &random) ? geometry.zoomedIn() : geometry.zoomedOut()
            default: geometry = Int.random(in: 0..<10, using: &random) == 0 ? geometry.reset() : geometry
            }
            expectValid(geometry, "step \(step)")
            if (try? geometry.crop.validated(width: photo.width, height: photo.height)) == nil { break }
        }
    }
}

/// Every coordinate within 1e-9 points.
private func near(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9 && abs(a.width - b.width) < 1e-9
        && abs(a.height - b.height) < 1e-9
}

@Suite struct CropCanvasTests {
    @Test func thePhotoIsScaledToFitAndCentred() {
        // 616x396 inside the insets: 1200x900 fits its height (0.44 points a pixel).
        let canvas = CropCanvas(photo: PhotoSize(width: 1200, height: 900), size: CGSize(width: 640, height: 420), inset: 12)
        #expect(near(canvas.imageFrame, CGRect(x: 56, y: 12, width: 528, height: 396)))
        // A panorama fits its width.
        let wide = CropCanvas(photo: PhotoSize(width: 3840, height: 480), size: CGSize(width: 640, height: 420), inset: 12)
        #expect(abs(wide.imageFrame.width - 616) < 1e-9 && abs(wide.imageFrame.height - 77) < 1e-9)
        #expect(abs(wide.imageFrame.minX - 12) < 1e-9 && abs(wide.imageFrame.midY - 210) < 1e-9)
        // No room: nothing to map, nothing breaks.
        let none = CropCanvas(photo: PhotoSize(width: 1200, height: 900), size: .zero)
        #expect(none.fraction(at: CGPoint(x: 3, y: 3)) == CGPoint(x: 0.5, y: 0.5))
        #expect(none.fractions(of: CGSize(width: 5, height: 5)) == .zero)
    }

    @Test func pointsAndFractionsMapBothWays() {
        let canvas = CropCanvas(photo: PhotoSize(width: 1200, height: 900), size: CGSize(width: 640, height: 420), inset: 12)
        let crop = Crop(left: 0.25, top: 0.5, width: 0.5, height: 0.4)
        let rect = canvas.rect(of: crop)
        #expect(near(rect, CGRect(x: 56 + 132, y: 12 + 198, width: 264, height: 158.4)))
        let topLeft = canvas.fraction(at: rect.origin), bottomRight = canvas.fraction(at: CGPoint(x: rect.maxX, y: rect.maxY))
        #expect(abs(topLeft.x - 0.25) < 1e-12 && abs(topLeft.y - 0.5) < 1e-12)
        #expect(abs(bottomRight.x - 0.75) < 1e-12 && abs(bottomRight.y - 0.9) < 1e-12)
        let step = canvas.fractions(of: CGSize(width: 52.8, height: -39.6))
        #expect(abs(step.width - 0.1) < 1e-12 && abs(step.height + 0.1) < 1e-12)
        // Outside the photo: fractions outside 0-1 (the geometry clamps).
        #expect(canvas.fraction(at: CGPoint(x: 0, y: 0)).x < 0)
    }

    @Test func aPressStartsOnAHandleInsideTheFrameOrOutside() {
        let canvas = CropCanvas(photo: PhotoSize(width: 1200, height: 900), size: CGSize(width: 640, height: 420), inset: 12)
        let crop = Crop(left: 0.25, top: 0.5, width: 0.5, height: 0.4)
        let rect = canvas.rect(of: crop)  // 188, 210, 264 x 158.4
        #expect(canvas.hit(CGPoint(x: rect.minX + 3, y: rect.minY - 4), crop: crop) == .corner(.topLeft))
        #expect(canvas.hit(CGPoint(x: rect.maxX - 10, y: rect.minY + 10), crop: crop) == .corner(.topRight))
        #expect(canvas.hit(CGPoint(x: rect.minX, y: rect.maxY), crop: crop) == .corner(.bottomLeft))
        #expect(canvas.hit(CGPoint(x: rect.maxX + 12, y: rect.maxY + 12), crop: crop) == .corner(.bottomRight))
        #expect(canvas.hit(CGPoint(x: rect.midX, y: rect.midY), crop: crop) == .inside)
        #expect(canvas.hit(CGPoint(x: rect.minX + 20, y: rect.midY), crop: crop) == .inside)
        #expect(canvas.hit(CGPoint(x: rect.maxX + 13, y: rect.maxY + 13), crop: crop) == .outside)
        #expect(canvas.hit(CGPoint(x: 60, y: 20), crop: crop) == .outside)
        // A small frame keeps its middle for moving: handles reach a third of its size.
        let small = Crop(left: 0.5, top: 0.5, width: 0.04, height: 0.032)  // 21.1 x 12.7 points
        let smallRect = canvas.rect(of: small)
        #expect(canvas.hit(CGPoint(x: smallRect.midX, y: smallRect.midY), crop: small) == .inside)
        #expect(canvas.hit(CGPoint(x: smallRect.minX + 1, y: smallRect.minY + 1), crop: small) == .corner(.topLeft))
    }
}
