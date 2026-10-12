import Foundation
import Testing
@testable import UlaniKit

/// shared/vectors/crop-vectors.json: the crop maths every implementation must match.
private struct CropVectors: Decodable, Sendable {
    struct Case: Decodable, Sendable {
        let photo: [Int]
        let name: String
        let crop: [Double]
        let box: [Int]
    }

    struct BoxCase: Decodable, Sendable {
        let size: [Int]
        let crop: [Double]
        let box: [Int]
    }

    struct Invalid: Decodable, Sendable {
        let photo: [Int]
        let crop: [Double]
        let name: String
        /// Python's message; ours need not be the same.
        let reason: String
    }

    let version: Int
    let screen: [Int]
    let minCropPx: Int
    let maxZoom: Int
    let crops: [Case]
    let boxes: [BoxCase]
    let invalid: [Invalid]

    /// <repo>/shared/vectors/crop-vectors.json: this file's directory, up 4 directories.
    static let url: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/UlaniKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // UlaniKit
        .deletingLastPathComponent()  // apple
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("shared/vectors/crop-vectors.json")

    static let loaded = Swift.Result<CropVectors, any Error> {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CropVectors.self, from: Data(contentsOf: url))
    }
}

private extension Crop {
    init(_ values: [Double]) {
        precondition(values.count == 4, "a crop is four numbers")
        self.init(left: values[0], top: values[1], width: values[2], height: values[3])
    }

    var values: [Double] { [left, top, width, height] }
}

private extension Crop.Box {
    var values: [Int] { [x0, y0, x1, y1] }
}

@Suite struct CropTests {
    // MARK: shared vectors

    @Test func constantsMatch() throws {
        let vectors = try CropVectors.loaded.get()
        #expect(vectors.version == 1)
        #expect(vectors.screen == [Frame.width, Frame.height])
        #expect(vectors.minCropPx == Crop.minimumHeight)
        #expect(vectors.maxZoom == Crop.maximumZoom)
    }

    @Test func everyCropIsValidAndHasItsBox() throws {
        let vectors = try CropVectors.loaded.get()
        #expect(vectors.crops.count >= 20)
        for c in vectors.crops {
            let crop = Crop(c.crop)
            let checked = try crop.validated(width: c.photo[0], height: c.photo[1])
            #expect(checked == crop, "\(c.photo) \(c.name)")
            #expect(crop.box(width: c.photo[0], height: c.photo[1]).values == c.box, "\(c.photo) \(c.name)")
        }
    }

    @Test func defaultCropsAreTheCentredCrop() throws {
        // The same doubles, bit for bit, as Python's default_crop; and the other named
        // crops are built from it as the vector generator does.
        let vectors = try CropVectors.loaded.get()
        var named = Set<String>()
        for c in vectors.crops {
            let centred = Crop.centred(width: c.photo[0], height: c.photo[1])
            let (w, h) = (centred.width, centred.height)
            let expected: Crop? = switch c.name {
            case "default": centred
            case "top-left": Crop(left: 0, top: 0, width: w, height: h)
            case "bottom-right": Crop(left: 1 - w, top: 1 - h, width: w, height: h)
            case "4x zoom centre": Crop(left: 0.5 - w / 4 / 2, top: 0.5 - h / 4 / 2, width: w / 4, height: h / 4)
            default: nil
            }
            #expect(expected?.values == c.crop, "\(c.photo) \(c.name)")
            named.insert(c.name)
        }
        #expect(named == ["default", "top-left", "bottom-right", "4x zoom centre"])
    }

    @Test func boxesRoundHalfUp() throws {
        let vectors = try CropVectors.loaded.get()
        #expect(!vectors.boxes.isEmpty)
        for c in vectors.boxes {
            #expect(Crop(c.crop).box(width: c.size[0], height: c.size[1]).values == c.box, "\(c.size) \(c.crop)")
        }
        // 0.25 * 1002 = 250.5: up to 251, where rounding half to even gives 250.
        #expect(vectors.boxes[0].box[0] == 251)
    }

    @Test func everyInvalidCropIsRejected() throws {
        let vectors = try CropVectors.loaded.get()
        #expect(vectors.invalid.count >= 5)
        for c in vectors.invalid {
            #expect(throws: CropError.self, "\(c.photo) \(c.name)") {
                try Crop(c.crop).validated(width: c.photo[0], height: c.photo[1])
            }
        }
    }

    // MARK: rules

    @Test func centredCropIsTheLargestWithThePanelsShape() {
        #expect(Crop.centred(width: 1000, height: 600) == Crop(left: 0, top: 0, width: 1, height: 1))
        #expect(Crop.centred(width: 1600, height: 480) == Crop(left: 0.25, top: 0, width: 0.5, height: 1))
        #expect(Crop.centred(width: 800, height: 960) == Crop(left: 0, top: 0.25, width: 1, height: 0.5))
        for (w, h) in [(1200, 900), (900, 1600), (2560, 1080), (150, 90), (1, 4000), (4000, 1), (801, 479)] {
            let crop = Crop.centred(width: w, height: h)
            #expect(throws: Never.self, "\(w)x\(h)") { try crop.validated(width: w, height: h) }
            #expect(crop.width == 1 || crop.height == 1, "\(w)x\(h)")
            #expect(abs(crop.left + crop.width / 2 - 0.5) < 1e-12 && abs(crop.top + crop.height / 2 - 0.5) < 1e-12)
        }
    }

    @Test func rejectionsSayWhy() throws {
        func error(_ crop: Crop, _ w: Int, _ h: Int) -> CropError? {
            do {
                _ = try crop.validated(width: w, height: h)
                return nil
            } catch {
                return error
            }
        }
        let outside = Crop(left: 0.5, top: 0, width: 1, height: 0.8)
        #expect(error(outside, 1200, 900) == .outside(outside))
        #expect(CropError.outside(outside).description
                == "the crop must lie inside the photo (fractions 0-1), got (0.5, 0.0, 1.0, 0.8)")
        for bad in [Crop(left: .nan, top: 0, width: 1, height: 0.8), Crop(left: 0, top: 0, width: .infinity, height: 0.8),
                    Crop(left: 0, top: 0, width: 0, height: 0), Crop(left: 0, top: -0.1, width: 1, height: 0.8),
                    Crop(left: 0, top: 0.2 + 1e-8, width: 1, height: 0.8)] {
            // Pattern matched: a NaN crop is not equal to itself.
            guard case .outside = error(bad, 1200, 900) else {
                Issue.record("\(bad) passed or failed for another reason")
                continue
            }
        }
        #expect(error(Crop(left: 0, top: 0, width: 0.5, height: 0.5), 1200, 900) == .wrongShape(width: 600, height: 450))
        #expect(CropError.wrongShape(width: 600, height: 450).description
                == "the crop must have the screen's 800:480 shape, got 600.0 x 450.0 px")
        #expect(error(Crop(left: 0.4, top: 0.4, width: 1.0 / 9, height: 0.8 / 9), 1200, 900) == .tooSmall)
        #expect(CropError.tooSmall.description
                == "the crop is too small (at most 8x zoom and at least 100 photo pixels high)")
    }

    @Test func slackOfTheChecks() throws {
        // Inside with 1e-9 to spare; the shape within one pixel.
        #expect(throws: Never.self) { try Crop(left: 0, top: 0.2 + 5e-10, width: 1, height: 0.8).validated(width: 1200, height: 900) }
        // 0.59 photo rows too many make the crop 0.98 px too narrow for its height: accepted.
        #expect(throws: Never.self) { try Crop(left: 0, top: 0, width: 1, height: 0.8 + 0.59 / 900).validated(width: 1200, height: 900) }
        #expect(throws: CropError.self) { try Crop(left: 0, top: 0, width: 1, height: 0.8 - 0.61 / 900).validated(width: 1200, height: 900) }
    }

    @Test func minimumWidthIsTheZoomLimit() throws {
        // (photo, narrowest width): 100 px high, or 1/8 of the default width when that is
        // wider; a photo whose default crop is under 100 px high allows no zoom.
        let cases: [(w: Int, h: Int, narrowest: Double)] = [
            (1200, 900, 100.0 * 800 / 480 / 1200), (4000, 3000, 1.0 / 8), (150, 90, 1), (2560, 1080, 0.703125 / 8),
            (160, 90, 0.9375), (300, 2000, 100.0 * 800 / 480 / 300),
        ]
        for (w, h, narrowest) in cases {
            let minimum = Crop.minimumWidth(width: w, height: h)
            #expect(abs(minimum - narrowest) < 1e-12, "\(w)x\(h): \(minimum)")
            // Centred at that width (height for the panel's shape): accepted; 0.1 % narrower: not.
            for (scale, expected) in [(1.0, true), (0.999, false)] {
                let cw = minimum * scale, ch = cw * Double(w) * 480 / 800 / Double(h)
                let crop = Crop(left: (1 - cw) / 2, top: max(0, (1 - ch) / 2), width: cw, height: ch)
                let accepted = (try? crop.validated(width: w, height: h)) != nil
                #expect(accepted == expected, "\(w)x\(h) at \(scale): \(crop)")
            }
        }
    }

    @Test func boxOfAnUncheckedCropNeverTraps() {
        #expect(Crop(left: .nan, top: 0, width: 1, height: 1).box(width: 1200, height: 900).x0 == 0)
        #expect(Crop(left: 0, top: 0, width: 1e300, height: 1).box(width: 1200, height: 900).x1 == 1 << 52)
        #expect(Crop(left: 0, top: -.infinity, width: 1, height: 1).box(width: 1200, height: 900).y0 == -(1 << 52))
    }

    // MARK: 4K cap

    @Test(arguments: [
        // landscape
        (6000, 4000, 3240, 2160), (3840, 2160, 3840, 2160), (3000, 2000, 3000, 2000), (5000, 2000, 3840, 1536),
        (4000, 3000, 2880, 2160),
        // portrait
        (4000, 6000, 2160, 3240), (2160, 3840, 2160, 3840), (2000, 5000, 1536, 3840),
        // panoramas, square, small
        (12000, 1500, 3840, 480), (1500, 12000, 480, 3840), (40000, 400, 3840, 38),
        (4000, 4000, 2160, 2160), (2160, 2160, 2160, 2160), (150, 90, 150, 90), (1, 1, 1, 1),
    ])
    func cappedPhotoSize(width: Int, height: Int, cappedWidth: Int, cappedHeight: Int) {
        let capped = FrameEncoder.cappedPhotoSize(width: width, height: height)
        #expect(capped == PhotoSize(width: cappedWidth, height: cappedHeight), "\(width)x\(height)")
        // Never above the cap in its own orientation, never scaled up.
        #expect(max(capped.width, capped.height) <= 3840 && min(capped.width, capped.height) <= 2160)
        #expect(capped.width <= width && capped.height <= height)
    }
}
