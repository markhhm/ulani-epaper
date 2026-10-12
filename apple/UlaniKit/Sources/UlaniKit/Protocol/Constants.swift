import Foundation

// Wire constants of the ULANI calendar (P7320E-B). Mirrors the constants in
// python/src/ulani_epaper/protocol.py; see shared/PROTOCOL.md.

/// Panel geometry and transfer limits.
public enum Panel {
    public static let width = 800
    public static let height = 480
    public static let pixelsPerByte = 2
    public static let frameBytes = width * height / pixelsPerByte
    /// Slots 1-4 are the four pages the button cycles through. Firmware v1.0.09 does not
    /// answer headers for slots outside 1-4 (tried with 16), so only 1-4 are used.
    public static let userSlots: ClosedRange<Int> = 1...4
    /// Header "mode" byte. Paperhue always sends 1 (tested); other values are untested.
    public static let defaultMode: UInt8 = 1
    /// Largest image chunk written per packet.
    public static let maxChunk = 230
}

/// GATT UUIDs (lower-case, as in protocol.py; compare case-insensitively).
public enum GattUUID {
    /// 16-bit service the calendar advertises (used for scanning).
    public static let advertisedService = "0000a200-0000-1000-8000-00805f9b34fb"
    public static let service = "1234a200-7cbc-11e9-8f9e-2a86e4085a59"
    /// Commands are written here; replies arrive as notifications here.
    public static let command = "1234a201-7cbc-11e9-8f9e-2a86e4085a59"
    /// Raw image data is streamed here; the final result is notified here.
    public static let image = "1234a202-7cbc-11e9-8f9e-2a86e4085a59"
    public static let modelNumber = "00002a24-0000-1000-8000-00805f9b34fb"
    public static let firmwareRevision = "00002a26-0000-1000-8000-00805f9b34fb"
}

/// First byte of every command and of its reply.
public enum Opcode {
    public static let imageHeader: UInt8 = 0x01
    public static let imageData: UInt8 = 0x02
    public static let unlock: UInt8 = 0x04
    /// Notified unasked right after connecting (`05 00`).
    public static let deviceReady: UInt8 = 0x05
    public static let battery: UInt8 = 0x06
    public static let disconnect: UInt8 = 0x09
    public static let deviceInfo: UInt8 = 0x0A
    /// Switches the page shown (`0B nn` -> `0B 00`), like pressing the calendar's button.
    public static let showSlot: UInt8 = 0x0B
    public static let getSlot: UInt8 = 0x0C
}

/// Fixed commands, written to the command characteristic.
public enum Command {
    /// Unlock (`04` + ASCII "NB"), sent at the start of every session; the reply is `04 00`.
    public static let unlock = Data([0x04, 0x4E, 0x42])
    public static let battery = Data([0x06, 0x00])
    public static let deviceInfo = Data([0x0A, 0x00])
    public static let getSlot = Data([0x0C, 0x00])
    public static let disconnect = Data([0x09, 0x03])
}

/// Fixed replies.
public enum Reply {
    public static let unlockOK = Data([0x04, 0x00])
    public static let headerOK = Data([0x01, 0x00])
    public static let headerBusy = Data([0x01, 0x01])
    public static let headerSameImage = Data([0x01, 0x02])
    public static let dataOK = Data([0x02, 0x00])
    public static let dataFail = Data([0x02, 0x01])
    public static let showSlotOK = Data([0x0B, 0x00])
    public static let deviceReady = Data([0x05, 0x00])
    /// Battery reply value meaning "charging" (`06 06`).
    public static let batteryCharging: UInt8 = 6
}
