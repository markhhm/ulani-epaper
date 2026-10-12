import Foundation

/// Every error UlaniKit throws on purpose.
public enum UlaniError: Error, Sendable, Equatable {
    case noReply(opcode: UInt8)                     // a command got no answer in replyTimeout
    case deviceBusy(what: String)                   // silent/busy for busyTimeout
    case unlockRejected(Data)
    case unexpectedHeaderReply(page: Int, reply: Data)
    case uploadFailed(page: Int, reply: Data)
    /// The device sent something unexpected, or a message could not be built.
    case protocolError(String)
    case notFound                                   // no advertising device
    case connectFailed(attempts: Int, last: String)
    case bondLost                                   // peerRemovedPairingInformation / insufficient auth/encryption
    case bluetoothUnavailable(String)               // powered off / unauthorized / unsupported
    case linkLost(String)
}

/// A push stopped at `page`; the pages before it are in `completed` (Python: the
/// UlaniError's `.slot` / `.results`). The remaining pages were not sent.
public struct PushError: Error, Sendable, Equatable {
    public let page: Int
    public let completed: [Int: UploadResult]
    public let underlying: UlaniError

    public init(page: Int, completed: [Int: UploadResult], underlying: UlaniError) {
        self.page = page
        self.completed = completed
        self.underlying = underlying
    }
}

// MARK: - classification

extension UlaniError {
    /// The UlaniError behind `error`: the error itself or the cause of a PushError.
    public static func from(_ error: any Error) -> UlaniError? {
        if let error = error as? UlaniError { return error }
        if let error = error as? PushError { return error.underlying }
        return nil
    }

    /// Whether setting up the connection again can help (see CalendarConnector). A lost
    /// bond or Bluetooth being off needs the user; not finding the device, link drops
    /// and silence (it refreshes for ~40 s) are often transient.
    public var isRetryable: Bool {
        switch self {
        case .bondLost, .bluetoothUnavailable: false
        default: true
        }
    }
}

// MARK: - messages (English, technical; the app shows its own zh-TW text)

extension UlaniError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noReply(let opcode):
            "no reply to opcode 0x\(Data([opcode]).hexString())"
        case .deviceBusy(let what):
            "the device did not accept \(what) in time (still refreshing?); try again in a minute"
        case .unlockRejected(let reply):
            "unlock rejected: \(reply.hexString(separator: " "))"
        case .unexpectedHeaderReply(let page, let reply):
            "page \(page): unexpected header reply: \(reply.hexString(separator: " "))"
        case .uploadFailed(let page, let reply):
            "page \(page): device reported failure: \(reply.hexString(separator: " "))"
        case .protocolError(let message):
            message
        case .notFound:
            "no e-paper device found (is Bluetooth on and the device nearby?)"
        case .connectFailed(let attempts, let last):
            "could not connect after \(attempts) attempts: \(last)"
        case .bondLost:
            "the device is no longer paired with this computer: forget it in the Bluetooth settings, "
                + "hold its button ~5 s and pair again"
        case .bluetoothUnavailable(let reason):
            "Bluetooth unavailable: \(reason)"
        case .linkLost(let reason):
            "Bluetooth link lost: \(reason)"
        }
    }
}

extension PushError: CustomStringConvertible {
    /// Starts with "page N:", like the Python error messages.
    public var description: String {
        let message = underlying.description
        return message.hasPrefix("page \(page):") ? message : "page \(page): \(message)"
    }
}
