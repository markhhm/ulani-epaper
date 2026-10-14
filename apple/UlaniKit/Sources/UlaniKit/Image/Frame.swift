import CoreGraphics
import Foundation

/// One page as the device stores it: 800x480 palette indices, row-major from the
/// top-left, two pixels per byte with the first pixel in the high nibble.
public struct Frame: Sendable, Equatable {
    public static let width = Panel.width, height = Panel.height, byteCount = Panel.frameBytes

    /// Exactly `byteCount` bytes, indexed from 0.
    public let bytes: Data

    public var crc32: UInt32 { Checksums.crc32(bytes) }
    public var crc16: UInt16 { Checksums.crc16(bytes) }

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else {
            throw UlaniError.protocolError("a frame is \(Self.byteCount) bytes, got \(bytes.count)")
        }
        self.bytes = bytes.startIndex == 0 ? bytes : Data(bytes)
    }

    /// `width * height` palette indices (0-6), row-major from the top-left.
    public init(indices: [UInt8]) throws {
        guard indices.count == Self.width * Self.height else {
            throw UlaniError.protocolError(
                "a frame has \(Self.width * Self.height) pixels, got \(indices.count)")
        }
        if let bad = indices.first(where: { Int($0) >= Palette.colours.count }) {
            throw UlaniError.protocolError("palette index out of range: \(bad)")
        }
        self.bytes = Self.pack(indices)
    }

    /// The palette indices, row-major from the top-left.
    public func indices() -> [UInt8] { Self.unpack(bytes) }

    /// Two indices per byte, first in the high nibble; an odd count is padded with 0.
    public static func pack(_ indices: [UInt8]) -> Data {
        var out = Data(count: (indices.count + 1) / 2)
        out.withUnsafeMutableBytes { dst in
            indices.withUnsafeBufferPointer { src in
                for i in 0..<dst.count {
                    let high = src[2 * i] & 0x0F
                    let low = 2 * i + 1 < src.count ? src[2 * i + 1] & 0x0F : 0
                    dst[i] = high << 4 | low
                }
            }
        }
        return out
    }

    /// Inverse of `pack` (two indices per byte, high nibble first).
    public static func unpack(_ bytes: Data) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: bytes.count * 2)
        out.withUnsafeMutableBufferPointer { dst in
            bytes.withUnsafeBytes { src in
                for (i, byte) in src.enumerated() {
                    dst[2 * i] = byte >> 4
                    dst[2 * i + 1] = byte & 0x0F
                }
            }
        }
        return out
    }

    /// The frame as the panel shows it, in its measured colours (opaque sRGB,
    /// `Palette.previewColours`). Nibbles outside the palette (7-15) render as the panel's black.
    public func previewImage() -> CGImage {
        var lookup = [UInt8](repeating: 0, count: 16 * 4)  // RGBX per nibble value
        for i in 0..<16 {
            let c = Palette.previewColours[i < Palette.previewColours.count ? i : 0]
            lookup[i * 4] = c.r
            lookup[i * 4 + 1] = c.g
            lookup[i * 4 + 2] = c.b
        }
        var rgba = Data(count: Self.width * Self.height * 4)
        lookup.withUnsafeBufferPointer { lut in
            rgba.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                bytes.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                    for (i, byte) in src.enumerated() {
                        let first = Int(byte >> 4) * 4, second = Int(byte & 0x0F) * 4, o = i * 8
                        dst[o] = lut[first]
                        dst[o + 1] = lut[first + 1]
                        dst[o + 2] = lut[first + 2]
                        dst[o + 3] = 0xFF
                        dst[o + 4] = lut[second]
                        dst[o + 5] = lut[second + 1]
                        dst[o + 6] = lut[second + 2]
                        dst[o + 7] = 0xFF
                    }
                }
            }
        }
        // Neither initialiser can fail for these constant, valid parameters.
        let provider = CGDataProvider(data: rgba as CFData)!
        return CGImage(
            width: Self.width, height: Self.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: Self.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
