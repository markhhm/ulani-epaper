import Foundation

/// The two calendar characteristics: commands (`...A201`, write + notify) and image data
/// (`...A202`, write-without-response + notify).
public enum GattCharacteristic: Sendable {
    case command, image
}

/// Standard Device Information characteristics the session reads (the firmware revision
/// also serves as the read barrier).
public enum ReadableCharacteristic: Sendable {
    case modelNumber, firmwareRevision
}

/// One notification from the calendar.
public struct GattNotification: Sendable, Equatable {
    public let characteristic: GattCharacteristic
    public let value: Data

    public init(characteristic: GattCharacteristic, value: Data) {
        self.characteristic = characteristic
        self.value = value
    }
}

/// A connected, subscribed GATT link to the calendar. `CalendarSession` speaks the
/// protocol on top of it; CoreBluetooth, the TCP relay and the test fake implement it.
///
/// Transport failures must be thrown as `UlaniError` (`linkLost`, `notFound`, `bondLost`,
/// `bluetoothUnavailable`), never as raw CBError / NSError / NWError: `CalendarConnector`
/// retries only UlaniErrors (Python also retries BleakError, OSError and TimeoutError).
public protocol GattLink: AnyObject, Sendable {
    /// Notifications from both characteristics, in arrival order. Single consumer.
    var notifications: AsyncStream<GattNotification> { get }
    /// Largest write-without-response payload right now (CoreBluetooth: maximumWriteValueLength(for: .withoutResponse)).
    func maximumWriteLength() async -> Int
    /// Write with response to the command characteristic.
    func writeCommand(_ data: Data) async throws
    func read(_ characteristic: ReadableCharacteristic) async throws -> Data
    /// Stream `data` to the image characteristic in `chunkSize` pieces with the link's own flow
    /// control. Calls `progress(sent, total)` after each chunk and stops early (returns) as soon
    /// as `shouldStop()` is true before a chunk. Returns bytes sent. `shouldStop` is
    /// thread-safe and also turns true when the calling task is cancelled; a link that cannot
    /// ask it per chunk (the relay streams on its side) must end the stream on cancellation.
    func streamImage(_ data: Data, chunkSize: Int,
                     progress: @escaping @Sendable (Int, Int) -> Void,
                     shouldStop: @escaping @Sendable () -> Bool) async throws -> Int
    func disconnect() async
}
