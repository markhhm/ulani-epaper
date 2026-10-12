import Foundation
import Testing
@testable import UlaniKit

@Suite struct ChecksumTests {
    @Test func crcVectors() throws {
        let cases = try #require(try Vectors.root()["crc"]?.array)
        #expect(cases.count == 5)
        for c in cases {
            let recipe = try #require(c["input"])
            let data = try Vectors.input(recipe)
            #expect(hexNumber(Checksums.crc16(data), digits: 4) == c["crc16"]?.string, "crc16 of \(recipe)")
            #expect(hexNumber(Checksums.crc32(data), digits: 8) == c["crc32"]?.string, "crc32 of \(recipe)")
        }
    }

    @Test func catalogueCheckValues() {
        // CRC-16/XMODEM and CRC-32/ISO-HDLC check values for "123456789".
        let check = Data("123456789".utf8)
        #expect(Checksums.crc16(check) == 0x31C3)
        #expect(Checksums.crc32(check) == 0xCBF4_3926)
        #expect(Checksums.crc16(Data()) == 0)
        #expect(Checksums.crc32(Data()) == 0)
    }

    @Test func sliceWithNonZeroStartIndex() {
        let whole = Data((0..<64).map { UInt8($0) })
        let slice = whole[10..<50]
        #expect(slice.startIndex == 10)
        #expect(Checksums.crc16(slice) == Checksums.crc16(Data(slice)))
        #expect(Checksums.crc32(slice) == Checksums.crc32(Data(slice)))
    }
}
