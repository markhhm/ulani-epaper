import CoreGraphics
import Foundation
import Testing
import UlaniKit
@testable import PaperhueUI

/// Previews shown smaller than the panel: the mean of the pixels each screen pixel covers, in
/// linear light (not the sRGB numbers' mean, which looks too dark).
@Suite struct PanelImageTests {
    /// Columns of the panel's black and white, alternating.
    let stripes = try! Frame(indices: (0..<(Frame.width * Frame.height)).map { UInt8($0 % 2) }).previewImage()
    let black = Palette.previewColours[0]

    @Test func halfSizeIsTheMeanInLinearLight() throws {
        let small = try #require(boxAverage(stripes, width: 400, height: 240))
        #expect(small.width == 400 && small.height == 240)
        let expected = [black.r, black.g, black.b].map { mix($0, 255, 0.5) }
        for (x, y) in [(0, 0), (399, 239), (200, 120)] {
            #expect(close(pixel(small, x, y), expected), "(\(x), \(y))")
        }
        #expect(expected[0] > (76 + 255) / 2)  // lighter than the sRGB midpoint
    }

    @Test func otherSizesWeighByTheAreaCovered() throws {
        let small = try #require(boxAverage(stripes, width: 600, height: 360))
        // Pixel 0 covers 4/3 frame pixels: all of black 0 and a third of white 1.
        #expect(close(pixel(small, 0, 10), [black.r, black.g, black.b].map { mix($0, 255, 0.25) }))
        let white = try Frame(indices: [UInt8](repeating: 1, count: Frame.width * Frame.height)).previewImage()
        let odd = try #require(boxAverage(white, width: 333, height: 201))
        #expect(pixel(odd, 0, 0) == [255, 255, 255] && pixel(odd, 332, 200) == [255, 255, 255])
    }

    @MainActor @Test func theCacheShrinksOnlyBelowThePanelsSize() {
        let cache = PanelImageCache()
        #expect(cache.image(stripes, width: 800, height: 480) === stripes)
        #expect(cache.image(stripes, width: 1200, height: 720) === stripes)  // nearest neighbour when drawn
        let small = cache.image(stripes, width: 400, height: 240)
        #expect(small !== stripes && small.width == 400)
        #expect(cache.image(stripes, width: 400, height: 240) === small)  // not averaged again
    }

    /// sRGB `a` and `b` mixed in linear light, `share` of `b`.
    private func mix(_ a: UInt8, _ b: UInt8, _ share: Double) -> Int {
        func linear(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let c = (1 - share) * linear(a) + share * linear(b)
        return Int(((c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055) * 255).rounded())
    }

    private func close(_ a: [Int], _ b: [Int]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= 1 } }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return rgba.prefix(3).map(Int.init)
    }
}
