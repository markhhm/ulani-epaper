import Foundation
import Testing
@testable import UlaniKit

/// shared/vectors/dither-vectors.json: expected Stucki results shared by every implementation.
private struct DitherVectors: Decodable, Sendable {
    struct RangeCase: Decodable, Sendable {
        let `in`: [Int]
        let out: [Int]
    }

    struct Image: Decodable, Sendable {
        let name: String
        let width: Int
        let height: Int
        /// Hex, 3 bytes per pixel, row-major.
        let rgb: String
        let results: [Result]
    }

    struct Result: Decodable, Sendable {
        let strength: Double
        /// One hex digit (palette index) per pixel, row-major.
        let indices: String
    }

    let version: Int
    let kernel: [[Int]]
    let divisor: Int
    let strengths: [Double]
    let keepInRange: [RangeCase]
    let images: [Image]

    /// <repo>/shared/vectors/dither-vectors.json: this file's directory, up 4 directories.
    static let url: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/UlaniKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // UlaniKit
        .deletingLastPathComponent()  // apple
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("shared/vectors/dither-vectors.json")

    static let loaded = Swift.Result<DitherVectors, any Error> {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(DitherVectors.self, from: Data(contentsOf: url))
    }
}

private func bytes(hex: String) throws -> [Int] {
    let digits = Array(hex.utf8)
    guard digits.count % 2 == 0 else { throw VectorError("odd hex length \(digits.count)") }
    return try stride(from: 0, to: digits.count, by: 2).map { i in
        guard let value = Int(String(decoding: digits[i..<i + 2], as: UTF8.self), radix: 16) else {
            throw VectorError("bad hex at \(i)")
        }
        return value
    }
}

private func indices(hex: String) throws -> [UInt8] {
    try hex.map { digit in
        guard let value = digit.hexDigitValue else { throw VectorError("bad index digit \(digit)") }
        return UInt8(value)
    }
}

@Suite struct DitherVectorTests {
    @Test func kernelAndStrengthsMatch() throws {
        let vectors = try DitherVectors.loaded.get()
        #expect(vectors.version == 1)
        #expect(vectors.divisor == 42)
        #expect(vectors.kernel == FrameEncoder.stuckiKernel.map { [$0.weight, $0.dx, $0.dy] })
        #expect(Set(vectors.strengths).isSuperset(of: [1.0, 0.8, 0.65, 0.5]))
    }

    @Test func keepInRangeCases() throws {
        let vectors = try DitherVectors.loaded.get()
        #expect(!vectors.keepInRange.isEmpty)
        for c in vectors.keepInRange {
            let kept = FrameEncoder.keepInRange(c.in[0], c.in[1], c.in[2])
            #expect([kept.r, kept.g, kept.b] == c.out, "in \(c.in)")
        }
    }

    @Test func everyImageAtEveryStrength() throws {
        let vectors = try DitherVectors.loaded.get()
        #expect(!vectors.images.isEmpty)
        for image in vectors.images {
            let rgb = try bytes(hex: image.rgb)
            try #require(rgb.count == image.width * image.height * 3, "\(image.name): rgb size")
            for result in image.results {
                let expected = try indices(hex: result.indices)
                let actual = FrameEncoder.stucki(rgb, width: image.width, height: image.height,
                                                 strength: result.strength)
                #expect(actual == expected, "\(image.name) at strength \(result.strength)")
            }
        }
    }
}
