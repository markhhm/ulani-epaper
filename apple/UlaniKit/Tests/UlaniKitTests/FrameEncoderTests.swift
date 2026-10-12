import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import UlaniKit

// Every input is synthesised here (CGContext / CGImage / ImageIO in memory); no binary fixtures.

private typealias RGBA = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)
private let red: RGBA = (255, 0, 0, 255), green: RGBA = (0, 255, 0, 255), blue: RGBA = (0, 0, 255, 255)
private let black: RGBA = (0, 0, 0, 255), clear: RGBA = (0, 0, 0, 0)

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

    @Test func largeJPEGsDecodeSmall() throws {
        let jpeg = try encoded(makeFilledImage(width: 6000, height: 4000), as: .jpeg, properties: [
            kCGImageDestinationLossyCompressionQuality: 0.5,
        ])
        let image = try FrameEncoder.loadImage(data: jpeg)
        #expect(max(image.width, image.height) <= 2400)
        // Still >= 2x the panel, enough for cover/contain.
        #expect(image.width >= 1600 && image.height >= 960)
        #expect(FrameEncoder.encode(image).bytes.count == Frame.byteCount)
    }

    @Test func decodeSizeKeepsTheShortSide() {
        #expect(FrameEncoder.decodeSize(width: 6000, height: 4000) == 2400)  // ordinary photo
        #expect(FrameEncoder.decodeSize(width: 4000, height: 6000) == 2400)
        #expect(FrameEncoder.decodeSize(width: 4800, height: 960) == 4800)   // 5:1, exactly
        #expect(FrameEncoder.decodeSize(width: 12000, height: 1500) == 7680)
        #expect(FrameEncoder.decodeSize(width: 1500, height: 12000) == 7680)
        #expect(FrameEncoder.decodeSize(width: 1001, height: 999) == 2400)   // small: full size anyway
        #expect(FrameEncoder.decodeSize(width: 40000, height: 400) == 8192)  // capped
        #expect(FrameEncoder.decodeSize(width: 0, height: 0) == 2400)        // size unknown
    }

    @Test func panoramasKeepTwiceThePanelOnTheShortSide() throws {
        // Capping only the long side at 2400 would decode a 12000x1500 panorama as 2400x300,
        // and cover would then blow it up to 480 rows. Like Python's draft (>= 1600x960),
        // the short side stays >= 960, so cover still scales down.
        for (width, height) in [(12000, 1500), (1500, 12000)] {
            let jpeg = try encoded(makeFilledImage(width: width, height: height), as: .jpeg, properties: [
                kCGImageDestinationLossyCompressionQuality: 0.5,
            ])
            let image = try FrameEncoder.loadImage(data: jpeg)
            #expect(min(image.width, image.height) >= 960, "\(width)x\(height) -> \(image.width)x\(image.height)")
            #expect(max(image.width, image.height) < max(width, height), "\(width)x\(height) decoded at full size")
            #expect((image.width > image.height) == (width > height))
        }
        // An extreme strip is still capped, so its decode stays small.
        let strip = try encoded(makeFilledImage(width: 40000, height: 400), as: .jpeg, properties: [
            kCGImageDestinationLossyCompressionQuality: 0.5,
        ])
        let image = try FrameEncoder.loadImage(data: strip)
        #expect(image.width <= FrameEncoder.maxPixelSizeCap, "\(image.width)x\(image.height)")
        #expect(FrameEncoder.encode(image).bytes.count == Frame.byteCount)
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
        // about half black with Floyd-Steinberg (green and blue stay 0, so no other colour).
        let darkRed = makeImage(width: 800, height: 480) { _, _ in (128, 0, 0, 255) }
        #expect(Set(FrameEncoder.encode(darkRed, dither: false).indices()) == [4])
        let dithered = FrameEncoder.encode(darkRed, dither: true).indices()
        #expect(Set(dithered) == [0, 4])
        let blackShare = Double(dithered.filter { $0 == 0 }.count) / Double(dithered.count)
        #expect(abs(blackShare - 127.0 / 255.0) < 0.01, "black share \(blackShare)")
    }

    @Test func ditheringIsLeftToRightFloydSteinberg() throws {
        // Textbook Floyd-Steinberg on the red channel alone (green and blue stay exact):
        // 7/16 right, 3/16 below left, 5/16 below, 1/16 below right, every row left to
        // right, errors past the edges dropped. Errors accumulate apart from the source
        // value, in the same order as the encoder, so the Float results agree exactly.
        let source: (Int, Int) -> Float = { x, y in Float((x * 7 + y * 3) % 256) }
        let image = makeImage(width: 800, height: 480) { x, y in (UInt8(source(x, y)), 0, 0, 255) }
        var error = [[Float]](repeating: [Float](repeating: 0, count: 800), count: 480)
        var expected = [UInt8]()
        expected.reserveCapacity(800 * 480)
        for y in 0..<480 {
            for x in 0..<800 {
                let v = min(max(source(x, y) + error[y][x], 0), 255)
                let index = Palette.nearestIndex(r: Int(v.rounded()), g: 0, b: 0)
                expected.append(index)
                let e = v - Float(Palette.colours[Int(index)].r)
                if x + 1 < 800 { error[y][x + 1] += e * (7 / 16) }
                if y + 1 < 480 {
                    if x > 0 { error[y + 1][x - 1] += e * (3 / 16) }
                    error[y + 1][x] += e * (5 / 16)
                    if x + 1 < 800 { error[y + 1][x + 1] += e * (1 / 16) }
                }
            }
        }
        #expect(Set(expected) == [0, 4])
        expectIndices(FrameEncoder.encode(image, dither: true).indices(), expected)
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
