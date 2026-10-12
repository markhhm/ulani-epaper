import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import UlaniKit

// Every input is synthesised here (CGContext / CGImage / ImageIO in memory); no binary fixtures.

private typealias RGBA = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)
private let red: RGBA = (255, 0, 0, 255), green: RGBA = (0, 255, 0, 255), blue: RGBA = (0, 0, 255, 255)
private let black: RGBA = (0, 0, 0, 255), clear: RGBA = (0, 0, 0, 0), yellow: RGBA = (255, 255, 0, 255)

@Suite struct FrameEncoderTests {
    // MARK: orientation guard

    /// The checker frame's palette colours as an 800x480 RGBA image.
    private func checkerImage() -> CGImage {
        makeImage(width: 800, height: 480) { x, y in
            let c = Palette.colours[Int(Vectors.checkerIndex(x: x, y: y))]
            return (c.r, c.g, c.b, 255)
        }
    }

    private func expectCheckerFrame(_ frame: Frame) throws {
        let expected = try #require(try Vectors.root()["frame_checker"])
        #expect(hexNumber(frame.crc32, digits: 8) == expected["crc32"]?.string)
        #expect(hexNumber(frame.crc16, digits: 4) == expected["crc16"]?.string)
        #expect(frame.bytes.count == Frame.byteCount)
    }

    @Test func checkerImageEncodesToTheCheckerFrame() throws {
        // Catches CGContext's bottom-left origin, any flip and the nibble order.
        try expectCheckerFrame(FrameEncoder.encode(checkerImage(), fit: .cover, dither: false))
    }

    @Test func ditheringPalettePixelsChangesNothing() throws {
        try expectCheckerFrame(FrameEncoder.encode(checkerImage(), fit: .cover, dither: true))
    }

    // MARK: loading

    @Test func transparentPNGBecomesWhite() throws {
        let png = try encoded(makeImage(width: 10, height: 10) { _, _ in clear }, as: .png)
        let image = try FrameEncoder.loadImage(data: png)
        #expect(image.width == 10 && image.height == 10)
        expectIndices(FrameEncoder.encode(image).indices(), allWhite)
    }

    @Test func pngColourKeyTransparencyBecomesWhite() throws {
        // tRNS keys black: the opaque-looking black RGB image is fully transparent.
        let image = try FrameEncoder.loadImage(data: colourKeyPNG(width: 10, height: 10))
        expectIndices(FrameEncoder.encode(image, dither: false).indices(), allWhite)
    }

    @Test func exifOrientationIsApplied() throws {
        // Stored 480x800, top half red, bottom half blue. Orientation 6 = rotate 90° clockwise
        // to display, so the stored top row ends up as the right-hand column.
        let stored = makeImage(width: 480, height: 800) { _, y in y < 400 ? red : blue }
        let jpeg = try encoded(stored, as: .jpeg, properties: [
            kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 1.0,
        ])
        #expect(properties(of: jpeg)[kCGImagePropertyOrientation] as? Int == 6)
        let image = try FrameEncoder.loadImage(data: jpeg)
        #expect(image.width == 800 && image.height == 480)
        let frame = FrameEncoder.encode(image, fit: .contain, dither: false)
        #expect(column(frame, 0) == [3])
        #expect(column(frame, 799) == [4])
        #expect(column(frame, 200) == [3])
        #expect(column(frame, 600) == [4])
    }

    @Test func largeJPEGsDecodeAtTheCap() throws {
        let jpeg = try encoded(makeFilledImage(width: 6000, height: 4000), as: .jpeg, properties: [
            kCGImageDestinationLossyCompressionQuality: 0.5,
        ])
        let image = try FrameEncoder.loadImage(data: jpeg)
        #expect(image.width == 3240 && image.height == 2160)  // 6000x4000 capped to 4K
        #expect(FrameEncoder.encode(image).bytes.count == Frame.byteCount)
    }

    @Test func decodeSizeIsTheCappedLongSide() {
        #expect(FrameEncoder.decodeSize(width: 6000, height: 4000) == 3240)  // ordinary photo: 3240x2160
        #expect(FrameEncoder.decodeSize(width: 4000, height: 6000) == 3240)
        #expect(FrameEncoder.decodeSize(width: 3600, height: 1200) == 3600)  // 3:1, inside the cap
        #expect(FrameEncoder.decodeSize(width: 1200, height: 3600) == 3600)
        #expect(FrameEncoder.decodeSize(width: 8000, height: 2000) == 3840)  // 4:1, exactly
        #expect(FrameEncoder.decodeSize(width: 4800, height: 960) == 3840)   // the cap: 3840x768
        #expect(FrameEncoder.decodeSize(width: 12000, height: 1500) == 3840)
        #expect(FrameEncoder.decodeSize(width: 1500, height: 12000) == 3840)
        #expect(FrameEncoder.decodeSize(width: 40000, height: 400) == 3840)
        #expect(FrameEncoder.decodeSize(width: 4000, height: 4000) == 2160)  // square: 2160x2160
        #expect(FrameEncoder.decodeSize(width: 1001, height: 999) == 1001)   // small: full size
        #expect(FrameEncoder.decodeSize(width: 0, height: 0) == 2160)        // size unknown
    }

    @Test func panoramasKeepTwiceThePanelOnTheShortSide() throws {
        // A panorama decodes at its capped size (3840x960 here), not at a fixed long side,
        // so cover scales it down instead of blowing up a few hundred rows.
        for (width, height) in [(8000, 2000), (2000, 8000)] {
            let photo = try FrameEncoder.loadPhoto(data: jpeg(makeFilledImage(width: width, height: height)))
            let image = photo.image
            #expect(min(image.width, image.height) >= 960, "\(width)x\(height) -> \(image.width)x\(image.height)")
            #expect(max(image.width, image.height) <= 3840, "\(width)x\(height) -> \(image.width)x\(image.height)")
            #expect((image.width > image.height) == (width > height))
            #expect(photo.size == (width > height ? PhotoSize(width: 3840, height: 960) : PhotoSize(width: 960, height: 3840)))
        }
    }

    @Test(arguments: [
        // (photo, its size after the cap, the largest decode allowed)
        (6000, 4000, 3240, 2160, 3240),    // landscape
        (4000, 6000, 2160, 3240, 3240),    // portrait
        (4000, 4000, 2160, 2160, 2160),    // square
        (12000, 1500, 3840, 480, 3840),    // panorama beyond the cap
        (1500, 12000, 480, 3840, 3840),
        (40000, 400, 3840, 38, 3840),      // a strip
        (3600, 1200, 3600, 1200, 3600),    // panorama inside the cap
        (1000, 600, 1000, 600, 1000),      // small: never scaled up
    ])
    func photosAreCappedAt4K(width: Int, height: Int, cappedWidth: Int, cappedHeight: Int, longest: Int) throws {
        let photo = try FrameEncoder.loadPhoto(data: jpeg(makeFilledImage(width: width, height: height)))
        let image = photo.image
        let size = "\(width)x\(height) -> \(image.width)x\(image.height)"
        #expect(photo.size == PhotoSize(width: cappedWidth, height: cappedHeight), "\(size)")
        // Never above the capped size, in the photo's own orientation; never scaled up.
        #expect(image.width <= cappedWidth && image.height <= cappedHeight, "\(size)")
        #expect(max(image.width, image.height) == longest, "\(size)")
        #expect((image.width >= image.height) == (width >= height), "\(size)")
        // Cover still covers the panel: no white.
        #expect(!FrameEncoder.encode(image, dither: false).indices().contains(1), "\(size)")
    }

    @Test func rotatedPhotosAreCappedAsDisplayed() throws {
        // Stored 2000x5000, orientation 6: shown 5000x2000, so 3840x1536 after the cap.
        let data = try jpeg(makeFilledImage(width: 2000, height: 5000), properties: [kCGImagePropertyOrientation: 6])
        let photo = try FrameEncoder.loadPhoto(data: data)
        #expect(photo.size == PhotoSize(width: 3840, height: 1536))
        #expect(photo.image.width == 3840 && photo.image.height == 1536)
    }

    @Test func sixteenBitGreyPNGIsScaledNotClipped() throws {
        // Left half 8000 (~12 % grey -> black), right half 65535 (white).
        var samples = [UInt8]()
        samples.reserveCapacity(800 * 480 * 2)
        for _ in 0..<480 {
            for x in 0..<800 {
                let v: UInt16 = x < 400 ? 8000 : 65535
                samples += [UInt8(v >> 8), UInt8(v & 0xFF)]
            }
        }
        let grey = rawImage(
            width: 800, height: 480, bitsPerComponent: 16, bitsPerPixel: 16,
            space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
            bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Big.rawValue, samples: samples)
        let png = try encoded(grey, as: .png)
        let props = properties(of: png)
        #expect(props[kCGImagePropertyDepth] as? Int == 16)
        #expect(props[kCGImagePropertyColorModel] as? String == kCGImagePropertyColorModelGray as String)

        let frame = FrameEncoder.encode(try FrameEncoder.loadImage(data: png), dither: false)
        #expect(frame.bytes.count == Frame.byteCount)
        #expect(column(frame, 0) == [0])
        #expect(column(frame, 799) == [1])
    }

    @Test func cmykJPEGLoadsAndEncodes() throws {
        // Left half no ink (paper white), right half full black ink.
        var samples = [UInt8]()
        samples.reserveCapacity(800 * 480 * 4)
        for _ in 0..<480 {
            for x in 0..<800 { samples += [0, 0, 0, x < 400 ? 0 : 255] }
        }
        let cmyk = rawImage(
            width: 800, height: 480, bitsPerComponent: 8, bitsPerPixel: 32,
            space: CGColorSpace(name: CGColorSpace.genericCMYK)!,
            bitmapInfo: CGImageAlphaInfo.none.rawValue, samples: samples)
        let jpeg = try encoded(cmyk, as: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 1.0])
        #expect(properties(of: jpeg)[kCGImagePropertyColorModel] as? String == kCGImagePropertyColorModelCMYK as String)

        let frame = FrameEncoder.encode(try FrameEncoder.loadImage(data: jpeg), dither: false)
        #expect(frame.bytes.count == Frame.byteCount)
        #expect(column(frame, 0) == [1])
        #expect(column(frame, 799) == [0])
    }

    @Test func undecodableDataThrows() {
        for data in [Data("definitely not an image".utf8), Data()] {
            let message = protocolErrorMessage { _ = try FrameEncoder.loadImage(data: data) }
            #expect(message?.contains("unsupported image") == true, "\(data.count) bytes: \(String(describing: message))")
        }
    }

    @Test func loadImageFromAFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ulani-encoder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("red.png")
        try encoded(makeImage(width: 40, height: 30) { _, _ in red }, as: .png).write(to: url)
        let image = try FrameEncoder.loadImage(url: url)
        #expect(image.width == 40 && image.height == 30)

        let missing = protocolErrorMessage { _ = try FrameEncoder.loadImage(url: directory.appendingPathComponent("gone.jpg")) }
        #expect(missing?.contains("gone.jpg") == true, "\(String(describing: missing))")

        let text = directory.appendingPathComponent("notes.jpg")
        try Data("not a photo".utf8).write(to: text)
        let bad = protocolErrorMessage { _ = try FrameEncoder.loadImage(url: text) }
        #expect(bad?.contains("notes.jpg") == true && bad?.contains("unsupported image") == true,
                "\(String(describing: bad))")
    }

    // MARK: fitting

    @Test func containLetterboxesOnWhite() throws {
        let frame = FrameEncoder.encode(makeImage(width: 400, height: 480) { _, _ in red }, fit: .contain, dither: false)
        let row: [UInt8] = (0..<800).map { (200..<600).contains($0) ? 4 : 1 }
        expectIndices(frame.indices(), Array(repeatElement(row, count: 480).joined()))
    }

    @Test func containRoundsHalfToEvenLikePython() throws {
        // 1001x960 -> scale 0.5 -> 500.5 px wide: Python's round() gives 500, placed at x = 150.
        let frame = FrameEncoder.encode(makeImage(width: 1001, height: 960) { _, _ in red }, fit: .contain, dither: false)
        let row: [UInt8] = (0..<800).map { (150..<650).contains($0) ? 4 : 1 }
        expectIndices(frame.indices(), Array(repeatElement(row, count: 480).joined()))
    }

    @Test func containPlacesAThinLineLikePython() throws {
        // 2000x1 -> 800x1 (at least 1 px), top at (480 - 1) // 2 = 239 counted from the top.
        let frame = FrameEncoder.encode(makeImage(width: 2000, height: 1) { _, _ in black }, fit: .contain, dither: false)
        let indices = frame.indices()
        for y in [0, 238, 239, 240, 479] {
            let row = Set(indices[(y * 800)..<((y + 1) * 800)])
            #expect(row == (y == 239 ? [0] : [1]), "row \(y)")
        }
        for size in [(1, 2000), (2, 5000)] {
            let tall = FrameEncoder.encode(makeImage(width: size.0, height: size.1) { _, _ in black }, fit: .contain)
            #expect(tall.bytes.count == Frame.byteCount)
            #expect(column(tall, 0) == [1])
        }
    }

    @Test func coverCropsTheCentre() throws {
        // 1600x480, left half green, right half blue -> source x 400..<1200 is shown.
        let image = makeImage(width: 1600, height: 480) { x, _ in x < 800 ? green : blue }
        let frame = FrameEncoder.encode(image, fit: .cover, dither: false)
        #expect(column(frame, 0) == [2])
        #expect(column(frame, 799) == [3])
        let indices = frame.indices()
        for y in 0..<480 {
            let row = indices[(y * 800)..<((y + 1) * 800)]
            let boundary = try #require(row.firstIndex(of: 3)) - y * 800
            #expect((399...401).contains(boundary), "row \(y): blue starts at \(boundary)")
            #expect(row.prefix(399).allSatisfy { $0 == 2 } && row.suffix(398).allSatisfy { $0 == 3 }, "row \(y)")
        }
    }

    @Test func coverFillsTheFrameFromATallImage() throws {
        let frame = FrameEncoder.encode(makeImage(width: 100, height: 400) { _, _ in black }, fit: .cover, dither: false)
        #expect(Set(frame.indices()) == [0])
    }

    // MARK: crop

    @Test(arguments: [(1200, 900), (900, 1600), (2560, 1080), (1000, 600), (150, 90), (801, 479), (3840, 2160)])
    func noCropIsTodaysCover(width: Int, height: Int) throws {
        // The cover path as it was before crops: the whole picture scaled to fill, centred.
        let image = makePattern(width: width, height: height)
        // Bools, not `#expect(a == b)`: a failure would diff 1.5 million bytes (see expectIndices).
        let today = todaysCover(image)
        let sameRender = FrameEncoder.render(image, fit: .cover, crop: nil) == today
        #expect(sameRender, "\(width)x\(height): the render differs")
        // Dithered once (slow in debug builds); nearest colour for every size.
        let dither = width == 1200
        let frame = FrameEncoder.encode(image, fit: .cover, crop: nil, dither: dither)
        let sameFrame = frame.bytes == Data(FrameEncoder.quantize(today, dither: dither))
        #expect(sameFrame, "\(width)x\(height): the frame differs")
        let sameDefault = frame == FrameEncoder.encode(image, dither: dither)
        #expect(sameDefault, "\(width)x\(height): crop nil is not the default")
    }

    @Test func theCentredCropLooksLikeNoCrop() throws {
        // The explicit default crop draws the same part of the photo: with a box in whole
        // pixels, the same picture (a row may differ by rounding).
        for (width, height) in [(1200, 900), (900, 1600), (2560, 1080), (1000, 600)] {
            let image = makePattern(width: width, height: height)
            let crop = Crop.centred(width: width, height: height)
            let plain = FrameEncoder.render(image, fit: .cover)
            let cropped = FrameEncoder.render(image, fit: .cover, crop: crop)
            let rows = (0..<Frame.height).filter { y in
                (0..<(Frame.width * 4)).contains { abs(Int(plain[y * Frame.width * 4 + $0]) - Int(cropped[y * Frame.width * 4 + $0])) > 8 }
            }
            #expect(rows.count <= 1, "\(width)x\(height): rows \(rows.prefix(10)) differ")
        }
    }

    @Test(arguments: [
        // (crop of a 1200x900 photo, the one colour on the panel)
        (Crop(left: 0, top: 0, width: 0.5, height: 0.4), UInt8(4)),       // top-left: red
        (Crop(left: 0.5, top: 0, width: 0.5, height: 0.4), UInt8(2)),     // top-right: green
        (Crop(left: 0, top: 0.6, width: 0.5, height: 0.4), UInt8(3)),     // bottom-left: blue
        (Crop(left: 0.5, top: 0.6, width: 0.5, height: 0.4), UInt8(5)),   // bottom-right: yellow
    ])
    func cornerCropsShowThatCorner(crop: Crop, colour: UInt8) throws {
        try crop.validated(width: 1200, height: 900)
        let frame = FrameEncoder.encode(quadrants(width: 1200, height: 900), crop: crop, dither: false)
        #expect(Set(frame.indices()) == [colour])
    }

    @Test func aZoomedCropLandsOnTheExpectedPixels() throws {
        // 4x zoom on the centre: box 450,360 - 750,540, so the four quadrants meet in the
        // middle of the panel.
        let crop = Crop(left: 0.375, top: 0.4, width: 0.25, height: 0.2)
        try crop.validated(width: 1200, height: 900)
        expectQuadrants(FrameEncoder.encode(quadrants(width: 1200, height: 900), crop: crop, dither: false))
        // An off-centre crop: box 300,180 - 900,540 shows red at the top left down to row
        // 450 - 180 = 270 of 360 (360 of 480 on the panel) and to column 300 of 600 (400).
        let offset = Crop(left: 0.25, top: 0.2, width: 0.5, height: 0.4)
        try offset.validated(width: 1200, height: 900)
        let indices = FrameEncoder.encode(quadrants(width: 1200, height: 900), crop: offset, dither: false).indices()
        #expect(indices[358 * 800 + 100] == 4 && indices[362 * 800 + 100] == 3)
        #expect(indices[100 * 800 + 398] == 4 && indices[100 * 800 + 402] == 2)
    }

    @Test func containIgnoresTheCrop() throws {
        let image = quadrants(width: 1200, height: 900)
        let crop = Crop(left: 0, top: 0, width: 0.5, height: 0.4)
        #expect(FrameEncoder.encode(image, fit: .contain, crop: crop) == FrameEncoder.encode(image, fit: .contain))
        #expect(FrameEncoder.encode(image, fit: .cover, crop: crop) != FrameEncoder.encode(image, fit: .cover))
    }

    @Test(arguments: [3, 6, 8])
    func rotatedPhotosAreCroppedAsDisplayed(orientation: Int) throws {
        // Stored so that, displayed, it is the 1200x900 quadrants picture.
        let shown = (width: 1200, height: 900)
        let stored = orientation == 3 ? shown : (width: shown.height, height: shown.width)
        let image = makeImage(width: stored.width, height: stored.height) { sx, sy in
            let (dx, dy) = switch orientation {
            case 3: (stored.width - 1 - sx, stored.height - 1 - sy)  // turned 180°
            case 6: (stored.height - 1 - sy, sx)                     // turned 90° clockwise
            default: (sy, stored.width - 1 - sx)                     // 8: turned 90° anticlockwise
            }
            return quadrantColour(x: dx, y: dy, width: shown.width, height: shown.height)
        }
        let data = try jpeg(image, properties: [kCGImagePropertyOrientation: orientation])
        let photo = try FrameEncoder.loadPhoto(data: data)
        #expect(photo.size == PhotoSize(width: 1200, height: 900))
        #expect(photo.image.width == 1200 && photo.image.height == 900)
        let topLeft = FrameEncoder.encode(photo.image, crop: Crop(left: 0, top: 0, width: 0.5, height: 0.4), dither: false)
        #expect(Set(topLeft.indices()) == [4])
        expectQuadrants(FrameEncoder.encode(photo.image, crop: Crop(left: 0.375, top: 0.4, width: 0.25, height: 0.2),
                                            dither: false))
    }

    @Test func cropsAreFractionsSoAnyDecodeSizeWorks() throws {
        // The crop refers to the capped photo (6000x4500 -> 2880x2160); the box is taken in
        // the decoded image's pixels, here the same size, and in a half-size copy too.
        let data = try jpeg(quadrants(width: 6000, height: 4500))
        let photo = try FrameEncoder.loadPhoto(data: data)
        #expect(photo.size == PhotoSize(width: 2880, height: 2160))
        #expect(photo.image.width == 2880 && photo.image.height == 2160)
        let crop = Crop(left: 0.375, top: 0.4, width: 0.25, height: 0.2)
        try crop.validated(width: photo.size.width, height: photo.size.height)
        expectQuadrants(FrameEncoder.encode(photo.image, crop: crop, dither: false))
        expectQuadrants(FrameEncoder.encode(quadrants(width: 1440, height: 1080), crop: crop, dither: false))
    }

    @Test func cropBoxStaysInsideThePicture() {
        let box = { (crop: Crop) in FrameEncoder.cropBox(crop, width: 1200, height: 900) }
        #expect(box(Crop(left: 0.375, top: 0.4, width: 0.25, height: 0.2)) == Crop.Box(x0: 450, y0: 360, x1: 750, y1: 540))
        #expect(box(Crop(left: -0.5, top: 0.5, width: 2, height: 1)) == Crop.Box(x0: 0, y0: 450, x1: 1200, y1: 900))
        #expect(box(Crop(left: 1, top: 1, width: 0, height: 0)) == Crop.Box(x0: 1199, y0: 899, x1: 1200, y1: 900))
        #expect(box(Crop(left: .nan, top: 0, width: .nan, height: 1)) == Crop.Box(x0: 0, y0: 0, x1: 1, y1: 900))
        // The box fills the panel: 450,360 - 750,540 of 1200x900 at 8/3 times.
        let rect = FrameEncoder.placement(width: 1200, height: 900, fit: .cover,
                                          crop: Crop(left: 0.375, top: 0.4, width: 0.25, height: 0.2))
        #expect(abs(rect.minX + 1200) < 1e-9 && abs(rect.width - 3200) < 1e-9)
        #expect(abs(rect.minY + 960) < 1e-9 && abs(rect.height - 2400) < 1e-9)  // (900 - 540) * 8/3 below
    }

    // MARK: colour mapping

    @Test func fastNearestAgreesWithThePalette() throws {
        // The encoder's per-pixel lookup must be Palette.nearestIndex exactly, ties included.
        var samples = [(100, 255, 155), (255, 190, 0), (127, 127, 127), (128, 0, 0), (255, 125, 0)]
        for entry in try #require(try Vectors.root()["nearest_colour"]?.array) {
            let rgb = try #require(entry["rgb"]?.array).compactMap(\.int)
            samples.append((rgb[0], rgb[1], rgb[2]))
        }
        for r in stride(from: 0, through: 255, by: 5) {
            for g in stride(from: 0, through: 255, by: 5) {
                for b in stride(from: 0, through: 255, by: 5) { samples.append((r, g, b)) }
            }
        }
        let mismatches = samples.filter { FrameEncoder.nearest($0.0, $0.1, $0.2) != Palette.nearestIndex(r: $0.0, g: $0.1, b: $0.2) }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
    }

    @Test func ditheringMixesColoursToTheAverage() throws {
        // Dark red (128,0,0) is just nearer red than black: flat red without dithering,
        // about half black with error diffusion (green and blue stay 0, so no other colour).
        let darkRed = makeImage(width: 800, height: 480) { _, _ in (128, 0, 0, 255) }
        #expect(Set(FrameEncoder.encode(darkRed, dither: false).indices()) == [4])
        let dithered = FrameEncoder.encode(darkRed, dither: true).indices()
        #expect(Set(dithered) == [0, 4])
        let blackShare = Double(dithered.filter { $0 == 0 }.count) / Double(dithered.count)
        #expect(abs(blackShare - 127.0 / 255.0) < 0.02, "black share \(blackShare)")
    }

    /// A 9x6 image (a formula, below) and the indices the Stucki algorithm gives at each
    /// grain strength, computed independently from the algorithm's written definition.
    @Test(arguments: [
        (1.0, [0, 2, 2, 5, 4, 6, 6, 2, 2, 0, 6, 1, 3, 4, 3, 3, 1, 3, 1, 1, 3, 3, 3, 1, 1, 1, 3, 3, 3, 2, 6, 6, 6, 5, 2, 0, 2, 5, 5, 6, 3, 2, 2, 3, 4, 6, 1, 3, 3, 3, 1, 1, 3, 1]),
        (0.8, [0, 2, 2, 2, 4, 6, 6, 2, 2, 0, 6, 1, 4, 4, 3, 3, 1, 3, 1, 1, 3, 3, 3, 1, 1, 1, 3, 3, 3, 1, 0, 6, 6, 5, 2, 0, 2, 5, 5, 6, 3, 2, 2, 3, 4, 6, 1, 3, 3, 2, 1, 1, 3, 1]),
        (0.65, [0, 2, 2, 2, 4, 6, 6, 2, 2, 0, 6, 1, 4, 4, 3, 3, 1, 3, 1, 1, 3, 3, 3, 1, 1, 1, 3, 3, 3, 1, 0, 6, 6, 5, 2, 0, 2, 5, 5, 6, 2, 2, 2, 3, 4, 6, 1, 3, 3, 3, 1, 1, 4, 1]),
        (0.5, [0, 2, 2, 2, 4, 6, 6, 2, 2, 0, 6, 1, 4, 4, 3, 3, 1, 3, 1, 1, 2, 3, 3, 1, 1, 1, 3, 3, 3, 1, 0, 6, 6, 5, 2, 0, 2, 5, 5, 4, 0, 2, 2, 3, 4, 6, 1, 3, 3, 3, 1, 1, 4, 1]),
    ])
    func stuckiOnASmallImage(strength: Double, expected: [UInt8]) {
        let width = 9, height = 6
        var rgb = [Int]()
        for y in 0..<height {
            for x in 0..<width {
                let r: Int = (x * 37 + y * 91) % 256
                let g: Int = (x * 53 + y * 17 + 80) % 256
                let b: Int = (x * 11 + y * 67 + 30) % 256
                rgb += [r, g, b]
            }
        }
        #expect(FrameEncoder.stucki(rgb, width: width, height: height, strength: strength) == expected)
    }

    @Test func zeroStrengthIsPlainNearestColour() {
        let rgb: [Int] = (0..<(40 * 30)).flatMap { (p: Int) -> [Int] in [p * 7 % 256, p * 13 % 256, p * 29 % 256] }
        let plain = (0..<(40 * 30)).map { FrameEncoder.nearest(rgb[3 * $0], rgb[3 * $0 + 1], rgb[3 * $0 + 2]) }
        #expect(FrameEncoder.stucki(rgb, width: 40, height: 30, strength: 0) == plain)
    }

    @Test(arguments: [1.0, 0.65])
    func encoderMatchesAStraightforwardStucki(strength: Double) throws {
        // The same definition written plainly (2-D arrays, one tap at a time) against the
        // encoder's buffer-based version, on a full frame with every kind of colour.
        let source: (Int, Int) -> (Int, Int, Int) = { x, y in
            let r: Int = (x * 7 + y * 3) % 256
            let g: Int = (x * x + y * 5) % 256
            let b: Int = (x * 3 + y * y) % 256
            return (r, g, b)
        }
        let image = makeImage(width: 800, height: 480) { x, y in
            let c = source(x, y)
            return (UInt8(c.0), UInt8(c.1), UInt8(c.2), 255)
        }
        var px = (0..<480).map { y in (0..<800).map { x in [source(x, y).0, source(x, y).1, source(x, y).2] } }
        let kernel = [(8, 1, 0), (4, 2, 0), (2, -2, 1), (4, -1, 1), (8, 0, 1), (4, 1, 1), (2, 2, 1),
                      (1, -2, 2), (2, -1, 2), (4, 0, 2), (2, 1, 2), (1, 2, 2)]
        var expected = [UInt8]()
        expected.reserveCapacity(800 * 480)
        for y in 0..<480 {
            for x in 0..<800 {
                let c = px[y][x]
                let index = Palette.nearestIndex(r: c[0], g: c[1], b: c[2])
                expected.append(index)
                let colour = Palette.colours[Int(index)]
                let error = [c[0] - Int(colour.r), c[1] - Int(colour.g), c[2] - Int(colour.b)]
                for (weight, dx, dy) in kernel where x + dx >= 0 && x + dx < 800 && y + dy < 480 {
                    let f = Double(weight) / 42.0 * strength
                    var n = (0..<3).map { px[y + dy][x + dx][$0] + Int(Double(error[$0]) * f) }
                    if let low = n.min(), low < 0 {
                        let lift = Int(Double(255 * -low) / Double(255 - low))
                        n = n.map { $0 + lift }
                    }
                    if let high = n.max(), high > 255 {
                        let scale = 255.0 / Double(high)
                        n = n.map { Int(Double($0) * scale) }
                    }
                    px[y + dy][x + dx] = n.map { min(max($0, 0), 255) }
                }
            }
        }
        #expect(Set(expected).count > 3)
        expectIndices(FrameEncoder.encode(image, dither: true, strength: strength).indices(), expected)
    }

    @Test func ditheredGradientUsesOnlyPaletteIndices() throws {
        let gradient = makeImage(width: 800, height: 480) { x, y in
            (UInt8(x * 255 / 799), UInt8(y * 255 / 479), UInt8((x + y) * 255 / 1278), 255)
        }
        let indices = FrameEncoder.encode(gradient).indices()
        #expect(indices.allSatisfy { $0 < 7 })
        #expect(Set(indices).count > 2)
    }
}

// MARK: helpers

/// Every pixel white (index 1).
private let allWhite = [UInt8](repeating: 1, count: Frame.width * Frame.height)

/// Whole-frame comparison of palette indices (row-major, 800 per row). Not `#expect(a == b)`:
/// on failure Swift Testing diffs the two collections, which takes minutes for 384 000
/// pixels; this reports how many differ and the first one, in milliseconds.
private func expectIndices(_ actual: [UInt8], _ expected: [UInt8],
                           sourceLocation: SourceLocation = #_sourceLocation) {
    guard actual.count == expected.count else {
        Issue.record("\(actual.count) indices, expected \(expected.count)", sourceLocation: sourceLocation)
        return
    }
    var first: Int?, differing = 0
    for i in actual.indices where actual[i] != expected[i] {
        if first == nil { first = i }
        differing += 1
    }
    if let i = first {
        Issue.record("""
            \(differing) pixels differ, the first at x \(i % Frame.width), y \(i / Frame.width): \
            index \(actual[i]), expected \(expected[i])
            """, sourceLocation: sourceLocation)
    }
}

/// An 8-bit sRGB RGBA image built pixel by pixel; `pixel(x, y)` with y = 0 at the top.
/// Alpha is either 0 or 255 here, so premultiplying is a no-op except for clearing.
private func makeImage(width: Int, height: Int, pixel: (Int, Int) -> RGBA) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let stride = context.bytesPerRow
    let buffer = context.data!.bindMemory(to: UInt8.self, capacity: stride * height)
    for y in 0..<height {  // bitmap memory starts with the top row
        for x in 0..<width {
            let c = pixel(x, y)
            let o = y * stride + x * 4
            if c.a == 0 {
                buffer[o] = 0; buffer[o + 1] = 0; buffer[o + 2] = 0; buffer[o + 3] = 0
            } else {
                buffer[o] = c.r; buffer[o + 1] = c.g; buffer[o + 2] = c.b; buffer[o + 3] = c.a
            }
        }
    }
    return context.makeImage()!
}

/// A CGImage over raw `samples` (rows from the top, no padding).
private func rawImage(width: Int, height: Int, bitsPerComponent: Int, bitsPerPixel: Int,
                      space: CGColorSpace, bitmapInfo: UInt32, samples: [UInt8]) -> CGImage {
    CGImage(
        width: width, height: height, bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerPixel,
        bytesPerRow: width * bitsPerPixel / 8, space: space, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
        provider: CGDataProvider(data: Data(samples) as CFData)!,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

/// A 1200x900-style test photo in four colours: red top left, green top right, blue
/// bottom left, yellow bottom right (drawn with fills, so any size is fast).
private func quadrants(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let halfW = width / 2, halfH = height / 2
    // CoreGraphics' origin is the bottom left: the top half is y >= height - halfH.
    for (x, y, colour) in [(0, height - halfH, red), (halfW, height - halfH, green), (0, 0, blue), (halfW, 0, yellow)] {
        context.setFillColor(red: CGFloat(colour.r) / 255, green: CGFloat(colour.g) / 255,
                             blue: CGFloat(colour.b) / 255, alpha: 1)
        context.fill(CGRect(x: x, y: y, width: x == 0 ? halfW : width - halfW, height: y == 0 ? height - halfH : halfH))
    }
    return context.makeImage()!
}

/// The colour of `quadrants` at (x, y), y = 0 at the top.
private func quadrantColour(x: Int, y: Int, width: Int, height: Int) -> RGBA {
    switch (x < width / 2, y < height / 2) {
    case (true, true): red
    case (false, true): green
    case (true, false): blue
    case (false, false): yellow
    }
}

/// A frame showing `quadrants` meeting in the middle of the panel (boundaries within 2 px).
private func expectQuadrants(_ frame: Frame, sourceLocation: SourceLocation = #_sourceLocation) {
    let indices = frame.indices()
    var wrong = 0
    for y in 0..<Frame.height where abs(y - 240) > 2 {
        for x in 0..<Frame.width where abs(x - 400) > 2 {
            let expected: UInt8 = switch (x < 400, y < 240) {
            case (true, true): 4
            case (false, true): 2
            case (true, false): 3
            case (false, false): 5
            }
            if indices[y * Frame.width + x] != expected { wrong += 1 }
        }
    }
    #expect(wrong == 0, "\(wrong) pixels off their quadrant", sourceLocation: sourceLocation)
}

/// A photo-like test picture (gradients, shapes, fine stripes) drawn with CoreGraphics.
private func makePattern(width: Int, height: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let w = CGFloat(width), h = CGFloat(height)
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 1), CGColor(srgbRed: 0.1, green: 0.6, blue: 0.9, alpha: 1),
        CGColor(srgbRed: 0.95, green: 0.9, blue: 0.2, alpha: 1),
    ] as CFArray, locations: [0, 0.5, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
    context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
    context.fillEllipse(in: CGRect(x: w * 0.3, y: h * 0.3, width: w * 0.4, height: h * 0.4))
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8))
    for i in stride(from: 0, to: width, by: max(3, width / 60)) {
        context.fill(CGRect(x: CGFloat(i), y: 0, width: 1, height: h * 0.2))
    }
    return context.makeImage()!
}

/// What `FrameEncoder.render` drew in cover mode before crops existed: the whole image
/// scaled to fill the panel, centred, on white, with high-quality interpolation.
private func todaysCover(_ image: CGImage) -> [UInt8] {
    let width = Frame.width, height = Frame.height
    var pixels = [UInt8](repeating: 0xFF, count: width * height * 4)
    pixels.withUnsafeMutableBytes { raw in
        let context = CGContext(
            data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        let w = Double(image.width), h = Double(image.height)
        let scale = max(Double(width) / w, Double(height) / h)
        context.draw(image, in: CGRect(x: (Double(width) - w * scale) / 2, y: (Double(height) - h * scale) / 2,
                                       width: w * scale, height: h * scale))
    }
    return pixels
}

/// `image` as a JPEG (quality 1, or as `properties` say).
private func jpeg(_ image: CGImage, properties: [CFString: Any] = [:]) throws -> Data {
    try encoded(image, as: .jpeg, properties: properties.merging(
        [kCGImageDestinationLossyCompressionQuality: 1.0]) { given, _ in given })
}

/// A big image drawn with fills (fast): red with a blue square.
private func makeFilledImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
    return context.makeImage()!
}

/// `image` written by ImageIO as `type`, in memory.
private func encoded(_ image: CGImage, as type: UTType, properties: [CFString: Any] = [:]) throws -> Data {
    let out = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
    return out as Data
}

/// ImageIO's properties of the first image in `data`.
private func properties(of data: Data) -> [CFString: Any] {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
    return props
}

/// The distinct palette indices in column `x`.
private func column(_ frame: Frame, _ x: Int) -> Set<UInt8> {
    let indices = frame.indices()
    return Set((0..<Frame.height).map { indices[$0 * Frame.width + x] })
}

/// A black 8-bit RGB PNG whose tRNS chunk makes black transparent (ImageIO cannot write
/// one, so the chunks are assembled here; IDAT is a stored, uncompressed deflate block).
private func colourKeyPNG(width: Int, height: Int) -> Data {
    func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    func chunk(_ kind: String, _ body: [UInt8]) -> [UInt8] {
        let typed = Array(kind.utf8) + body
        return be32(body.count) + typed + be32(Int(Checksums.crc32(Data(typed))))
    }
    var raw = [UInt8]()
    for _ in 0..<height { raw += [0] + [UInt8](repeating: 0, count: width * 3) }  // filter 0 + black pixels
    precondition(raw.count <= 0xFFFF, "one stored block only")
    var a: UInt32 = 1, b: UInt32 = 0  // adler32
    for byte in raw { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
    let len = raw.count
    let zlib: [UInt8] = [0x78, 0x01, 0x01, UInt8(len & 0xFF), UInt8(len >> 8), UInt8(~len & 0xFF), UInt8((~len >> 8) & 0xFF)]
        + raw + be32(Int(b << 16 | a))
    let ihdr = be32(width) + be32(height) + [8, 2, 0, 0, 0]  // 8-bit truecolour
    let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        + chunk("IHDR", ihdr) + chunk("tRNS", [0, 0, 0, 0, 0, 0]) + chunk("IDAT", zlib) + chunk("IEND", [])
    return Data(png)
}
