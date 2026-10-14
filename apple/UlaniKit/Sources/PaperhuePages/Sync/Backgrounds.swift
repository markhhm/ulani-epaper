import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UlaniKit

/// The photo behind a calendar page (python/src/ulani_epaper/config.py `PageBackground`): a
/// file in the backgrounds folder and the part of it shown (shared/CROP.md; nil: centred).
public struct PageBackground: Hashable, Sendable {
    public var image: String
    public var crop: Crop?

    public init(image: String, crop: Crop? = nil) {
        self.image = image
        self.crop = crop
    }

    /// A plain .jpg or .png file name (Python: `Settings.validate`).
    var isValid: Bool {
        image.wholeMatch(of: /[0-9A-Za-z_-]{1,40}\.(jpg|jpeg|png)/) != nil
    }
}

/// The background photos, each an upright copy of at most 4K (as for photo pages) in `folder`,
/// named after its page (`page-N.jpg`; Python: `config.set_background`). The photo never leaves
/// the Mac; a page is drawn on it by cutting the crop out and dithering it with the grain setting.
public struct BackgroundStore: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// Keeps `photo` (decoded upright, at most 4K) for `page` as JPEG, replacing the page's
    /// earlier one; returns the setting naming it with `crop`.
    public func keep(_ photo: CGImage, page: Int, crop: Crop? = nil) throws -> PageBackground {
        let background = PageBackground(image: "page-\(page).jpg", crop: crop)
        try keep(photo, as: background)
        return background
    }

    /// Writes `photo` as the JPEG file `background.image`, replacing an earlier one.
    func keep(_ photo: CGImage, as background: PageBackground) throws {
        let prepared = try prepare(photo)
        do {
            try install(prepared, as: background)
        } catch {
            discard(prepared)
            throw error
        }
    }

    /// Writes `photo` as JPEG (on white, as photo pages flatten transparency) to a temporary
    /// file in the folder: `install` it, or `discard` it when the choice was superseded.
    public func prepare(_ photo: CGImage) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".bg-\(UUID().uuidString).tmp")
        guard let context = CGContext(data: nil, width: photo.width, height: photo.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.jpeg.identifier as CFString,
                                                                1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let rect = CGRect(x: 0, y: 0, width: photo.width, height: photo.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(photo, in: rect)
        guard let flat = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            discard(temporary)
            throw CocoaError(.fileWriteUnknown)
        }
        return temporary
    }

    /// Makes a prepared photo `page`'s background, replacing the page's earlier one.
    public func install(_ prepared: URL, page: Int, crop: Crop? = nil) throws -> PageBackground {
        let background = PageBackground(image: "page-\(page).jpg", crop: crop)
        try install(prepared, as: background)
        return background
    }

    /// Makes a prepared photo the file `background.image`, replacing an earlier one.
    func install(_ prepared: URL, as background: PageBackground) throws {
        if FileManager.default.fileExists(atPath: url(background).path) {
            _ = try FileManager.default.replaceItemAt(url(background), withItemAt: prepared)
        } else {
            try FileManager.default.moveItem(at: prepared, to: url(background))
        }
    }

    public func discard(_ prepared: URL) {
        try? FileManager.default.removeItem(at: prepared)
    }

    /// The kept photo (to show in the crop editor) with the size its crop refers to.
    public func photo(_ background: PageBackground) throws -> DecodedPhoto {
        try FrameEncoder.loadPhoto(url: url(background))
    }

    /// The page's background as the panel shows it: the crop of the kept photo filling the
    /// screen, dithered with `colours` at `strength` (a fraction of a second, so it is done for
    /// each drawing).
    public func frame(_ background: PageBackground, strength: Double, colours: Colours) throws -> Frame {
        let photo = try photo(background)
        let crop = try background.crop.map { try $0.validated(width: photo.size.width, height: photo.size.height) }
        return FrameEncoder.encode(photo.image, fit: .cover, crop: crop, dither: true, strength: strength,
                                   colours: colours)
    }

    public func remove(_ background: PageBackground) {
        try? FileManager.default.removeItem(at: url(background))
    }

    func url(_ background: PageBackground) -> URL { folder.appendingPathComponent(background.image) }
}
