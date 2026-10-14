import CoreGraphics
import Foundation
import SwiftUI

/// An 800x480 preview at the size it is shown, as the panel would look from afar: shown smaller
/// than its pixels, each screen pixel is the mean, in linear light, of the frame pixels it
/// covers; shown at its size or larger, nearest neighbour. Fills the space it is given.
struct PanelImage: View {
    let image: CGImage
    @Environment(\.displayScale) private var displayScale
    @State private var cache = PanelImageCache()

    var body: some View {
        GeometryReader { proxy in
            let width = Int((proxy.size.width * displayScale).rounded())
            let height = Int((proxy.size.height * displayScale).rounded())
            Image(decorative: cache.image(image, width: width, height: height), scale: 1)
                .resizable()
                .interpolation(.none)
        }
    }
}

/// The last shrunk image, so drawing again at the same size does not average again.
@MainActor final class PanelImageCache {
    private var last: (source: CGImage, width: Int, height: Int, image: CGImage)?

    /// `source` shrunk to `width` x `height` pixels when it is larger, else `source`.
    func image(_ source: CGImage, width: Int, height: Int) -> CGImage {
        guard width > 0, height > 0, width < source.width || height < source.height else { return source }
        if let last, last.source === source, last.width == width, last.height == height { return last.image }
        let image = boxAverage(source, width: min(width, source.width), height: min(height, source.height)) ?? source
        last = (source, width, height, image)
        return image
    }
}

/// `image` (opaque) at `width` x `height` (sRGB): each pixel the mean of the pixels it covers,
/// weighted by how much of each it covers, averaged in linear light.
func boxAverage(_ image: CGImage, width: Int, height: Int) -> CGImage? {
    let sw = image.width, sh = image.height, space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard width > 0, height > 0,
          let input = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let pixels = input.data else { return nil }
    input.draw(image, in: CGRect(x: 0, y: 0, width: sw, height: sh))
    let src = pixels.bindMemory(to: UInt8.self, capacity: sw * sh * 4)  // RGBX, row 0 = top
    let xs = coverage(sw, width), ys = coverage(sh, height)
    var rows = [Float](repeating: 0, count: sh * width * 3)  // narrowed first, linear RGB
    for y in 0..<sh {
        for (ox, span) in xs.enumerated() {
            let d = (y * width + ox) * 3
            for (x, w) in span {
                let s = (y * sw + x) * 4
                rows[d] += w * linearLight[Int(src[s])]
                rows[d + 1] += w * linearLight[Int(src[s + 1])]
                rows[d + 2] += w * linearLight[Int(src[s + 2])]
            }
        }
    }
    var out = [UInt8](repeating: 255, count: width * height * 4)
    for (oy, span) in ys.enumerated() {
        for ox in 0..<width {
            var r: Float = 0, g: Float = 0, b: Float = 0
            for (y, w) in span {
                let s = (y * width + ox) * 3
                r += w * rows[s]
                g += w * rows[s + 1]
                b += w * rows[s + 2]
            }
            let o = (oy * width + ox) * 4
            out[o] = sRGB(r)
            out[o + 1] = sRGB(g)
            out[o + 2] = sRGB(b)
        }
    }
    guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

/// For each of `m` pixels across, the `n` pixels it covers and the share of it each covers.
private func coverage(_ n: Int, _ m: Int) -> [[(index: Int, weight: Float)]] {
    let step = Double(n) / Double(m)
    return (0..<m).map { o in
        let a = Double(o) * step, b = Double(o + 1) * step
        return (Int(a)..<min(n, Int(b.rounded(.up)))).map { i in
            (i, Float((min(b, Double(i + 1)) - max(a, Double(i))) / step))
        }
    }
}

/// sRGB 0-255 -> linear light 0-1.
private let linearLight: [Float] = (0...255).map { v in
    let c = Float(v) / 255
    return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
}

/// Linear light 0-1 -> sRGB 0-255.
private func sRGB(_ c: Float) -> UInt8 {
    let c = min(max(c, 0), 1)
    let v = c <= 0.0031308 ? 12.92 * c : 1.055 * powf(c, 1 / 2.4) - 0.055
    return UInt8((v * 255).rounded())
}
