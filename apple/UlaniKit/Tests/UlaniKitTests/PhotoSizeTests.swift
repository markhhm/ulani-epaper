import Foundation
import Testing
@testable import UlaniKit

/// shared/vectors/photo-cap-vectors.json: the 4K cap and the 50 MP refusal every app applies.
private struct PhotoCapVectors: Decodable, Sendable {
    struct Cap: Decodable, Sendable {
        let name: String
        let photo: [Int]
        let capped: [Int]
    }

    struct Refusal: Decodable, Sendable {
        let name: String
        let photo: [Int]
        let refused: Bool
    }

    struct Megapixels: Decodable, Sendable {
        let pixels: Int
        let megapixels: Int
    }

    let maxPhotoSize: [Int]
    let pixelLimit: Int
    let cap: [Cap]
    let refusal: [Refusal]
    let megapixels: [Megapixels]

    /// <repo>/shared/vectors/photo-cap-vectors.json: this file's directory, up 4 directories.
    static let url: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/UlaniKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // UlaniKit
        .deletingLastPathComponent()  // apple
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("shared/vectors/photo-cap-vectors.json")

    static let loaded = Swift.Result<PhotoCapVectors, any Error> {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PhotoCapVectors.self, from: Data(contentsOf: url))
    }
}

@Suite struct PhotoSizeTests {
    @Test func limitsMatchTheVectors() throws {
        let vectors = try PhotoCapVectors.loaded.get()
        #expect(vectors.maxPhotoSize == [FrameEncoder.maxPhotoSize.width, FrameEncoder.maxPhotoSize.height])
        #expect(vectors.pixelLimit == FrameEncoder.photoPixelLimit)
    }

    @Test func everyCapSize() throws {
        let vectors = try PhotoCapVectors.loaded.get()
        #expect(!vectors.cap.isEmpty)
        for c in vectors.cap {
            let capped = FrameEncoder.cappedPhotoSize(width: c.photo[0], height: c.photo[1])
            #expect([capped.width, capped.height] == c.capped, "\(c.name)")
            // The decoder asks ImageIO for exactly the capped long side.
            #expect(FrameEncoder.decodeSize(width: c.photo[0], height: c.photo[1]) == c.capped.max(), "\(c.name)")
        }
    }

    @Test func refusalBoundary() throws {
        let vectors = try PhotoCapVectors.loaded.get()
        #expect(!vectors.refusal.isEmpty)
        // The check loadPhoto makes on the header's size before decoding (a real 50 MP photo
        // is too big for a unit test; ImageIO reports no size for a truncated one).
        for r in vectors.refusal {
            do {
                try FrameEncoder.checkPixels(width: r.photo[0], height: r.photo[1])
                #expect(!r.refused, "\(r.name): accepted")
            } catch {
                #expect(r.refused, "\(r.name): refused")
                #expect(error.pixels == r.photo[0] * r.photo[1])
            }
        }
    }

    @Test func megapixelsRoundHalvesUp() throws {
        let vectors = try PhotoCapVectors.loaded.get()
        #expect(!vectors.megapixels.isEmpty)
        for m in vectors.megapixels {
            #expect(PhotoTooLarge(pixels: m.pixels).megapixels == m.megapixels, "\(m.pixels)")
        }
    }

    @Test func refusalText() {
        #expect(String(describing: PhotoTooLarge(pixels: 50_320_896))
                == "the photo is over the 50 megapixel limit; shrink it first")
    }
}
