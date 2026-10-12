import CoreGraphics
import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UlaniKit
import UniformTypeIdentifiers

/// A decoded photo (EXIF orientation applied, at most ~2400 px on the long side), kept so
/// that changing an option re-renders without decoding again.
struct LoadedPhoto: Sendable {
    let image: CGImage
    /// File name, when the source knows it only after fetching (Photos library items).
    let name: String?
}

/// Where a page's photo comes from.
public struct PhotoSource: Sendable {
    /// Shown on the tile while loading; nil when unknown yet.
    public let name: String?
    /// Gets the photo's bytes; for a Photos library item this may mean downloading it from
    /// iCloud. The view model calls it off the main actor without holding a render slot,
    /// so a slow download holds up no other page; at most once per photo.
    public let fetch: @Sendable () async throws -> FetchedPhoto

    public init(name: String?, fetch: @escaping @Sendable () async throws -> FetchedPhoto) {
        self.name = name
        self.fetch = fetch
    }

    /// Image file contents (JPEG, HEIC, PNG, ...).
    public static func data(_ data: Data, name: String?) -> PhotoSource {
        PhotoSource(name: name) { .data(data, name: name) }
    }

    /// A file chosen in the file importer. In the macOS sandbox it is readable only between
    /// start/stopAccessingSecurityScopedResource, so it is read here, once.
    public static func file(_ url: URL) -> PhotoSource {
        let name = url.lastPathComponent
        return PhotoSource(name: name) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            return .data(try Data(contentsOf: url), name: name)
        }
    }

    /// A photo chosen with PhotosPicker. Loading may download it from iCloud first.
    public static func libraryItem(_ item: PhotosPickerItem) -> PhotoSource {
        PhotoSource(name: nil) {
            guard let picked = try await item.loadTransferable(type: PickedPhoto.self) else {
                throw UlaniError.protocolError("unsupported image")
            }
            return .data(picked.data, name: picked.name)
        }
    }
}

/// A photo's bytes, not decoded yet.
public struct FetchedPhoto: Sendable {
    /// File name, when the source knows it only now (Photos library items).
    public let name: String?
    /// Decodes the photo (EXIF orientation applied, at most ~2400 px on the long side).
    /// Runs off the main actor holding one of the two render slots: decoding a large photo
    /// takes memory and CPU.
    public let decode: @Sendable () async throws -> CGImage

    public init(name: String?, decode: @escaping @Sendable () async throws -> CGImage) {
        self.name = name
        self.decode = decode
    }

    /// Image file contents (JPEG, HEIC, PNG, ...).
    public static func data(_ data: Data, name: String?) -> FetchedPhoto {
        FetchedPhoto(name: name) { try FrameEncoder.loadImage(data: data) }
    }
}

/// The bytes of a photo from the Photos library. A file representation keeps the original
/// file name; plain data is the fallback.
struct PickedPhoto: Transferable {
    let data: Data
    let name: String?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            PickedPhoto(data: try Data(contentsOf: received.file), name: received.file.lastPathComponent)
        }
        DataRepresentation(importedContentType: .image) { data in
            PickedPhoto(data: data, name: nil)
        }
    }
}
