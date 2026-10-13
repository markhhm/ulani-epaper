import Foundation
import UlaniKit

/// What "讀取狀態" shows (Python: gui.default_info).
public struct CalendarStatus: Sendable, Equatable {
    public let battery: Battery
    /// The page on screen (1-4).
    public let shown: Int

    public init(battery: Battery, shown: Int) {
        self.battery = battery
        self.shown = shown
    }
}

/// The calendar work the app does, each call in its own connection. Tests use a fake.
public protocol PushService: Sendable {
    /// Upload `[page: frame]`, the page on screen last (Python: push.push_frames).
    func push(frames: [Int: Frame],
              progress: @escaping @Sendable (PushEvent) -> Void) async throws -> [Int: UploadResult]
    /// Battery and the page on screen.
    func info() async throws -> CalendarStatus
    /// Put `page` on screen, uploading nothing ("在裝置上顯示").
    func display(page: Int) async throws -> CalendarSession.DisplayResult
}

/// The real calendar over CoreBluetooth (or any link the connector makes).
public struct LivePushService: PushService {
    private let connector: CalendarConnector

    public init(connector: CalendarConnector = CalendarConnector { try await CoreBluetoothLink.connect() }) {
        self.connector = connector
    }

    public func push(frames: [Int: Frame],
                     progress: @escaping @Sendable (PushEvent) -> Void) async throws -> [Int: UploadResult] {
        try await connector.withCalendar { session in
            try await session.push(frames, progress: progress)
        }
    }

    public func info() async throws -> CalendarStatus {
        try await connector.withCalendar { session in
            let battery = try await session.battery()
            let shown = try await session.currentSlot().page
            return CalendarStatus(battery: battery, shown: shown)
        }
    }

    public func display(page: Int) async throws -> CalendarSession.DisplayResult {
        try await connector.withCalendar { session in
            try await session.display(page: page)
        }
    }
}
