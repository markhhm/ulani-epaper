import Foundation
import Testing
@testable import UlaniKit

/// JSON-lines messages of `python -m ulani_epaper.relay` (wire format: python/src/ulani_epaper/relay.py).
@Suite struct RelayCodecTests {
    /// The request line as a JSON object (key order does not matter on the wire).
    private func object(_ line: Data) throws -> NSDictionary {
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)  // exactly one line
        return try #require(try JSONSerialization.jsonObject(with: line) as? NSDictionary)
    }

    private func line(_ json: String) -> Data { Data(json.utf8) }

    // MARK: requests

    @Test func hello() throws {
        #expect(try object(RelayCodec.encode(.hello, id: 1)) == ["id": 1, "op": "hello"])
    }

    @Test func connectSendsANullAddressAndTheScanTime() throws {
        let request = try object(RelayCodec.encode(.connect(address: nil, scanTimeout: .seconds(30)), id: 2))
        #expect(request == ["id": 2, "op": "connect", "address": NSNull(), "scan_timeout": 30])
        let named = try object(RelayCodec.encode(.connect(address: "ULANI-FAKE", scanTimeout: .milliseconds(2500)), id: 3))
        #expect(named == ["id": 3, "op": "connect", "address": "ULANI-FAKE", "scan_timeout": 2.5])
    }

    @Test func writeIsLowerCaseHex() throws {
        #expect(try object(RelayCodec.encode(.write(.command, Command.unlock), id: 3))
                == ["id": 3, "op": "write", "char": "command", "data": "044e42"])
        #expect(try object(RelayCodec.encode(.write(.image, Data([0xAB, 0x0F, 0x00])), id: 4))
                == ["id": 4, "op": "write", "char": "image", "data": "ab0f00"])
    }

    @Test func read() throws {
        #expect(try object(RelayCodec.encode(.read(.firmwareRevision), id: 4))
                == ["id": 4, "op": "read", "char": "firmware_revision"])
        #expect(try object(RelayCodec.encode(.read(.modelNumber), id: 5))
                == ["id": 5, "op": "read", "char": "model_number"])
    }

    @Test func streamCarriesTheWholeFrame() throws {
        let frame = patternFrame()
        let request = try object(RelayCodec.encode(.stream(frame.bytes, chunk: 230, flushEvery: 10), id: 5))
        #expect(request["op"] as? String == "stream")
        #expect(request["id"] as? Int == 5)
        #expect(request["chunk"] as? Int == 230)
        #expect(request["flush_every"] as? Int == 10)
        let hex = try #require(request["data"] as? String)
        #expect(hex.count == 2 * Frame.byteCount)
        #expect(hex.hasPrefix("000102030405"))
        #expect(hex == frame.bytes.hexString())  // lower-case, every byte
        #expect(request.count == 5)
    }

    @Test func writeLengthAndDisconnect() throws {
        #expect(try object(RelayCodec.encode(.writeLength, id: 6)) == ["id": 6, "op": "write_length"])
        #expect(try object(RelayCodec.encode(.disconnect, id: 7)) == ["id": 7, "op": "disconnect"])
    }

    @Test func hexOfASlice() throws {
        // Data slices keep their parent's indices.
        let slice = Data([0x00, 0x11, 0xFE, 0xFF])[2...]
        #expect(try object(RelayCodec.encode(.write(.image, slice), id: 8))["data"] as? String == "feff")
    }

    // MARK: answers

    @Test func okAnswers() throws {
        #expect(try RelayCodec.decode(line(#"{"id":1,"ok":true,"relay":1,"fake":false}"#))
                == .success(id: 1, RelayResult(relay: 1, fake: false)))
        #expect(try RelayCodec.decode(line(#"{"id":2,"ok":true,"write_length":244}"#))
                == .success(id: 2, RelayResult(writeLength: 244)))
        #expect(try RelayCodec.decode(line(#"{"id":3,"ok":true}"#)) == .success(id: 3, RelayResult()))
        #expect(try RelayCodec.decode(line(#"{"id":4,"ok":true,"data":"76312e302e3039"}"#))
                == .success(id: 4, RelayResult(data: Data("v1.0.09".utf8))))
        #expect(try RelayCodec.decode(line(#"{"id":5,"ok":true,"sent":192000}"#))
                == .success(id: 5, RelayResult(sent: 192_000)))
    }

    @Test func errorWithKind() throws {
        #expect(try RelayCodec.decode(line(#"{"id":2,"ok":false,"error":"no device found","kind":"not_found"}"#))
                == .failure(id: 2, RelayFailure(kind: "not_found", message: "no device found")))
        // The relay could not read a request, or refused a second client: no id.
        #expect(try RelayCodec.decode(line(
            #"{"id":null,"ok":false,"error":"the relay is busy: another client is connected","kind":"link"}"#))
                == .failure(id: nil, RelayFailure(kind: "link", message: "the relay is busy: another client is connected")))
    }

    @Test(arguments: [
        ("not_found", UlaniError.notFound),
        ("link", UlaniError.linkLost("boom")),
        ("timeout", UlaniError.linkLost("timed out on the relay (boom)")),
        ("protocol", UlaniError.protocolError("boom")),
        ("something_new", UlaniError.linkLost("boom")),
    ])
    func errorKindsMapToUlaniError(kind: String, expected: UlaniError) {
        #expect(RelayFailure(kind: kind, message: "boom").ulaniError == expected)
    }

    @Test func notify() throws {
        #expect(try RelayCodec.decode(line(#"{"event":"notify","char":"command","data":"0400"}"#))
                == .notify(GattNotification(characteristic: .command, value: Reply.unlockOK)))
        #expect(try RelayCodec.decode(line(#"{"event":"notify","char":"image","data":"0201"}"#))
                == .notify(GattNotification(characteristic: .image, value: Reply.dataFail)))
        #expect(try RelayCodec.decode(line(#"{"event":"notify","char":"command","data":"0A0b"}"#))
                == .notify(GattNotification(characteristic: .command, value: Data([0x0A, 0x0B]))))
    }

    @Test func progress() throws {
        #expect(try RelayCodec.decode(line(#"{"event":"progress","id":5,"sent":2300,"total":192000}"#))
                == .progress(id: 5, sent: 2300, total: 192_000))
    }

    @Test func disconnected() throws {
        #expect(try RelayCodec.decode(line(#"{"event":"disconnected","reason":"the device dropped the link"}"#))
                == .disconnected(reason: "the device dropped the link"))
    }

    @Test func unknownEventsAreReported() throws {
        #expect(try RelayCodec.decode(line(#"{"event":"log","text":"hi"}"#)) == .unknownEvent("log"))
    }

    @Test(arguments: [
        "",
        "not json",
        "[1,2]",
        #"{"id":1}"#,                                              // neither ok nor event
        #"{"id":1,"ok":true,"data":"0g"}"#,                        // not hex
        #"{"id":1,"ok":true,"data":"040"}"#,                       // odd length
        #"{"event":"notify","char":"battery","data":"0400"}"#,     // unknown characteristic
        #"{"event":"notify","char":"command"}"#,                   // no data
        #"{"event":"progress","id":5,"sent":2300}"#,               // no total
        #"{"id":"one","ok":true}"#,                                // we only send integer ids
    ])
    func malformedLinesAreProtocolErrors(json: String) {
        #expect {
            _ = try RelayCodec.decode(line(json))
        } throws: { error in
            guard case .protocolError(let message) = error as? UlaniError else { return false }
            return message.contains("relay")
        }
    }
}
