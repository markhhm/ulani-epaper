import CoreBluetooth
import Foundation
import os

/// `GattLink` over CoreBluetooth: the app's link to the device.
///
/// `connect` sets the link up the way `client.connect()` does in one attempt (the
/// connector retries): wait until Bluetooth is on, scan for the advertised service A200,
/// connect (CoreBluetooth never gives up, so the link does after `connectTimeout`), give
/// the MTU exchange up to 3 s, discover the calendar and Device Information services and
/// enable notifications on both calendar characteristics. Both need a bonded link: the first
/// access makes the system ask to pair. The session then unlocks.
///
/// Image chunks are written without response while `canSendWriteWithoutResponse` holds,
/// otherwise after `peripheralIsReady(toSendWriteWithoutResponse:)`; unlike WinRT, nothing
/// is dropped, so the session needs no read barrier (`readBarrierEvery` stays a fallback).
/// Like `client.upload`, the stream stops before the next chunk once the calendar answered
/// on the image characteristic (it gave up), also while it waits for room.
///
/// Concurrency: one private serial queue runs the central manager and every delegate
/// callback, and is the only place the link's mutable state is touched; it is the lock
/// behind `@unchecked Sendable`. An async operation registers its continuation in
/// `pending` on that queue, in the same block as the CoreBluetooth call that starts it.
/// Its callback, its timeout, cancellation or the link closing removes it and resumes it,
/// exactly once. The link closes (and everything waiting fails) on disconnect, when the
/// calendar drops it, when Bluetooth leaves `.poweredOn` and when a GATT request times out.
public final class CoreBluetoothLink: GattLink, @unchecked Sendable {
    /// What an operation waits for.
    enum OperationKey: Hashable, Sendable, CustomStringConvertible {
        case power, scan, connect, discovery
        case notify(GattCharacteristic)
        /// A write with response to the command characteristic.
        case write
        case read(ReadableCharacteristic)
        /// Room for the next image chunk.
        case ready
        /// The disconnection to complete.
        case disconnect

        /// CoreBluetooth answers each such request with exactly one callback, so a cancelled
        /// one keeps its place (see `PendingOperations.abandon`).
        var isRequest: Bool {
            switch self {
            case .notify, .write, .read: true
            default: false
            }
        }

        var description: String {
            switch self {
            case .power: "Bluetooth power"
            case .scan: "scanning"
            case .connect: "connecting"
            case .discovery: "service discovery"
            case .notify(let characteristic): "enabling \(characteristic) notifications"
            case .write: "a command write"
            case .read(let characteristic): "a \(Self.name(characteristic)) read"
            case .ready: "room to send image data"
            case .disconnect: "disconnecting"
            }
        }

        static func name(_ characteristic: ReadableCharacteristic) -> String {
            switch characteristic {
            case .modelNumber: "model number"
            case .firmwareRevision: "firmware revision"
            }
        }
    }

    /// How long each step may take. Internal so tests can shorten them.
    struct Timeouts: Sendable {
        /// For Bluetooth to report its state; long enough to answer the permission prompt.
        var power: Duration = .seconds(60)
        var scan: Duration = .seconds(30)
        var connect: Duration = .seconds(30)
        /// For the MTU exchange after connecting; the setup continues anyway.
        var writeLength: Duration = .seconds(3)
        /// For enabling notifications, the first access that needs the bond: on first
        /// contact it includes the system pairing dialog.
        var subscribe: Duration = .seconds(60)
        /// For one other GATT request (discovery, a write, a read, room to send).
        /// ATT itself gives up after 30 s; running out closes the link.
        var operation: Duration = .seconds(30)
        /// For the disconnection to complete after cancelling the connection.
        var close: Duration = .seconds(5)
    }

    /// Write length before the MTU exchange (23 - 3).
    static let minimumWriteLength = 20
    static let notConnected = UlaniError.linkLost("not connected to the device")
    private static let logger = Logger(subsystem: "UlaniKit", category: "CoreBluetoothLink")

    public let notifications: AsyncStream<GattNotification>
    let timeouts: Timeouts
    private let incoming: AsyncStream<GattNotification>.Continuation
    private let queue = DispatchQueue(label: "UlaniKit.CoreBluetoothLink")
    private let delegate = CoreBluetoothDelegate()
    private let lastID = OSAllocatedUnfairLock(initialState: 0)

    // Confined to `queue`.
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristics: [GattCharacteristic: CBCharacteristic] = [:]
    private var readables: [ReadableCharacteristic: CBCharacteristic] = [:]
    /// Where image chunks go once discovered; tests put a fake here.
    var imageWriter: (any ImageWriter)?
    /// Notifications from the image characteristic so far: a stream stops once it grows.
    private var imageReplies = 0
    private var discovery = GattDiscovery()
    private var pending = PendingOperations<OperationKey>()
    /// Bluetooth was on: leaving `.poweredOn` from now on ends the link.
    private var poweredOn = false
    /// Why the link is over; set once.
    private var closed: UlaniError?

    /// Find the nearest calendar and connect to it. Throws UlaniErrors: `notFound` (nothing
    /// advertised within `scanTimeout`), `bluetoothUnavailable`, `bondLost`, `linkLost`
    /// (connect timeout, link dropped, a step failed) or `protocolError` (calendar service or
    /// characteristic missing); CancellationError when cancelled.
    public static func connect(scanTimeout: Duration = .seconds(30),
                               connectTimeout: Duration = .seconds(30)) async throws -> CoreBluetoothLink {
        var timeouts = Timeouts()
        timeouts.scan = scanTimeout
        timeouts.connect = connectTimeout
        let link = CoreBluetoothLink(timeouts: timeouts)
        do {
            try await link.open()
            return link
        } catch {
            await link.disconnect()
            throw Task.isCancelled ? CancellationError() : error
        }
    }

    /// A link that has not touched Bluetooth yet: the central manager is created by `open`.
    init(timeouts: Timeouts = Timeouts()) {
        self.timeouts = timeouts
        (notifications, incoming) = AsyncStream.makeStream(of: GattNotification.self)
        delegate.link = self
    }

    deinit {
        // Releasing the central manager ends any connection it still holds.
        incoming.finish()
    }

    // MARK: GattLink

    public func maximumWriteLength() async -> Int {
        await onQueue { self.currentWriteLength() }
    }

    public func writeCommand(_ data: Data) async throws {
        _ = try await perform(.write, timeout: timeouts.operation) {
            guard let peripheral = self.peripheral, let command = self.characteristics[.command] else {
                return .failure(Self.notConnected)
            }
            peripheral.writeValue(data, for: command, type: .withResponse)
            return nil
        }
    }

    public func read(_ characteristic: ReadableCharacteristic) async throws -> Data {
        try await perform(.read(characteristic), timeout: timeouts.operation) {
            guard let peripheral = self.peripheral, !self.characteristics.isEmpty else {
                return .failure(Self.notConnected)
            }
            guard let readable = self.readables[characteristic] else {
                let name = OperationKey.name(characteristic)
                return .failure(UlaniError.protocolError("the device has no \(name) characteristic"))
            }
            peripheral.readValue(for: readable)
            return nil
        }
    }

    public func streamImage(_ data: Data, chunkSize: Int,
                            progress: @escaping @Sendable (Int, Int) -> Void,
                            shouldStop: @escaping @Sendable () -> Bool) async throws -> Int {
        let chunks = try Messages.chunks(data, size: chunkSize)
        let replies = await onQueue { self.imageReplies }
        var sent = 0
        for chunk in chunks {
            guard try await send(chunk, after: replies, shouldStop: shouldStop) else { break }
            sent += chunk.count
            progress(sent, data.count)
        }
        return sent
    }

    /// Cancel the connection and wait (bounded) until it is down, so a new attempt starts
    /// clean; then let go of the central manager. Fails whatever is still waiting with
    /// `linkLost("disconnected")`. Never throws; calling it again is harmless.
    public func disconnect() async {
        _ = try? await perform(.disconnect, timeout: timeouts.close, whenClosed: true) {
            let state = self.peripheral?.state
            let wasConnected = state == .connected || state == .disconnecting
            self.close(.linkLost("disconnected"))
            return wasConnected && self.central?.state == .poweredOn ? nil : .success(Data())
        }
        await onQueue { self.release() }
    }

    // MARK: setup

    private func open() async throws {
        _ = try await perform(.power, timeout: timeouts.power) { self.startManager() }
        _ = try await perform(.scan, timeout: timeouts.scan) {
            guard let central = self.central else { return .failure(Self.notConnected) }
            central.scanForPeripherals(withServices: [GattUUID.cbUUID(GattUUID.advertisedService)])
            return nil
        }
        _ = try await perform(.connect, timeout: timeouts.connect) {
            guard let central = self.central, let peripheral = self.peripheral else {
                return .failure(Self.notConnected)
            }
            central.connect(peripheral)
            return nil
        }
        try await waitForWriteLength()
        _ = try await perform(.discovery, timeout: timeouts.operation) {
            guard let peripheral = self.peripheral else { return .failure(Self.notConnected) }
            self.discovery = GattDiscovery()
            peripheral.discoverServices(GattDiscovery.services.map(GattUUID.cbUUID))
            return nil
        }
        for characteristic in [GattCharacteristic.command, .image] {
            _ = try await perform(.notify(characteristic), timeout: timeouts.subscribe) {
                guard let peripheral = self.peripheral, let target = self.characteristics[characteristic] else {
                    return .failure(Self.notConnected)
                }
                peripheral.setNotifyValue(true, for: target)
                return nil
            }
        }
    }

    /// Create the central manager (on the queue, which also receives its callbacks).
    private func startManager() -> Result<Data, any Error>? {
        let central = self.central ?? CBCentralManager(delegate: delegate, queue: queue)
        self.central = central
        switch Self.readiness(of: central.state) {
        case .ready:
            poweredOn = true
            return .success(Data())
        case .pending:
            return nil
        case .unavailable(let error):
            return .failure(error)
        }
    }

    /// The OS exchanges the MTU shortly after connecting (Windows: ~1.5 s); the chunk size
    /// depends on it. Like `_wait_for_mtu`: poll up to `timeouts.writeLength`, then go on;
    /// throws once the link is closed (it dropped).
    func waitForWriteLength() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeouts.writeLength
        while true {
            let (length, closed) = await onQueue { (self.currentWriteLength(), self.closed) }
            if let closed { throw closed }
            if length > Self.minimumWriteLength || clock.now >= deadline { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func currentWriteLength() -> Int {
        guard closed == nil, let peripheral, peripheral.state == .connected else { return Self.minimumWriteLength }
        return peripheral.maximumWriteValueLength(for: .withoutResponse)
    }

    /// Where an image stream stands.
    enum StreamState: Sendable, Equatable {
        /// CoreBluetooth has room for a chunk.
        case room
        /// No room: wait for `peripheralIsReady`.
        case full
        /// The calendar answered on the image characteristic during the stream (it gave up).
        case answered
    }

    /// Write one image chunk without response as soon as CoreBluetooth has room for it.
    /// Returns false, without writing, once `shouldStop()` holds or the calendar answered
    /// (an image notification after the first `replies`), which the session's inbox may
    /// not have yet.
    private func send(_ chunk: Data, after replies: Int, shouldStop: () -> Bool) async throws -> Bool {
        while !shouldStop() {
            switch try await onQueue({ self.writeIfRoom(chunk, after: replies) }).get() {
            case .room:
                return true  // written
            case .answered:
                return false
            case .full:
                // `peripheralIsReady` or an image notification ends the wait.
                _ = try await perform(.ready, timeout: timeouts.operation) {
                    self.streamState(after: replies) == .success(.full) ? nil : .success(Data())
                }
            }
        }
        return false
    }

    /// Write `chunk` if there is room; returns the state found before writing.
    private func writeIfRoom(_ chunk: Data, after replies: Int) -> Result<StreamState, UlaniError> {
        let state = streamState(after: replies)
        if state == .success(.room) { imageWriter?.writeWithoutResponse(chunk) }
        return state
    }

    /// `replies`: image notifications before the stream began. A reply wins over a closed
    /// link, as in `client.upload`, so the session reports the reply.
    private func streamState(after replies: Int) -> Result<StreamState, UlaniError> {
        if imageReplies != replies { return .success(.answered) }
        if let closed { return .failure(closed) }
        guard let imageWriter else { return .failure(Self.notConnected) }
        return .success(imageWriter.canSendWriteWithoutResponse ? .room : .full)
    }

    // MARK: waiting

    /// Run `start` on the queue and wait for the operation it began. `start` returns a
    /// result when it is already done, nil when a callback will answer `key`. `timeout`
    /// bounds the wait (see `timedOut`). Fails at once when the link is closed, unless
    /// `whenClosed`.
    func perform(_ key: OperationKey, timeout: Duration?, whenClosed: Bool = false,
                 _ start: @escaping @Sendable () -> Result<Data, any Error>?) async throws -> Data {
        let id = lastID.withLock { id in
            id += 1
            return id
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                queue.async {
                    self.begin(key, id: id, timeout: timeout, whenClosed: whenClosed, start: start) {
                        continuation.resume(with: $0)
                    }
                }
                // Already cancelled: the handler may have run before `begin` was queued,
                // so abandon the operation again behind it.
                if Task.isCancelled { queue.async { self.abandon(id) } }
            }
        } onCancel: {
            queue.async { self.abandon(id) }
        }
    }

    private func begin(_ key: OperationKey, id: Int, timeout: Duration?, whenClosed: Bool,
                       start: () -> Result<Data, any Error>?,
                       resume: @escaping PendingOperations<OperationKey>.Resume) {
        if let closed, !whenClosed { return resume(.failure(closed)) }
        if let result = start() { return resume(result) }
        pending.add(key, id: id, resume: resume)
        if let timeout {
            queue.asyncAfter(deadline: .now() + timeout.dispatchInterval) { [weak self] in
                self?.timedOut(id, after: timeout)
            }
        }
    }

    /// The task waiting for `id` was cancelled.
    private func abandon(_ id: Int) {
        guard let key = pending.key(of: id) else { return }
        pending.abandon(id, with: CancellationError(), keepingPlace: key.isRequest)
        switch key {
        case .scan where !pending.isWaiting(.scan): stopScanning()
        case .connect: cancelConnection()
        default: break
        }
    }

    private func timedOut(_ id: Int, after timeout: Duration) {
        guard let key = pending.key(of: id) else { return }
        Self.logger.info("\(key, privacy: .public) timed out after \(timeout, privacy: .public)")
        switch key {
        case .power:
            pending.resume(id, with: .failure(UlaniError.bluetoothUnavailable("Bluetooth did not get ready within \(timeout)")))
        case .scan:
            stopScanning()
            pending.resume(id, with: .failure(UlaniError.notFound))
        case .connect:
            cancelConnection()
            pending.resume(id, with: .failure(UlaniError.linkLost("connecting timed out after \(timeout)")))
        case .disconnect:
            pending.resume(id, with: .success(Data()))
        case .discovery, .notify, .write, .read, .ready:
            close(.linkLost("the device did not answer \(key) within \(timeout)"))
        }
    }

    /// Run `body` on the queue.
    func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// Tests: whether a live operation waits on `key`.
    func isWaiting(_ key: OperationKey) async -> Bool {
        await onQueue { self.pending.isWaiting(key) }
    }

    // MARK: closing

    /// The link is over: fail everything waiting with `error`, end the notifications, stop
    /// scanning and cancel the connection. Only the first call counts.
    private func close(_ error: UlaniError) {
        guard closed == nil else { return }
        closed = error
        Self.logger.info("closed: \(error.description, privacy: .public)")
        pending.resumeEverything(with: error)
        incoming.finish()
        stopScanning()
        cancelConnection()
    }

    /// Let go of the manager and the peripheral (after `disconnect`).
    private func release() {
        peripheral?.delegate = nil
        central?.delegate = nil
        peripheral = nil
        central = nil
        characteristics = [:]
        readables = [:]
        imageWriter = nil
    }

    private func stopScanning() {
        guard let central, central.state == .poweredOn, central.isScanning else { return }
        central.stopScan()
    }

    private func cancelConnection() {
        guard let central, central.state == .poweredOn, let peripheral, peripheral.state != .disconnected else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    // MARK: events (on the queue; the delegate's entry points, taking plain values where it can)

    func managerStateChanged(_ state: CBManagerState) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch Self.readiness(of: state) {
        case .ready:
            poweredOn = true
            pending.resumeAll(.power, with: .success(Data()))
        case .unavailable(let error):
            pending.resumeAll(.power, with: .failure(error))
        case .pending:
            break
        }
        if poweredOn, let error = Self.stateChangeError(state) {
            close(error)
        }
    }

    fileprivate func discovered(_ found: CBPeripheral, advertisementData: [String: Any]) {
        guard peripheral == nil, pending.isWaiting(.scan) else { return }
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? found.name
        guard Self.isCalendar(advertisedServices: services, localName: name) else { return }
        stopScanning()
        found.delegate = delegate
        peripheral = found
        pending.resumeAll(.scan, with: .success(Data()))
    }

    /// Whether `other` is the calendar this link uses.
    fileprivate func owns(_ other: CBPeripheral) -> Bool {
        peripheral?.identifier == other.identifier
    }

    func connected() {
        dispatchPrecondition(condition: .onQueue(queue))
        pending.resumeAll(.connect, with: .success(Data()))
    }

    func connectFailed(error: (any Error)?) {
        dispatchPrecondition(condition: .onQueue(queue))
        let failure = error.map { Self.ulaniError(for: $0, during: "connecting") } ?? .linkLost("connecting failed")
        pending.resumeAll(.connect, with: .failure(failure))
        pending.resumeAll(.disconnect, with: .success(Data()))
    }

    func disconnected(error: (any Error)?) {
        dispatchPrecondition(condition: .onQueue(queue))
        pending.resumeAll(.disconnect, with: .success(Data()))
        close(error.map { Self.ulaniError(for: $0, during: "the connection") } ?? .linkLost("the device disconnected"))
    }

    fileprivate func discoveredServices(of found: CBPeripheral, error: (any Error)?) {
        guard pending.isWaiting(.discovery) else { return }
        do {
            if let error { throw Self.ulaniError(for: error, during: "discovering services") }
            let services = found.services ?? []
            let next = try discovery.servicesDiscovered(services.map(\.uuid.uuidString))
            for service in services where next.contains(GattUUID.canonical(service.uuid.uuidString)) {
                let wanted = GattDiscovery.characteristics(of: service.uuid.uuidString).map(GattUUID.cbUUID)
                found.discoverCharacteristics(wanted, for: service)
            }
        } catch {
            pending.resumeAll(.discovery, with: .failure(error))
        }
    }

    fileprivate func discoveredCharacteristics(of service: CBService, error: (any Error)?) {
        guard pending.isWaiting(.discovery) else { return }
        let uuid = GattUUID.canonical(service.uuid.uuidString)
        if let error, uuid == GattUUID.service {
            let failure = Self.ulaniError(for: error, during: "discovering characteristics")
            pending.resumeAll(.discovery, with: .failure(failure))
            return
        }
        // Device Information is optional: without it reads fail, nothing else does.
        let found = error == nil ? service.characteristics ?? [] : []
        for characteristic in found {
            let id = characteristic.uuid.uuidString
            if uuid == GattUUID.service, let known = GattUUID.characteristic(id) {
                characteristics[known] = characteristic
                if known == .image, let peripheral {
                    imageWriter = PeripheralImageWriter(peripheral: peripheral, characteristic: characteristic)
                }
            } else if uuid == GattUUID.deviceInformation, let readable = GattUUID.readable(id) {
                readables[readable] = characteristic
            }
        }
        do {
            if try discovery.characteristicsDiscovered(found.map(\.uuid.uuidString), of: uuid) {
                pending.resumeAll(.discovery, with: .success(Data()))
            }
        } catch {
            pending.resumeAll(.discovery, with: .failure(error))
        }
    }

    func notificationStateChanged(for uuid: String, isNotifying: Bool, error: (any Error)?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let characteristic = GattUUID.characteristic(uuid) else { return }
        let result: Result<Data, any Error> =
            if let error {
                .failure(Self.ulaniError(for: error, during: "enabling \(characteristic) notifications"))
            } else if !isNotifying {
                .failure(UlaniError.linkLost("the device did not enable \(characteristic) notifications"))
            } else {
                .success(Data())
            }
        pending.resumeFirst(.notify(characteristic), with: result)
    }

    /// A notification (calendar characteristics) or a read result (Device Information).
    func valueUpdated(for uuid: String, value: Data?, error: (any Error)?) {
        dispatchPrecondition(condition: .onQueue(queue))
        if let characteristic = GattUUID.characteristic(uuid) {
            guard error == nil, let value else { return }
            incoming.yield(GattNotification(characteristic: characteristic, value: value))
            if characteristic == .image {
                // The calendar answered (or gave up) mid-stream: the stream stops, even
                // while it waits for room.
                imageReplies += 1
                pending.resumeAll(.ready, with: .success(Data()))
            }
        } else if let readable = GattUUID.readable(uuid) {
            let result: Result<Data, any Error> =
                if let error {
                    .failure(Self.ulaniError(for: error, during: "reading the \(OperationKey.name(readable))"))
                } else {
                    .success(value ?? Data())
                }
            pending.resumeFirst(.read(readable), with: result)
        }
    }

    func valueWritten(for uuid: String, error: (any Error)?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard GattUUID.characteristic(uuid) == .command else { return }
        let result: Result<Data, any Error> =
            error.map { .failure(Self.ulaniError(for: $0, during: "writing a command")) } ?? .success(Data())
        pending.resumeFirst(.write, with: result)
    }

    func readyToSend() {
        dispatchPrecondition(condition: .onQueue(queue))
        pending.resumeAll(.ready, with: .success(Data()))
    }

    /// The calendar changed its GATT table: the calendar characteristics we hold are void.
    func servicesInvalidated(_ uuids: [String]) {
        dispatchPrecondition(condition: .onQueue(queue))
        if uuids.contains(where: { GattUUID.canonical($0) == GattUUID.service }) {
            close(.linkLost("the device changed its services"))
        }
    }
}

/// Where a link writes image chunks without response; used on the link's queue only.
protocol ImageWriter {
    /// CoreBluetooth has room for another write without response.
    var canSendWriteWithoutResponse: Bool { get }
    func writeWithoutResponse(_ chunk: Data)
}

/// The peripheral's image characteristic.
private struct PeripheralImageWriter: ImageWriter {
    let peripheral: CBPeripheral
    let characteristic: CBCharacteristic

    var canSendWriteWithoutResponse: Bool { peripheral.canSendWriteWithoutResponse }

    func writeWithoutResponse(_ chunk: Data) {
        peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)
    }
}

/// Forwards CoreBluetooth's callbacks (all on the link's queue) to the link, so the
/// delegate methods stay out of the link's public interface.
private final class CoreBluetoothDelegate: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var link: CoreBluetoothLink?

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        link?.managerStateChanged(central.state)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        link?.discovered(peripheral, advertisementData: advertisementData)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let link, link.owns(peripheral) else { return }
        link.connected()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        guard let link, link.owns(peripheral) else { return }
        link.connectFailed(error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: (any Error)?) {
        guard let link, link.owns(peripheral) else { return }
        link.disconnected(error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        link?.discoveredServices(of: peripheral, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        link?.discoveredCharacteristics(of: service, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: (any Error)?) {
        link?.notificationStateChanged(for: characteristic.uuid.uuidString, isNotifying: characteristic.isNotifying,
                                       error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        link?.valueUpdated(for: characteristic.uuid.uuidString, value: characteristic.value, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        link?.valueWritten(for: characteristic.uuid.uuidString, error: error)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        link?.readyToSend()
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        link?.servicesInvalidated(invalidatedServices.map(\.uuid.uuidString))
    }
}

extension Duration {
    /// For `DispatchQueue.asyncAfter`.
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        let nanoseconds = Double(seconds) * 1e9 + Double(attoseconds) / 1e9
        return .nanoseconds(Int(min(max(nanoseconds, 0), Double(Int.max / 2))))
    }
}
