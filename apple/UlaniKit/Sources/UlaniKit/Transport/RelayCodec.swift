import Foundation

// Messages of `python -m ulani_epaper.relay`: one JSON object per line (UTF-8,
// `\n`-terminated), bytes as lower-case hex. See python/src/ulani_epaper/relay.py.

/// A request to the relay. The relay answers each with `ok` (plus fields) or an error,
/// strictly in the order sent.
enum RelayRequest: Sendable, Equatable {
    /// -> `relay` (protocol version) and `fake`.
    case hello
    /// Scan for (or look up `address`) and connect the calendar, subscribe both
    /// characteristics -> `write_length`.
    case connect(address: String?, scanTimeout: Duration)
    /// Write `data`; with response on the command characteristic.
    case write(GattCharacteristic, Data)
    /// -> `data`.
    case read(ReadableCharacteristic)
    /// Stream a whole image on the relay host, reading the firmware revision every
    /// `flushEvery` chunks (0: never), until done or the calendar answers on the image
    /// characteristic -> `sent`; `progress` events meanwhile.
    case stream(Data, chunk: Int, flushEvery: Int)
    /// -> `write_length`.
    case writeLength
    case disconnect
}

/// Fields of an `ok` answer (which ones depends on the request).
struct RelayResult: Sendable, Equatable {
    var relay: Int?
    var fake: Bool?
    var writeLength: Int?
    var data: Data?
    var sent: Int?
}

/// An error answer: `kind` is not_found, link, timeout or protocol.
struct RelayFailure: Error, Sendable, Equatable {
    let kind: String
    let message: String

    /// What UlaniKit throws for it. `timeout` (a Bluetooth connect, write or read timed out
    /// on the relay host, after up to 30 s) is `linkLost`, not `noReply`: like Python's
    /// TimeoutError, the connector retries it but `whenReady` does not take it for a
    /// silent, refreshing calendar.
    var ulaniError: UlaniError {
        switch kind {
        case "not_found": .notFound
        case "timeout": .linkLost("timed out on the relay (\(message))")
        case "protocol": .protocolError(message)
        default: .linkLost(message)  // "link", or a kind this version does not know
        }
    }
}

/// One line from the relay.
enum RelayMessage: Sendable, Equatable {
    /// The answer to request `id` (nil: the relay could not read a request, or refused us).
    case success(id: Int?, RelayResult)
    case failure(id: Int?, RelayFailure)
    /// A notification from the calendar.
    case notify(GattNotification)
    /// Bytes streamed so far by the `stream` request `id`.
    case progress(id: Int?, sent: Int, total: Int)
    /// The calendar dropped the Bluetooth link (the relay stays connected).
    case disconnected(reason: String)
    /// An event this version does not know; ignore it.
    case unknownEvent(String)
}

enum RelayCodec {
    /// The request as one line, `\n` included.
    static func encode(_ request: RelayRequest, id: Int) throws -> Data {
        var line = try encoder.encode(Envelope(id: id, request: request))
        line.append(0x0A)
        return line
    }

    /// Parse one line (without its `\n`). Throws `protocolError` for anything malformed.
    static func decode(_ line: Data) throws -> RelayMessage {
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: line)
        } catch {
            throw invalid(line, "not a JSON object of the expected shape")
        }
        if let event = wire.event {
            switch event {
            case "notify":
                let characteristic: GattCharacteristic
                switch wire.char {
                case "command": characteristic = .command
                case "image": characteristic = .image
                default: throw invalid(line, "unknown characteristic")
                }
                guard let hex = wire.data else { throw invalid(line, "notification without data") }
                return .notify(GattNotification(characteristic: characteristic, value: try bytes(hex, line)))
            case "progress":
                guard let sent = wire.sent, let total = wire.total else { throw invalid(line, "incomplete progress") }
                return .progress(id: wire.id, sent: sent, total: total)
            case "disconnected":
                return .disconnected(reason: wire.reason ?? "the device dropped the link")
            default:
                return .unknownEvent(event)
            }
        }
        switch wire.ok {
        case true?:
            let data = try wire.data.map { try bytes($0, line) }
            return .success(id: wire.id, RelayResult(relay: wire.relay, fake: wire.fake, writeLength: wire.writeLength,
                                                     data: data, sent: wire.sent))
        case false?:
            return .failure(id: wire.id, RelayFailure(kind: wire.kind ?? "link", message: wire.error ?? "relay error"))
        case nil:
            throw invalid(line, "neither an answer nor an event")
        }
    }

    // MARK: - wire

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private enum Key: String, CodingKey {
        case id, op, address, char, data, chunk
        case scanTimeout = "scan_timeout", flushEvery = "flush_every"
    }

    private struct Envelope: Encodable {
        let id: Int
        let request: RelayRequest

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(id, forKey: .id)
            switch request {
            case .hello:
                try c.encode("hello", forKey: .op)
            case .connect(let address, let scanTimeout):
                try c.encode("connect", forKey: .op)
                if let address {
                    try c.encode(address, forKey: .address)
                } else {
                    try c.encodeNil(forKey: .address)  // the first calendar found
                }
                let (seconds, attoseconds) = scanTimeout.components
                if attoseconds == 0 {
                    try c.encode(seconds, forKey: .scanTimeout)
                } else {
                    try c.encode(Double(seconds) + Double(attoseconds) / 1e18, forKey: .scanTimeout)
                }
            case .write(let characteristic, let data):
                try c.encode("write", forKey: .op)
                try c.encode(characteristic == .command ? "command" : "image", forKey: .char)
                try c.encode(hex(data), forKey: .data)
            case .read(let characteristic):
                try c.encode("read", forKey: .op)
                try c.encode(characteristic == .modelNumber ? "model_number" : "firmware_revision", forKey: .char)
            case .stream(let data, let chunk, let flushEvery):
                try c.encode("stream", forKey: .op)
                try c.encode(hex(data), forKey: .data)
                try c.encode(chunk, forKey: .chunk)
                try c.encode(flushEvery, forKey: .flushEvery)
            case .writeLength:
                try c.encode("write_length", forKey: .op)
            case .disconnect:
                try c.encode("disconnect", forKey: .op)
            }
        }
    }

    /// Every field any relay message has; which are set depends on the message.
    private struct Wire: Decodable {
        var id: Int?
        var ok: Bool?
        var event: String?
        var error: String?
        var kind: String?
        var char: String?
        var data: String?
        var sent: Int?
        var total: Int?
        var reason: String?
        var relay: Int?
        var fake: Bool?
        var writeLength: Int?

        private enum CodingKeys: String, CodingKey {
            case id, ok, event, error, kind, char, data, sent, total, reason, relay, fake
            case writeLength = "write_length"
        }
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// Lower-case hex; fast enough for a whole frame (384 000 characters).
    static func hex(_ data: Data) -> String {
        var out = [UInt8](repeating: 0, count: data.count * 2)
        data.withUnsafeBytes { raw in
            out.withUnsafeMutableBufferPointer { out in
                for (i, byte) in raw.enumerated() {
                    out[2 * i] = hexDigits[Int(byte >> 4)]
                    out[2 * i + 1] = hexDigits[Int(byte & 0x0F)]
                }
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func bytes(_ hex: String, _ line: Data) throws -> Data {
        let digits = Array(hex.utf8)
        guard digits.count % 2 == 0 else { throw invalid(line, "odd-length hex") }
        var out = Data(capacity: digits.count / 2)
        var i = 0
        while i < digits.count {
            guard let high = nibble(digits[i]), let low = nibble(digits[i + 1]) else {
                throw invalid(line, "not hex")
            }
            out.append(high << 4 | low)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    private static func invalid(_ line: Data, _ problem: String) -> UlaniError {
        let text = String(decoding: line.prefix(200), as: UTF8.self)
        return .protocolError("the relay sent an invalid message (\(problem)): \(text)")
    }
}
