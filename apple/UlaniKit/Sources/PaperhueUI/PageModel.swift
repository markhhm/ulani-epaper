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
    public internal(set) var status = ""
    /// 0-100.
    public internal(set) var percent = 0
    public internal(set) var isRendering = false
    /// The last photo chosen for this page could not be read.
    public internal(set) var failed = false

    /// The chosen photo and, once decoded, the decoded image (re-renders reuse it).
    var source: PhotoSource?
    @ObservationIgnored var photo: LoadedPhoto?
    /// Bumped by every new render or clear: a render whose generation is no longer the
    /// page's is stale and its result is dropped.
    @ObservationIgnored var generation = 0
    @ObservationIgnored var renderTask: Task<Void, Never>?

    public nonisolated var id: Int { page }
    public var hasPhoto: Bool { source != nil }

    init(page: Int) {
        self.page = page
    }

    func setProgress(_ text: String, _ percent: Int) {
        status = text
        self.percent = percent
    }
}
