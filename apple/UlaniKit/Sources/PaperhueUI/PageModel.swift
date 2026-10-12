import CoreGraphics
import Foundation
import Observation
import UlaniKit

/// One page of the calendar: the chosen photo, its frame and preview, push progress
/// (Python: gui.Tile).
@MainActor @Observable
public final class PageModel: Identifiable {
    /// 1-4.
    public let page: Int
    public internal(set) var name: String?
    /// The encoded page; nil while there is no photo or it is (re)rendering.
    public internal(set) var frame: Frame?
    /// The frame in the panel's 7 colours, 800x480.
    public internal(set) var preview: CGImage?
    /// What the tile says under its progress bar (`PushViewModel.statusText(of:)`).
    public internal(set) var status = PageStatus.blank
    /// 0-100.
    public internal(set) var percent = 0
    public internal(set) var isRendering = false
    /// The last photo chosen for this page could not be read.
    public internal(set) var failed = false
    /// The part of the photo that fills the screen in Fill (`PushViewModel.setCrop`); nil,
    /// the default, is the centred crop. In memory only; a new photo or a clear resets it,
    /// Fit ignores it but keeps it.
    public internal(set) var crop: Crop?

    /// The chosen photo and, once decoded, the decoded image (re-renders reuse it).
    var source: PhotoSource?
    var photo: LoadedPhoto?
    /// Bumped by every new render or clear: a render whose generation is no longer the
    /// page's is stale and its result is dropped.
    @ObservationIgnored var generation = 0
    @ObservationIgnored var renderTask: Task<Void, Never>?

    public nonisolated var id: Int { page }
    public var hasPhoto: Bool { source != nil }
    /// The photo as decoded (EXIF orientation applied), for the crop editor; nil until then.
    public var photoImage: CGImage? { photo?.image }
    /// The photo's size after EXIF orientation and the 4K cap: what `crop` is a part of.
    public var photoSize: PhotoSize? { photo?.size }

    init(page: Int) {
        self.page = page
    }

    func setProgress(_ status: PageStatus, _ percent: Int) {
        self.status = status
        self.percent = percent
    }
}

/// What a tile says under its progress bar, whatever the language; `Strings.pageStatus`
/// gives the text.
public enum PageStatus: Sendable, Equatable {
    /// Nothing.
    case blank
    case rendering
    case previewReady
    /// The photo could not be turned into a preview; `name` is the file's name, if known.
    case previewFailed(name: String?, reason: PreviewFailure)
    /// Its push has not reached this page yet.
    case waiting
    case progress(PushProgress)
    /// The push failed before this page was done.
    case unfinished
    case verifying
    case verified(CalendarSession.ProbeResult)
    case notVerified
}

/// One page's push progress, from a push event (gui_model.describe).
public struct PushProgress: Sendable, Equatable {
    public let phase: PushEvent.Phase
    /// The page's place in the upload order (0-based), and how many pages the push sends.
    public let index: Int
    public let count: Int
    /// 0-100: rounded down while sending, 100 once the page is done.
    public let percent: Int

    public init(_ event: PushEvent) {
        phase = event.phase
        index = event.index
        count = event.count
        percent = switch event.phase {
        case .start: 0
        case .sending: event.total > 0 ? event.sent * 100 / event.total : 0
        case .unchanged, .refreshing, .switching, .done: 100
        }
    }
}
