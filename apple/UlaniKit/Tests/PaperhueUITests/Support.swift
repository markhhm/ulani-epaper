import CoreGraphics
import Foundation
import ImageIO
import UlaniKit
import UniformTypeIdentifiers
@testable import PaperhueUI

/// A push service whose behaviour each test scripts (Python: the fake push_fn / info_fn).
actor FakePushService: PushService {
    typealias PushHandler = @Sendable ([Int: Frame], @escaping @Sendable (PushEvent) -> Void) async throws
        -> [Int: UploadResult]
    typealias InfoHandler = @Sendable () async throws -> CalendarStatus
    typealias ProbeHandler = @Sendable ([Int: Frame]) async throws -> [Int: CalendarSession.ProbeResult]

    private(set) var pushed: [[Int: Frame]] = []
    private(set) var probed: [[Int: Frame]] = []
    private(set) var infoCalls = 0
    private let onPush: PushHandler
    private let onInfo: InfoHandler
    private let onProbe: ProbeHandler

    /// By default every push succeeds (`ok` for every page, with start/sending/done events),
    /// every probe matches and the calendar shows page 1 with a full battery.
    init(push: PushHandler? = nil, info: InfoHandler? = nil, probe: ProbeHandler? = nil) {
        onPush = push ?? { frames, progress in
            let order = frames.keys.sorted()
            for (index, page) in order.enumerated() {
                progress(PushEvent(page: page, phase: .start, index: index, count: order.count, total: 10))
                progress(PushEvent(page: page, phase: .sending, index: index, count: order.count, sent: 5, total: 10))
                progress(PushEvent(page: page, phase: .done, index: index, count: order.count, sent: 10, total: 10))
            }
            return Dictionary(uniqueKeysWithValues: order.map { ($0, UploadResult.ok) })
        }
        onInfo = info ?? { CalendarStatus(battery: Battery(level: 5, charging: false), shown: 1) }
        onProbe = probe ?? { frames in frames.mapValues { _ in .matches } }
    }

    func push(frames: [Int: Frame],
              progress: @escaping @Sendable (PushEvent) -> Void) async throws -> [Int: UploadResult] {
        pushed.append(frames)
        return try await onPush(frames, progress)
    }

    func info() async throws -> CalendarStatus {
        infoCalls += 1
        return try await onInfo()
    }

    func probe(frames: [Int: Frame]) async throws -> [Int: CalendarSession.ProbeResult] {
        probed.append(frames)
        return try await onProbe(frames)
    }
}

/// Counts begin/end calls instead of touching the idle timer.
@MainActor
final class FakeKeepAwake: KeepAwake {
    private(set) var begun = 0
    private(set) var ended = 0
    var isActive: Bool { begun > ended }

    func begin() { begun += 1 }
    func end() { ended += 1 }
}

/// Suspends callers of `wait()` until `open()`.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Counts calls across tasks.
actor Counter {
    private(set) var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}

enum TestImages {
    /// A `width` x `height` image of one opaque colour.
    static func solid(_ width: Int, _ height: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static let red = solid(160, 100, 255, 0, 0)
    static let blue = solid(160, 100, 0, 0, 255)

    /// PNG file contents of `image`.
    static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// The frame the app must produce for `image` with these options.
    static func frame(_ image: CGImage, fit: FitMode = .cover, dither: Bool = true) -> Frame {
        FrameEncoder.encode(image, fit: fit, dither: dither)
    }
}

/// A photo that is at hand at once and "decodes" to `image`.
func photo(_ image: CGImage, name: String = "a.png") -> PhotoSource {
    PhotoSource(name: name) { fetched(image, name: name) }
}

/// Fetched bytes that "decode" to `image`.
func fetched(_ image: CGImage, name: String? = nil) -> FetchedPhoto {
    FetchedPhoto(name: name) { image }
}

/// Polls `condition` until it holds or `timeout` passes (a failing test must not hang).
@MainActor
func eventually(within timeout: Duration = .seconds(60), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// How many callers are between `enter` and `leave`, now and at most.
actor Concurrency {
    private(set) var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() { current -= 1 }
}

/// Whether the caller runs on the main thread (not callable from async code directly).
func onMainThread() -> Bool { Thread.isMainThread }

/// A fresh, empty directory for one test.
func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("paperhue-ui-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
