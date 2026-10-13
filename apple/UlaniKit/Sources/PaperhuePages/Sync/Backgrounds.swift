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
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".bg-\(UUID().uuidString).tmp")
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.jpeg.identifier as CFString,
                                                                1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, photo, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
        if FileManager.default.fileExists(atPath: url(background).path) {
            _ = try FileManager.default.replaceItemAt(url(background), withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url(background))
        }
    }

    /// The kept photo (to show in the crop editor) with the size its crop refers to.
    public func photo(_ background: PageBackground) throws -> DecodedPhoto {
        try FrameEncoder.loadPhoto(url: url(background))
    }

    /// The page's background as the panel shows it: the crop of the kept photo filling the
    /// screen, dithered at `strength` (a fraction of a second, so it is done for each drawing).
    public func frame(_ background: PageBackground, strength: Double) throws -> Frame {
        let photo = try photo(background)
        let crop = try background.crop.map { try $0.validated(width: photo.size.width, height: photo.size.height) }
        return FrameEncoder.encode(photo.image, fit: .cover, crop: crop, dither: true, strength: strength)
    }

    public func remove(_ background: PageBackground) {
        try? FileManager.default.removeItem(at: url(background))
    }

    func url(_ background: PageBackground) -> URL { folder.appendingPathComponent(background.image) }
}
