import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import UlaniKit

/// shared/vectors/natural-vectors.json: 自然 dithering as every app must do it (shared/DITHER.md
/// §6): the tables as parsed, step A per colour, small images and whole frames at each strength.
private struct NaturalVectors: Decodable, Sendable {
    struct Colour: Decodable, Sendable {
        let name: String
        let rgb: String
        /// Three hex floats.
        let target: [String]
        let set: Int
        /// The same under 明亮 (no cusp move).
        let brightTarget: [String]
        let brightSet: Int
    }

    struct Image: Decodable, Sendable {
        let name: String
        let width: Int
        let height: Int
        /// Hex, 3 bytes per pixel, row-major.
        let rgb: String
        let results: [Result]
        let bright: [Result]
    }

    struct Result: Decodable, Sendable {
        let strength: Double
        /// One hex digit per pixel, row-major.
        let indices: String
    }

    struct Whole: Decodable, Sendable {
        let name: String
        let width: Int
        let height: Int
        /// Base64 of the RGB bytes, raw DEFLATE (no zlib header).
        let rgbDeflate: String
        let results: [Hashed]
        let bright: [Hashed]
    }

    struct Hashed: Decodable, Sendable {
        let strength: Double
        /// SHA-256 hex of the indices, one byte each.
        let sha256: String
    }

    let version: Int
    let strengths: [Double]
    let tablesSha256: [String: String]
    let colours: [Colour]
    let images: [Image]
    let frames: [Whole]

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/UlaniKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // UlaniKit
        .deletingLastPathComponent()  // apple
        .deletingLastPathComponent()  // repo root

    static let loaded = Swift.Result<NaturalVectors, any Error> {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(NaturalVectors.self,
                                  from: Data(contentsOf: root.appendingPathComponent("shared/vectors/natural-vectors.json")))
    }
}

private func rgbBytes(_ hex: String) -> [UInt8] {
    let digits = Array(hex.utf8)
    return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(decoding: digits[$0..<$0 + 2], as: UTF8.self), radix: 16)! }
}

private func hexIndices(_ indices: [UInt8]) -> String {
    String(indices.map { Character(String($0, radix: 16)) })
}

/// A 400x240 picture whose hue and lightness change across it.
private func gradient() -> CGImage? {
    let width = 400, height = 240
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            rgba[i] = UInt8(x * 255 / (width - 1))
            rgba[i + 1] = UInt8(y * 255 / (height - 1))
            rgba[i + 2] = UInt8(255 - x * 255 / (width - 1))
        }
    }
    let context = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    return context?.makeImage()
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Serialized: every test waits for the one decode of the large vectors file, and in parallel they
/// held enough threads to starve the timed Bluetooth tests.
@Suite(.serialized) struct NaturalTests {
    /// The tables in the source are the shared file, byte for byte.
    @Test func theTablesAreTheSharedFile() throws {
        let shared = try String(contentsOf: NaturalVectors.root.appendingPathComponent("shared/dither/natural-tables.json"),
                                encoding: .utf8)
        #expect(Natural.tablesJSON + "\n" == shared)
    }

    /// Every double parses to the bits the vectors hash (little-endian binary64, row by row),
    /// and the parsed tables hold those values.
    @Test func theTablesParseExactly() throws {
        let vectors = try NaturalVectors.loaded.get()
        #expect(vectors.version == 3 && vectors.strengths == [1.0, 0.8, 0.65, 0.5])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(Natural.tablesJSON.utf8)) as? [String: Any])
        #expect(vectors.tablesSha256.count == 21)
        for (key, hash) in vectors.tablesSha256 {
            let doubles = Natural.Tables.doubles(json, key)
            let packed = doubles.reduce(into: Data()) { data, d in withUnsafeBytes(of: d.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
            #expect(sha256(packed) == hash, "\(key)")
        }
        let t = Natural.tables
        #expect(t.decode == Natural.Tables.doubles(json, "decode_hex"))
        #expect(t.palLin == Natural.Tables.doubles(json, "pal_lin_hex"))
        #expect(t.facets.flatMap { [$0.nx, $0.ny, $0.nz, $0.d] } == Natural.Tables.doubles(json, "facets"))
        #expect(t.sectorXY.flatMap { [$0.ax, $0.ay, $0.bx, $0.by] } == Natural.Tables.doubles(json, "sector_xy"))
        #expect([t.yk, t.yrange, t.sat, t.dead, t.knee, t.alpha]
                    == ["yk", "yrange", "sat", "dead", "knee", "alpha"].map { Natural.Tables.doubles(json, $0)[0] })
        #expect(t.luma + t.k + t.wk + t.e1 + t.e2
                    == ["luma", "k", "wk", "e1", "e2"].flatMap { Natural.Tables.doubles(json, $0) })
    }

    /// The integer tables, checked directly (§3).
    @Test func theIntegerTables() {
        let t = Natural.tables
        #expect(t.paletteSRGB == Palette.previewColours.map { [Int($0.r), Int($0.g), Int($0.b)] })
        #expect(t.sectors.map { [$0.0, $0.1] } == [[3, 4], [4, 6], [6, 5], [5, 2], [2, 3]])
        #expect(t.stucki.map { [$0.w, $0.dx, $0.dy] } == FrameEncoder.stuckiKernel.map { [$0.weight, $0.dx, $0.dy] })
        #expect(t.stuckiDiv == 42)
    }

    /// Step A: the target to the bit, and the candidate set.
    @Test func eachColoursTargetAndCandidates() throws {
        let vectors = try NaturalVectors.loaded.get()
        #expect(vectors.colours.count == 80)
        for c in vectors.colours {
            let rgb = rgbBytes(c.rgb)
            let a = Natural.target(rgb[0], rgb[1], rgb[2])
            let expected = c.target.map { Double($0)! }
            #expect([a.t0, a.t1, a.t2].map(\.bitPattern) == expected.map(\.bitPattern), "\(c.name)")
            #expect(a.set == c.set, "\(c.name)")
            let b = Natural.target(rgb[0], rgb[1], rgb[2], cusp: false)
            #expect([b.t0, b.t1, b.t2].map(\.bitPattern) == c.brightTarget.map { Double($0)!.bitPattern }, "\(c.name) bright")
            #expect(b.set == c.brightSet, "\(c.name) bright")
        }
    }

    @Test func smallImagesAtEachStrength() throws {
        let vectors = try NaturalVectors.loaded.get()
        #expect(vectors.images.count == 43)
        for image in vectors.images {
            #expect(image.results.map(\.strength) == vectors.strengths, "\(image.name)")
            for result in image.results {
                let out = Natural.indices(rgbBytes(image.rgb), width: image.width, height: image.height,
                                          strength: result.strength)
                #expect(hexIndices(out) == result.indices, "\(image.name) at \(result.strength)")
            }
            #expect(image.bright.map(\.strength) == vectors.strengths, "\(image.name)")
            for result in image.bright {
                let out = Natural.indices(rgbBytes(image.rgb), width: image.width, height: image.height,
                                          strength: result.strength, cusp: false)
                #expect(hexIndices(out) == result.indices, "\(image.name) bright at \(result.strength)")
            }
        }
    }

    /// The real gate: one flipped decision spreads to its neighbours. One frame at a time, and
    /// a yield after each, so the other suites' timed tests are not held up for seconds.
    @Test(.serialized, arguments: 0..<3) func wholeFramesAtEachStrength(frame: Int) async throws {
        let vectors = try NaturalVectors.loaded.get()
        #expect(vectors.frames.count == 3)
        let whole = vectors.frames[frame]
        let deflated = try #require(Data(base64Encoded: whole.rgbDeflate))
        let rgb = [UInt8](try (deflated as NSData).decompressed(using: .zlib) as Data)
        #expect(rgb.count == whole.width * whole.height * 3)
        #expect(whole.results.map(\.strength) == vectors.strengths)
        for result in whole.results {
            let out = Natural.indices(rgb, width: whole.width, height: whole.height, strength: result.strength)
            #expect(sha256(Data(out)) == result.sha256, "\(whole.name) at \(result.strength)")
            await Task.yield()
        }
        #expect(whole.bright.map(\.strength) == vectors.strengths)
        for result in whole.bright {
            let out = Natural.indices(rgb, width: whole.width, height: whole.height, strength: result.strength,
                                      cusp: false)
            #expect(sha256(Data(out)) == result.sha256, "\(whole.name) bright at \(result.strength)")
            await Task.yield()
        }
    }

    /// FrameEncoder's 自然 is these indices, packed; without dithering it is the nearest colour.
    @Test func theEncoderUsesItForNatural() throws {
        let image = try #require(gradient())
        let rgba = FrameEncoder.render(image, fit: .cover)
        let rgb = (0..<(Frame.width * Frame.height)).flatMap { rgba[4 * $0..<4 * $0 + 3] }
        let natural = FrameEncoder.encode(image, strength: 0.8, colours: .natural)
        #expect(natural == (try Frame(indices: Natural.indices(rgb, width: Frame.width, height: Frame.height,
                                                               strength: 0.8))))
        #expect(natural != FrameEncoder.encode(image, strength: 0.8, colours: .classic))
        #expect(FrameEncoder.encode(image, strength: 0.8, colours: .bright)
                    == (try Frame(indices: Natural.indices(rgb, width: Frame.width, height: Frame.height,
                                                           strength: 0.8, cusp: false))))
        #expect(FrameEncoder.encode(image, dither: false, colours: .natural)
                    == FrameEncoder.encode(image, dither: false, colours: .classic))
    }
}
