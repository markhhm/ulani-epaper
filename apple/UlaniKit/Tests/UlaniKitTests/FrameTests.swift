import CoreGraphics
import Foundation
import Testing
@testable import UlaniKit

@Suite struct FrameTests {
    let v: JSON

    init() throws { v = try Vectors.root() }

    // MARK: palette

    @Test func paletteMatchesVectors() throws {
        let entries = try #require(v["palette"]?.array)
        #expect(entries.count == Palette.colours.count)
        for entry in entries {
            let index = try #require(entry["index"]?.int)
            let rgb = try #require(entry["rgb"]?.array).compactMap(\.int)
            let c = Palette.colours[index]
            #expect([Int(c.r), Int(c.g), Int(c.b)] == rgb, "palette \(index)")
        }
    }

    @Test func nearestColourSamples() throws {
        let samples = try #require(v["nearest_colour"]?.array)
        #expect(samples.count == 7)
        for s in samples {
            let rgb = try #require(s["rgb"]?.array).compactMap(\.int)
            #expect(Int(Palette.nearestIndex(r: rgb[0], g: rgb[1], b: rgb[2])) == s["index"]?.int, "rgb \(rgb)")
        }
    }

    @Test func exactPaletteColoursMapToThemselves() {
        for (i, c) in Palette.colours.enumerated() {
            #expect(Palette.nearestIndex(r: Int(c.r), g: Int(c.g), b: Int(c.b)) == UInt8(i))
        }
    }

    @Test func tiesGoToTheLowestIndex() {
        // (100,255,155): squared distance 34 025 to both white (1) and green (2).
        #expect(Palette.nearestIndex(r: 100, g: 255, b: 155) == 1)
        // (255,190,0): squared distance 4 225 to both yellow (5) and orange (6).
        #expect(Palette.nearestIndex(r: 255, g: 190, b: 0) == 5)
    }

    // MARK: packing

    @Test func packingVectors() throws {
        let cases = try #require(v["packing"]?.array)
        #expect(cases.count == 4)
        for c in cases {
            let indices = try #require(c["indices"]?.array).compactMap(\.int).map(UInt8.init)
            let packed = try #require(c["packed"]?.string)
            #expect(toHex(Frame.pack(indices)) == packed, "pack \(indices)")
            // Unpacking gives the indices back, padded with 0 to an even count.
            #expect(Frame.unpack(try fromHex(packed)) == indices + (indices.count % 2 == 1 ? [0] : []))
        }
        #expect(toHex(Frame.pack([5])) == "50")
        #expect(Frame.pack([]).isEmpty)
    }

    // MARK: test frames

    @Test func bandsFrame() throws {
        let expected = try #require(v["frame_bands"])
        let frame = try Frame(indices: Vectors.bandIndices())
        #expect(hexNumber(frame.crc32, digits: 8) == expected["crc32"]?.string)
        #expect(hexNumber(frame.crc16, digits: 4) == expected["crc16"]?.string)
        #expect(toHex(frame.bytes.prefix(Frame.width / 2)) == expected["first_row_packed"]?.string)
    }

    @Test func checkerFrame() throws {
        let expected = try #require(v["frame_checker"])
        let frame = try Frame(indices: Vectors.checkerIndices())
        #expect(hexNumber(frame.crc32, digits: 8) == expected["crc32"]?.string)
        #expect(hexNumber(frame.crc16, digits: 4) == expected["crc16"]?.string)
        #expect(toHex(frame.bytes.prefix(Frame.width / 2)) == expected["first_row_packed"]?.string)
        #expect(toHex(frame.bytes.suffix(Frame.width / 2)) == expected["last_row_packed"]?.string)
        // Same bytes as the vectors' own recipe.
        #expect(frame.bytes == (try Vectors.input(.object(["checker": .bool(true)]))))
    }

    @Test func dimensions() {
        #expect(Frame.width == 800)
        #expect(Frame.height == 480)
        #expect(Frame.byteCount == 192_000)
    }

    // MARK: construction

    @Test func bytesMustBeExactlyOneFrame() throws {
        #expect(protocolErrorMessage { _ = try Frame(bytes: Data(count: 191_999)) } != nil)
        #expect(protocolErrorMessage { _ = try Frame(bytes: Data(count: 192_001)) } != nil)
        #expect(protocolErrorMessage { _ = try Frame(bytes: Data()) } != nil)
        let frame = try Frame(bytes: Data(repeating: 0x11, count: 192_000))
        #expect(frame.bytes.count == 192_000)
    }

    @Test func bytesFromASliceStartAtZero() throws {
        let big = Data(repeating: 0x23, count: 192_010)
        let frame = try Frame(bytes: big[5..<192_005])
        #expect(frame.bytes.startIndex == 0)
        #expect(frame.bytes.first == 0x23)
    }

    @Test func indicesMustBeOneFrameOfPaletteIndices() {
        #expect(protocolErrorMessage { _ = try Frame(indices: [UInt8](repeating: 1, count: 383_999)) } != nil)
        #expect(protocolErrorMessage { _ = try Frame(indices: []) } != nil)
        var bad = [UInt8](repeating: 1, count: 384_000)
        bad[1234] = 7
        #expect(protocolErrorMessage { _ = try Frame(indices: bad) } != nil)
    }

    @Test func indicesRoundTrip() throws {
        let indices = Vectors.checkerIndices()
        let frame = try Frame(indices: indices)
        #expect(frame.indices() == indices)
        #expect(try Frame(bytes: frame.bytes) == frame)
    }

    // MARK: preview

    @Test func previewOfTheCheckerFrame() throws {
        let frame = try Frame(indices: Vectors.checkerIndices())
        let image = frame.previewImage()
        #expect(image.width == 800)
        #expect(image.height == 480)
        let pixels = rgbaPixels(of: image)
        func colour(_ x: Int, _ y: Int) -> [UInt8] {
            let i = (y * image.width + x) * 4
            return Array(pixels[i..<i + 3])
        }
        func palette(_ index: UInt8) -> [UInt8] {
            let c = Palette.previewColours[Int(index)]
            return [c.r, c.g, c.b]
        }
        #expect(colour(0, 0) == [76, 63, 89])  // the panel's black, as measured
        #expect(colour(799, 479) == palette(Vectors.checkerIndex(x: 799, y: 479)))
        for (x, y) in [(0, 479), (799, 0), (115, 0), (0, 69), (400, 240)] {
            #expect(colour(x, y) == palette(Vectors.checkerIndex(x: x, y: y)), "(\(x), \(y))")
        }
    }

    @Test func previewShowsInvalidNibblesAsBlack() throws {
        let frame = try Frame(bytes: Data(repeating: 0xF1, count: 192_000))
        let pixels = rgbaPixels(of: frame.previewImage())
        #expect(Array(pixels[0..<3]) == [0, 0, 0])
        #expect(Array(pixels[4..<7]) == [255, 255, 255])
    }
}

/// RGBA8 (sRGB, premultiplied last) pixels of `image`, row 0 = top.
func rgbaPixels(of image: CGImage) -> [UInt8] {
    let width = image.width, height = image.height
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    buffer.withUnsafeMutableBytes { raw in
        let context = CGContext(
            data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return buffer
}
