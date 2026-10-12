import CoreBluetooth
import Foundation

// The parts of CoreBluetoothLink that need no radio: UUID spelling, the advertisement
// filter, discovery bookkeeping, the table of waiting operations and error mapping.

// MARK: - UUIDs

extension GattUUID {
    /// Standard Device Information service (model number, firmware revision).
    static let deviceInformation = "0000180a-0000-1000-8000-00805f9b34fb"

    /// `uuid` in the lower-case 128-bit form of the constants. CoreBluetooth prints 16- and
    /// 32-bit UUIDs short ("A200") and 128-bit ones upper-case.
    static func canonical(_ uuid: String) -> String {
        let lower = uuid.lowercased()
        switch lower.count {
        case 4: return "0000\(lower)-0000-1000-8000-00805f9b34fb"
        case 8: return "\(lower)-0000-1000-8000-00805f9b34fb"
        default: return lower
        }
    }

    /// `uuid` as CoreBluetooth spells it: 16-bit UUIDs short ("A200"), others canonical.
    /// `CBUUID(string:)` keeps the long spelling as 16 bytes, so scan filters and discovery
    /// get the short one.
    static func short(_ uuid: String) -> String {
        let canonical = canonical(uuid)
        let base = "-0000-1000-8000-00805f9b34fb"
        guard canonical.count == 36, canonical.hasPrefix("0000"), canonical.hasSuffix(base) else { return canonical }
        return String(canonical.dropFirst(4).prefix(4)).uppercased()
    }

    static func cbUUID(_ uuid: String) -> CBUUID {
        CBUUID(string: short(uuid))
    }

    static func uuid(of characteristic: GattCharacteristic) -> String {
        switch characteristic {
        case .command: command
        case .image: image
        }
    }

    static func uuid(of characteristic: ReadableCharacteristic) -> String {
        switch characteristic {
        case .modelNumber: modelNumber
        case .firmwareRevision: firmwareRevision
        }
    }

    /// The calendar characteristic with this UUID, if it is one.
    static func characteristic(_ uuid: String) -> GattCharacteristic? {
        switch canonical(uuid) {
        case command: .command
        case image: .image
        default: nil
        }
    }

    /// The Device Information characteristic with this UUID, if it is one we read.
    static func readable(_ uuid: String) -> ReadableCharacteristic? {
        switch canonical(uuid) {
        case modelNumber: .modelNumber
        case firmwareRevision: .firmwareRevision
        default: nil
        }
    }
}

// MARK: - discovery

/// Which services still owe their characteristics after connecting, and whether the
/// required ones turned up. UUIDs in any spelling (see `GattUUID.canonical`).
struct GattDiscovery: Sendable, Equatable {
    /// Services to discover: the calendar service (required) and Device Information (optional:
    /// model and firmware reads, and the read barrier).
    static let services = [GattUUID.service, GattUUID.deviceInformation]

    /// The characteristics wanted from `service`.
    static func characteristics(of service: String) -> [String] {
        switch GattUUID.canonical(service) {
        case GattUUID.service: [GattUUID.command, GattUUID.image]
        case GattUUID.deviceInformation: [GattUUID.modelNumber, GattUUID.firmwareRevision]
        default: []
        }
    }

    private static let required = [(GattUUID.command, "command"), (GattUUID.image, "image")]

    /// Services whose characteristics have not been reported yet.
    private(set) var awaiting: Set<String> = []
    /// Wanted characteristics found so far.
    private(set) var found: Set<String> = []
    private var started = false

    /// Every service reported its characteristics and the required ones are there.
    var isComplete: Bool { started && awaiting.isEmpty }

    /// The peripheral listed its services; returns those to discover characteristics for.
    mutating func servicesDiscovered(_ uuids: [String]) throws -> [String] {
        let present = Set(uuids.map(GattUUID.canonical))
        guard present.contains(GattUUID.service) else {
            throw UlaniError.protocolError("the device service \(GattUUID.service) was not found")
        }
        let next = Self.services.filter(present.contains)
        awaiting = Set(next)
        started = true
        return next
    }

    /// `service` reported `uuids` (none when that failed). Returns true when this completes
    /// the discovery, at most once; throws when a required characteristic is missing.
    mutating func characteristicsDiscovered(_ uuids: [String], of service: String) throws -> Bool {
        let service = GattUUID.canonical(service)
        guard awaiting.remove(service) != nil else { return false }
        let wanted = Set(Self.characteristics(of: service))
        found.formUnion(uuids.map(GattUUID.canonical).filter(wanted.contains))
        guard awaiting.isEmpty else { return false }
        if let (_, name) = Self.required.first(where: { !found.contains($0.0) }) {
            throw UlaniError.protocolError("the device's \(name) characteristic was not found")
        }
        return true
    }
}

// MARK: - waiting operations

/// Continuations of a link's outstanding operations, oldest first per key. Whoever removes
/// an entry resumes it, so each is resumed exactly once. Not synchronised: the owner
/// confines it to one serial queue.
struct PendingOperations<Key: Hashable & Sendable>: Sendable {
    typealias Resume = @Sendable (Result<Data, any Error>) -> Void

    private struct Entry: Sendable {
        let id: Int
        /// nil: abandoned, kept as a placeholder for the answer still on its way.
        var resume: Resume?
    }

    private var entries: [Key: [Entry]] = [:]

    var isEmpty: Bool { entries.isEmpty }

    mutating func add(_ key: Key, id: Int, resume: @escaping Resume) {
        entries[key, default: []].append(Entry(id: id, resume: resume))
    }

    /// A live operation is waiting on `key`.
    func isWaiting(_ key: Key) -> Bool {
        entries[key]?.contains { $0.resume != nil } ?? false
    }

    /// The key of live operation `id`.
    func key(of id: Int) -> Key? {
        entries.first { $0.value.contains { $0.id == id && $0.resume != nil } }?.key
    }

    /// Answer the oldest entry on `key` (one request, one answer). Returns whether it was
    /// live; a placeholder just takes its answer.
    @discardableResult
    mutating func resumeFirst(_ key: Key, with result: Result<Data, any Error>) -> Bool {
        guard var list = entries[key], !list.isEmpty else { return false }
        let entry = list.removeFirst()
        entries[key] = list.isEmpty ? nil : list
        entry.resume?(result)
        return entry.resume != nil
    }

    /// Answer every entry on `key` (an event all of them wait for). Returns how many were live.
    @discardableResult
    mutating func resumeAll(_ key: Key, with result: Result<Data, any Error>) -> Int {
        let list = entries.removeValue(forKey: key) ?? []
        let live = list.compactMap(\.resume)
        live.forEach { $0(result) }
        return live.count
    }

    /// Answer live operation `id`. Returns whether there was one.
    @discardableResult
    mutating func resume(_ id: Int, with result: Result<Data, any Error>) -> Bool {
        guard let (key, index) = locate(id) else { return false }
        let entry = entries[key]!.remove(at: index)
        if entries[key]!.isEmpty { entries[key] = nil }
        entry.resume?(result)
        return true
    }

    /// Fail live operation `id` with `error` now (it was cancelled). `keepingPlace`: its
    /// request is still answered later, so leave a placeholder that takes that answer.
    /// Returns its key, nil when it was not live.
    @discardableResult
    mutating func abandon(_ id: Int, with error: any Error, keepingPlace: Bool) -> Key? {
        guard let (key, index) = locate(id) else { return nil }
        let resume = entries[key]![index].resume
        if keepingPlace {
            entries[key]![index].resume = nil
        } else {
            entries[key]!.remove(at: index)
            if entries[key]!.isEmpty { entries[key] = nil }
        }
        resume?(.failure(error))
        return key
    }

    /// Fail everything (the link closed). Returns how many were live.
    @discardableResult
    mutating func resumeEverything(with error: any Error) -> Int {
        let all = entries.values.flatMap { $0 }.sorted { $0.id < $1.id }.compactMap(\.resume)
        entries = [:]
        all.forEach { $0(.failure(error)) }
        return all.count
    }

    private func locate(_ id: Int) -> (Key, Int)? {
        for (key, list) in entries {
            if let index = list.firstIndex(where: { $0.id == id && $0.resume != nil }) { return (key, index) }
        }
        return nil
    }
}

// MARK: - errors and manager state

extension CoreBluetoothLink {
    /// Whether the central manager can be used.
    enum Readiness: Sendable, Equatable {
        case ready
        /// Unknown or resetting: wait for the next state update.
        case pending
        case unavailable(UlaniError)
    }

    static func readiness(of state: CBManagerState) -> Readiness {
        switch state {
        case .poweredOn: .ready
        case .poweredOff: .unavailable(.bluetoothUnavailable("Bluetooth is off"))
        case .unauthorized: .unavailable(.bluetoothUnavailable("this app is not allowed to use Bluetooth"))
        case .unsupported: .unavailable(.bluetoothUnavailable("this device does not support Bluetooth LE"))
        case .unknown, .resetting: .pending
        @unknown default: .pending
        }
    }

    /// Why the link ends when the manager leaves `.poweredOn` (CoreBluetooth then drops
    /// every connection without calling didDisconnect); nil while powered on.
    static func stateChangeError(_ state: CBManagerState) -> UlaniError? {
        switch readiness(of: state) {
        case .ready: nil
        case .unavailable(let error): error
        case .pending: .linkLost("Bluetooth was reset")
        }
    }

    /// The UlaniError for `error`, reported by CoreBluetooth while `step` ("connecting").
    /// A lost bond needs the user (forget the calendar, pair again); anything else is a link
    /// failure, which the connector retries.
    static func ulaniError(for error: any Error, during step: String) -> UlaniError {
        if let error = error as? UlaniError { return error }
        if isBondLost(error) { return .bondLost }
        return .linkLost("\(step) failed: \(describe(error))")
    }

    /// The peripheral forgot us, or a characteristic needs a bond we do not have.
    static func isBondLost(_ error: any Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case CBErrorDomain:
            return error.code == CBError.Code.peerRemovedPairingInformation.rawValue
        case CBATTErrorDomain:
            return [CBATTError.Code.insufficientAuthentication, .insufficientEncryption,
                    .insufficientEncryptionKeySize].map(\.rawValue).contains(error.code)
        default:
            return false
        }
    }

    /// Short English text for a CoreBluetooth error (their localizedDescription is generic).
    private static func describe(_ error: any Error) -> String {
        let error = error as NSError
        switch error.domain {
        case CBErrorDomain:
            let name = cbErrorNames[error.code].map { "\($0), " } ?? ""
            return "\(name)CBError \(error.code)"
        case CBATTErrorDomain:
            return "ATT error 0x\(Data([UInt8(truncatingIfNeeded: error.code)]).hexString())"
        default:
            return error.localizedDescription
        }
    }

    private static let cbErrorNames: [Int: String] = [
        0: "unknown error", 1: "invalid parameters", 2: "invalid handle", 3: "not connected",
        4: "out of space", 5: "operation cancelled", 6: "connection timeout",
        7: "peripheral disconnected", 8: "UUID not allowed", 9: "already advertising",
        10: "connection failed", 11: "connection limit reached", 12: "unknown device",
        13: "operation not supported", 14: "peer removed pairing information",
        15: "encryption timed out", 16: "too many LE paired devices",
    ]

    /// client.find(): the 16-bit service A200 is advertised, or the local name starts "ULANI".
    static func isCalendar(advertisedServices: [String], localName: String?) -> Bool {
        advertisedServices.contains { GattUUID.canonical($0) == GattUUID.advertisedService }
            || (localName ?? "").hasPrefix("ULANI")
    }
}
