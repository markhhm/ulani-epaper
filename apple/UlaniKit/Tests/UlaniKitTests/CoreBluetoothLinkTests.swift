import CoreBluetooth
import Foundation
import os
import Testing
@testable import UlaniKit

/// UUIDs and the advertisement filter.
@Suite struct BluetoothUUIDTests {
    @Test func shortAndLongFormsAreCanonical() {
        #expect(GattUUID.canonical("A200") == GattUUID.advertisedService)
        #expect(GattUUID.canonical("2A26") == GattUUID.firmwareRevision)
        #expect(GattUUID.canonical("180A") == GattUUID.deviceInformation)
        #expect(GattUUID.canonical("1234A201-7CBC-11E9-8F9E-2A86E4085A59") == GattUUID.command)
        #expect(GattUUID.canonical("0000A200-0000-1000-8000-00805F9B34FB") == GattUUID.advertisedService)
        #expect(GattUUID.canonical("12345678") == "12345678-0000-1000-8000-00805f9b34fb")
    }

    @Test func coreBluetoothSpellingsAreCanonical() {
        // CBUUID prints 16-bit UUIDs short and 128-bit ones upper-case.
        #expect(GattUUID.canonical(CBUUID(string: GattUUID.advertisedService).uuidString) == GattUUID.advertisedService)
        #expect(GattUUID.canonical(CBUUID(string: GattUUID.image).uuidString) == GattUUID.image)
    }

    @Test func coreBluetoothGetsTheShortForm() {
        #expect(GattUUID.short(GattUUID.advertisedService) == "A200")
        #expect(GattUUID.short(GattUUID.deviceInformation) == "180A")
        #expect(GattUUID.short(GattUUID.firmwareRevision) == "2A26")
        #expect(GattUUID.short("a200") == "A200")
        #expect(GattUUID.short(GattUUID.command) == GattUUID.command)
        #expect(GattUUID.short("12345678") == "12345678-0000-1000-8000-00805f9b34fb")
        // CBUUID.data does not copy: keep the UUID alive while reading it.
        let a200 = GattUUID.cbUUID(GattUUID.advertisedService)
        withExtendedLifetime(a200) { #expect(Array(a200.data) == [0xA2, 0x00]) }
        #expect(GattUUID.cbUUID(GattUUID.image) == CBUUID(string: GattUUID.image))
    }

    @Test func characteristicsByUUID() {
        #expect(GattUUID.characteristic("1234A201-7CBC-11E9-8F9E-2A86E4085A59") == .command)
        #expect(GattUUID.characteristic(GattUUID.image) == .image)
        #expect(GattUUID.characteristic(GattUUID.firmwareRevision) == nil)
        #expect(GattUUID.readable("2A24") == .modelNumber)
        #expect(GattUUID.readable("2A26") == .firmwareRevision)
        #expect(GattUUID.readable(GattUUID.command) == nil)
        #expect(GattUUID.uuid(of: .command) == GattUUID.command)
        #expect(GattUUID.uuid(of: .image) == GattUUID.image)
        #expect(GattUUID.uuid(of: .modelNumber) == GattUUID.modelNumber)
        #expect(GattUUID.uuid(of: .firmwareRevision) == GattUUID.firmwareRevision)
    }

    @Test func calendarsAdvertiseA200OrAnUlaniName() {
        // client.find(): A200 among the advertised services, or a local name starting "ULANI".
        #expect(CoreBluetoothLink.isCalendar(advertisedServices: ["A200"], localName: nil))
        #expect(CoreBluetoothLink.isCalendar(advertisedServices: ["180F", GattUUID.advertisedService], localName: "x"))
        #expect(CoreBluetoothLink.isCalendar(advertisedServices: [], localName: "ULANI Calendar 0A1B2C"))
        #expect(!CoreBluetoothLink.isCalendar(advertisedServices: [], localName: "ulani calendar"))
        #expect(!CoreBluetoothLink.isCalendar(advertisedServices: ["180F"], localName: "Keyboard"))
        #expect(!CoreBluetoothLink.isCalendar(advertisedServices: [], localName: nil))
    }
}

/// Service and characteristic discovery bookkeeping.
@Suite struct GattDiscoveryTests {
    @Test func asksForTheCalendarAndDeviceInformationServices() {
        #expect(GattDiscovery.services == [GattUUID.service, GattUUID.deviceInformation])
        #expect(Set(GattDiscovery.characteristics(of: GattUUID.service)) == [GattUUID.command, GattUUID.image])
        #expect(Set(GattDiscovery.characteristics(of: "180A")) == [GattUUID.modelNumber, GattUUID.firmwareRevision])
        #expect(GattDiscovery.characteristics(of: "180F").isEmpty)
    }

    @Test func completesOnceEveryServiceReported() throws {
        var discovery = GattDiscovery()
        let next = try discovery.servicesDiscovered(["1234A200-7CBC-11E9-8F9E-2A86E4085A59", "180A", "1800"])
        #expect(next == [GattUUID.service, GattUUID.deviceInformation])
        #expect(try !discovery.characteristicsDiscovered(["2A24", "2A26"], of: "180A"))
        #expect(try discovery.characteristicsDiscovered(
            ["1234A201-7CBC-11E9-8F9E-2A86E4085A59", "1234A202-7CBC-11E9-8F9E-2A86E4085A59"],
            of: "1234A200-7CBC-11E9-8F9E-2A86E4085A59"))
        #expect(discovery.isComplete)
    }

    @Test func aMissingCalendarServiceFails() {
        var discovery = GattDiscovery()
        #expect(throws: UlaniError.self) { try discovery.servicesDiscovered(["180A", "1800"]) }
        do {
            _ = try discovery.servicesDiscovered([])
        } catch let error as UlaniError {
            guard case .protocolError(let message) = error else {
                Issue.record("expected protocolError, got \(error)")
                return
            }
            #expect(message.contains("device service"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func deviceInformationIsOptional() throws {
        var discovery = GattDiscovery()
        #expect(try discovery.servicesDiscovered([GattUUID.service]) == [GattUUID.service])
        #expect(try discovery.characteristicsDiscovered([GattUUID.command, GattUUID.image], of: GattUUID.service))
    }

    @Test func aMissingCalendarCharacteristicFails() throws {
        var discovery = GattDiscovery()
        _ = try discovery.servicesDiscovered([GattUUID.service, GattUUID.deviceInformation])
        #expect(try !discovery.characteristicsDiscovered([GattUUID.modelNumber], of: GattUUID.deviceInformation))
        do {
            _ = try discovery.characteristicsDiscovered([GattUUID.command], of: GattUUID.service)
            Issue.record("expected a failure")
        } catch UlaniError.protocolError(let message) {
            #expect(message.contains("image characteristic"))
        }
    }

    @Test func unaskedOrRepeatedServicesAreIgnored() throws {
        var discovery = GattDiscovery()
        _ = try discovery.servicesDiscovered([GattUUID.service])
        #expect(try !discovery.characteristicsDiscovered(["2A00"], of: "1800"))
        #expect(try discovery.characteristicsDiscovered([GattUUID.command, GattUUID.image], of: GattUUID.service))
        // A late repeat does not complete the discovery a second time.
        #expect(try !discovery.characteristicsDiscovered([GattUUID.command, GattUUID.image], of: GattUUID.service))
    }

    @Test func notStartedIsNotComplete() {
        #expect(!GattDiscovery().isComplete)
    }
}

/// The table of waiting operations: each continuation is resumed exactly once.
@Suite struct PendingOperationsTests {
    private struct Cancelled: Error, CustomStringConvertible { var description: String { "cancelled" } }

    private func record(_ name: String, _ log: Recorder<String>) -> PendingOperations<String>.Resume {
        { result in
            switch result {
            case .success(let data): log.append("\(name) ok \(data.hexString())")
            case .failure(let error): log.append("\(name) \(error)")
            }
        }
    }

    @Test func oldestFirstPerKey() {
        let log = Recorder<String>()
        var table = PendingOperations<String>()
        table.add("write", id: 1, resume: record("a", log))
        table.add("write", id: 2, resume: record("b", log))
        table.add("read", id: 3, resume: record("c", log))
        let first = table.resumeFirst("write", with: .success(Data([1])))
        let second = table.resumeFirst("write", with: .success(Data([2])))
        let third = table.resumeFirst("write", with: .success(Data()))
        #expect(first && second && !third)
        #expect(log.values == ["a ok 01", "b ok 02"])
        #expect(table.isWaiting("read"))
        #expect(!table.isWaiting("write"))
    }

    @Test func anAbandonedRequestKeepsItsPlace() {
        // CoreBluetooth still answers the abandoned request: that answer must not be
        // taken for the next one's.
        let log = Recorder<String>()
        var table = PendingOperations<String>()
        table.add("write", id: 1, resume: record("a", log))
        table.add("write", id: 2, resume: record("b", log))
        let abandoned = table.abandon(1, with: Cancelled(), keepingPlace: true)
        #expect(abandoned == "write")
        #expect(log.values == ["a cancelled"])
        #expect(table.key(of: 1) == nil)
        let late = table.resumeFirst("write", with: .success(Data([1])))  // a's late answer
        #expect(!late)
        let answered = table.resumeFirst("write", with: .success(Data([2])))
        #expect(answered)
        #expect(log.values == ["a cancelled", "b ok 02"])
        #expect(table.isEmpty)
    }

    @Test func anAbandonedWaitLeavesNoTrace() {
        let log = Recorder<String>()
        var table = PendingOperations<String>()
        table.add("ready", id: 1, resume: record("a", log))
        table.add("ready", id: 2, resume: record("b", log))
        let abandoned = table.abandon(1, with: Cancelled(), keepingPlace: false)
        #expect(abandoned == "ready")
        let resumed = table.resumeAll("ready", with: .success(Data()))
        #expect(resumed == 1)
        #expect(log.values == ["a cancelled", "b ok "])
        #expect(table.isEmpty)
    }

    @Test func abandoningTwiceOrUnknownDoesNothing() {
        let log = Recorder<String>()
        var table = PendingOperations<String>()
        table.add("write", id: 1, resume: record("a", log))
        let once = table.abandon(1, with: Cancelled(), keepingPlace: true)
        let twice = table.abandon(1, with: Cancelled(), keepingPlace: true)
        let unknown = table.abandon(9, with: Cancelled(), keepingPlace: false)
        let resumed = table.resume(1, with: .success(Data()))
        #expect(once == "write")
        #expect(twice == nil)
        #expect(unknown == nil)
        #expect(!resumed)
        #expect(log.values == ["a cancelled"])
    }

    @Test func resumeByID() {
        let log = Recorder<String>()
        var table = PendingOperations<String>()
        table.add("connect", id: 4, resume: record("a", log))
        #expect(table.key(of: 4) == "connect")
        let first = table.resume(4, with: .success(Data([7])))
        let again = table.resume(4, with: .success(Data([8])))
        #expect(first && !again)
        #expect(log.values == ["a ok 07"])
    }

    @Test func everythingFailsOnceWhenTheLinkCloses() {
        let log = Recorder<String>()
        var table = PendingOperations<String>()
        table.add("write", id: 1, resume: record("a", log))
        table.add("write", id: 2, resume: record("b", log))
        table.add("ready", id: 3, resume: record("c", log))
        table.abandon(1, with: Cancelled(), keepingPlace: true)
        let failed = table.resumeEverything(with: UlaniError.linkLost("gone"))
        #expect(failed == 2)
        #expect(table.isEmpty)
        let write = table.resumeFirst("write", with: .success(Data()))
        let ready = table.resumeAll("ready", with: .success(Data()))
        #expect(!write && ready == 0)
        #expect(log.values == ["a cancelled", "b Bluetooth link lost: gone", "c Bluetooth link lost: gone"])
    }
}

/// The link's waiting, timeouts and event routing, driven without a radio: a link that was
/// never opened creates no central manager, and the delegate's entry points take plain values.
@Suite struct CoreBluetoothLinkTests {
    private func makeLink() -> CoreBluetoothLink {
        CoreBluetoothLink(timeouts: CoreBluetoothLink.Timeouts())
    }

    /// Start `key` waiting (its start returns nil) and return once the link holds it.
    /// The deadline is generous: the upload and push suites, running in parallel, can keep
    /// every cooperative thread busy for seconds (debug-build CRCs).
    private func waiting(_ link: CoreBluetoothLink,
                         _ key: CoreBluetoothLink.OperationKey) async throws -> Task<Data, any Error> {
        let task = Task { try await link.perform(key, timeout: nil) { nil } }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(30)
        while await !link.isWaiting(key) {
            guard clock.now < deadline else { throw TestTimeout() }
            try await Task.sleep(for: .milliseconds(1))
        }
        return task
    }

    /// Start `key` waiting with a 30 ms timeout (not polled: it may expire at once).
    private func expiring(_ link: CoreBluetoothLink, _ key: CoreBluetoothLink.OperationKey) -> Task<Data, any Error> {
        Task { try await link.perform(key, timeout: .milliseconds(30)) { nil } }
    }

    private func expectLinkLost(_ task: Task<Data, any Error>, sourceLocation: SourceLocation = #_sourceLocation) async {
        do {
            _ = try await task.value
            Issue.record("expected linkLost", sourceLocation: sourceLocation)
        } catch UlaniError.linkLost {
        } catch {
            Issue.record("expected linkLost, got \(error)", sourceLocation: sourceLocation)
        }
    }

    // MARK: before connecting

    @Test func anUnopenedLinkIsNotConnected() async {
        let link = makeLink()
        await #expect(throws: UlaniError.linkLost("not connected to the device")) {
            try await link.writeCommand(Command.unlock)
        }
        await #expect(throws: UlaniError.linkLost("not connected to the device")) {
            try await link.read(.firmwareRevision)
        }
        await #expect(throws: UlaniError.linkLost("not connected to the device")) {
            _ = try await link.streamImage(Data(count: 100), chunkSize: 20, progress: { _, _ in },
                                           shouldStop: { false })
        }
        #expect(await link.maximumWriteLength() == 20)
    }

    @Test func streamingAsksShouldStopBeforeTheFirstChunk() async throws {
        let link = makeLink()
        let sent = try await link.streamImage(Data(count: 1000), chunkSize: 230, progress: { _, _ in },
                                              shouldStop: { true })
        #expect(sent == 0)
    }

    @Test func immediateResultsDoNotWait() async throws {
        let link = makeLink()
        #expect(try await link.perform(.ready, timeout: .milliseconds(1)) { .success(Data([1])) } == Data([1]))
        await #expect(throws: UlaniError.protocolError("x")) {
            try await link.perform(.read(.modelNumber), timeout: nil) { .failure(UlaniError.protocolError("x")) }
        }
        #expect(await !link.isWaiting(.ready))
    }

    // MARK: disconnect

    @Test func disconnectFailsWhatIsWaitingAndEndsNotifications() async throws {
        let link = makeLink()
        let write = try await waiting(link, .write)
        let ready = try await waiting(link, .ready)
        await link.disconnect()
        await #expect(throws: UlaniError.linkLost("disconnected")) { try await write.value }
        await #expect(throws: UlaniError.linkLost("disconnected")) { try await ready.value }
        var notifications = link.notifications.makeAsyncIterator()
        #expect(await notifications.next() == nil)
        await #expect(throws: UlaniError.linkLost("disconnected")) { try await link.writeCommand(Command.unlock) }
        await link.disconnect()  // twice is fine
    }

    // MARK: cancellation

    @Test func cancellingAWaitResumesItOnce() async throws {
        let link = makeLink()
        let task = try await waiting(link, .write)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await !link.isWaiting(.write))
        // The link stays usable.
        let next = try await waiting(link, .ready)
        await link.onQueue { link.readyToSend() }
        #expect(try await next.value == Data())
    }

    @Test func cancelledBeforeWaiting() async {
        let link = makeLink()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await link.perform(.ready, timeout: nil) { nil }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await !link.isWaiting(.ready))
    }

    @Test func aCancelledWriteDoesNotTakeTheNextOnesAnswer() async throws {
        let link = makeLink()
        let first = try await waiting(link, .write)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        let second = try await waiting(link, .write)
        await link.onQueue { link.valueWritten(for: GattUUID.command, error: nil) }  // the first one's
        #expect(await link.isWaiting(.write))
        await link.onQueue { link.valueWritten(for: GattUUID.command, error: nil) }
        #expect(try await second.value == Data())
    }

    // MARK: timeouts

    @Test func aSilentGattRequestClosesTheLink() async throws {
        let link = makeLink()
        let other = try await waiting(link, .ready)
        let write = expiring(link, .write)
        await expectLinkLost(write)
        await expectLinkLost(other)
        var notifications = link.notifications.makeAsyncIterator()
        #expect(await notifications.next() == nil)
    }

    @Test func scanTimeoutIsNotFound() async throws {
        let link = makeLink()
        let scan = expiring(link, .scan)
        await #expect(throws: UlaniError.notFound) { try await scan.value }
    }

    @Test func connectTimeoutIsALinkFailure() async throws {
        let link = makeLink()
        let connect = expiring(link, .connect)
        await expectLinkLost(connect)
    }

    @Test func powerTimeoutIsUnavailable() async throws {
        let link = makeLink()
        let power = expiring(link, .power)
        do {
            _ = try await power.value
            Issue.record("expected bluetoothUnavailable")
        } catch UlaniError.bluetoothUnavailable {}
    }

    @Test func disconnectWaitIsBounded() async throws {
        let link = makeLink()
        let wait = expiring(link, .disconnect)
        #expect(try await wait.value == Data())
    }

    // MARK: manager state

    @Test func poweringOnEndsThePowerWait() async throws {
        let link = makeLink()
        let power = try await waiting(link, .power)
        await link.onQueue { link.managerStateChanged(.unknown) }
        #expect(await link.isWaiting(.power))
        await link.onQueue { link.managerStateChanged(.poweredOn) }
        #expect(try await power.value == Data())
    }

    @Test func bluetoothOffFailsThePowerWait() async throws {
        let link = makeLink()
        let power = try await waiting(link, .power)
        await link.onQueue { link.managerStateChanged(.unauthorized) }
        await #expect(throws: UlaniError.bluetoothUnavailable("this app is not allowed to use Bluetooth")) {
            try await power.value
        }
    }

    @Test func bluetoothTurnedOffMidSessionFailsEverything() async throws {
        let link = makeLink()
        await link.onQueue { link.managerStateChanged(.poweredOn) }
        let write = try await waiting(link, .write)
        await link.onQueue { link.managerStateChanged(.poweredOff) }
        await #expect(throws: UlaniError.bluetoothUnavailable("Bluetooth is off")) { try await write.value }
        await #expect(throws: UlaniError.bluetoothUnavailable("Bluetooth is off")) {
            try await link.writeCommand(Command.unlock)
        }
    }

    @Test func aResetMidSessionDropsTheLink() async throws {
        let link = makeLink()
        await link.onQueue { link.managerStateChanged(.poweredOn) }
        let read = try await waiting(link, .read(.firmwareRevision))
        await link.onQueue { link.managerStateChanged(.resetting) }
        await expectLinkLost(read)
    }

    // MARK: connection events

    @Test func aDroppedConnectionFailsEverything() async throws {
        let link = makeLink()
        let write = try await waiting(link, .write)
        let ready = try await waiting(link, .ready)
        await link.onQueue { link.disconnected(error: nil) }
        await #expect(throws: UlaniError.linkLost("the device disconnected")) { try await write.value }
        await #expect(throws: UlaniError.linkLost("the device disconnected")) { try await ready.value }
        var notifications = link.notifications.makeAsyncIterator()
        #expect(await notifications.next() == nil)
    }

    @Test func aDropForALostBondSaysSo() async throws {
        let link = makeLink()
        let notify = try await waiting(link, .notify(.command))
        await link.onQueue { link.disconnected(error: CBError(.peerRemovedPairingInformation)) }
        await #expect(throws: UlaniError.bondLost) { try await notify.value }
    }

    @Test func aDisconnectWaitEndsWithTheDisconnection() async throws {
        let link = makeLink()
        let wait = try await waiting(link, .disconnect)
        await link.onQueue { link.disconnected(error: nil) }
        #expect(try await wait.value == Data())
    }

    @Test func aFailedConnectIsMapped() async throws {
        let link = makeLink()
        let connect = try await waiting(link, .connect)
        await link.onQueue { link.connectFailed(error: CBError(.peerRemovedPairingInformation)) }
        await #expect(throws: UlaniError.bondLost) { try await connect.value }

        let again = try await waiting(link, .connect)
        await link.onQueue { link.connectFailed(error: nil) }
        await expectLinkLost(again)
    }

    @Test func connectedEndsTheConnectWait() async throws {
        let link = makeLink()
        let connect = try await waiting(link, .connect)
        await link.onQueue { link.connected() }
        #expect(try await connect.value == Data())
    }

    // MARK: GATT events

    @Test func notificationsAreRoutedByCharacteristic() async throws {
        let link = makeLink()
        await link.onQueue {
            link.valueUpdated(for: "1234A201-7CBC-11E9-8F9E-2A86E4085A59", value: Reply.deviceReady, error: nil)
            link.valueUpdated(for: GattUUID.image, value: Reply.dataOK, error: nil)
            link.valueUpdated(for: GattUUID.command, value: nil, error: nil)  // no value: skipped
            link.valueUpdated(for: GattUUID.command, value: Data([9]), error: CBATTError(.unlikelyError))  // error: skipped
            link.valueUpdated(for: "2A19", value: Data([50]), error: nil)  // not ours: skipped
            link.valueUpdated(for: GattUUID.command, value: Reply.unlockOK, error: nil)
        }
        await link.disconnect()
        var received: [GattNotification] = []
        for await notification in link.notifications { received.append(notification) }
        #expect(received == [
            GattNotification(characteristic: .command, value: Reply.deviceReady),
            GattNotification(characteristic: .image, value: Reply.dataOK),
            GattNotification(characteristic: .command, value: Reply.unlockOK),
        ])
    }

    @Test func readsAreAnsweredByValueUpdates() async throws {
        let link = makeLink()
        let model = try await waiting(link, .read(.modelNumber))
        let firmware = try await waiting(link, .read(.firmwareRevision))
        await link.onQueue {
            link.valueUpdated(for: "2A26", value: Data("v1.0.09".utf8), error: nil)
            link.valueUpdated(for: "2A24", value: Data("P7320E-B".utf8), error: nil)
        }
        #expect(try await model.value == Data("P7320E-B".utf8))
        #expect(try await firmware.value == Data("v1.0.09".utf8))
    }

    @Test func aFailedReadIsMapped() async throws {
        let link = makeLink()
        let read = try await waiting(link, .read(.firmwareRevision))
        await link.onQueue { link.valueUpdated(for: "2A26", value: nil, error: CBATTError(.insufficientEncryption)) }
        await #expect(throws: UlaniError.bondLost) { try await read.value }
    }

    @Test func writesAreAnsweredInOrder() async throws {
        let link = makeLink()
        let first = try await waiting(link, .write)
        let second = try await waiting(link, .write)
        await link.onQueue { link.valueWritten(for: GattUUID.command, error: CBATTError(.insufficientAuthentication)) }
        await #expect(throws: UlaniError.bondLost) { try await first.value }
        #expect(await link.isWaiting(.write))
        await link.onQueue { link.valueWritten(for: GattUUID.image, error: nil) }  // not a command write
        #expect(await link.isWaiting(.write))
        await link.onQueue { link.valueWritten(for: GattUUID.command, error: nil) }
        #expect(try await second.value == Data())
    }

    @Test func subscribingSucceedsOnlyWhenNotifying() async throws {
        let link = makeLink()
        let command = try await waiting(link, .notify(.command))
        let image = try await waiting(link, .notify(.image))
        await link.onQueue {
            link.notificationStateChanged(for: GattUUID.image, isNotifying: false, error: nil)
            link.notificationStateChanged(for: GattUUID.command, isNotifying: true, error: nil)
        }
        #expect(try await command.value == Data())
        await expectLinkLost(image)

        let again = try await waiting(link, .notify(.image))
        await link.onQueue {
            link.notificationStateChanged(for: GattUUID.image, isNotifying: false,
                                          error: NSError(domain: CBATTErrorDomain, code: 5))
        }
        await #expect(throws: UlaniError.bondLost) { try await again.value }
    }

    @Test func readyToSendWakesTheStream() async throws {
        let link = makeLink()
        let ready = try await waiting(link, .ready)
        await link.onQueue { link.readyToSend() }
        #expect(try await ready.value == Data())
        await link.onQueue { link.readyToSend() }  // nobody waiting: nothing happens
    }

    @Test func changedCalendarServicesDropTheLink() async throws {
        let link = makeLink()
        let write = try await waiting(link, .write)
        await link.onQueue { link.servicesInvalidated(["180F"]) }
        #expect(await link.isWaiting(.write))
        await link.onQueue { link.servicesInvalidated(["1234A200-7CBC-11E9-8F9E-2A86E4085A59"]) }
        await expectLinkLost(write)
    }

    // MARK: setup timeouts

    @Test func theWriteLengthWaitGivesUpAndSetupGoesOn() async throws {
        // A link that was never opened reports 20, like a link before the MTU exchange.
        var timeouts = CoreBluetoothLink.Timeouts()
        timeouts.writeLength = .milliseconds(300)
        let link = CoreBluetoothLink(timeouts: timeouts)
        let elapsed = try await ContinuousClock().measure { try await link.waitForWriteLength() }
        #expect(elapsed >= .milliseconds(300))
        #expect(elapsed < .seconds(10))  // generous: parallel suites can starve the test for seconds
    }

    @Test func theWriteLengthWaitFailsWhenTheLinkDrops() async throws {
        // Python `_wait_for_mtu`: "link dropped right after connecting".
        var timeouts = CoreBluetoothLink.Timeouts()
        timeouts.writeLength = .seconds(60)
        let link = CoreBluetoothLink(timeouts: timeouts)
        let wait = Task { try await link.waitForWriteLength() }
        try await Task.sleep(for: .milliseconds(150))
        let clock = ContinuousClock()
        let dropped = clock.now
        await link.onQueue { link.disconnected(error: nil) }
        await #expect(throws: UlaniError.linkLost("the device disconnected")) { try await wait.value }
        #expect(clock.now - dropped < .seconds(10))  // long before the 60 s deadline
        // Already dropped: fails at once.
        await #expect(throws: UlaniError.linkLost("the device disconnected")) { try await link.waitForWriteLength() }
    }

    @Test func subscribingLeavesTimeToPair() {
        // Enabling notifications is the first access that needs the bond: on first contact
        // it includes the system pairing dialog, like the power wait
        // includes the permission prompt.
        let timeouts = CoreBluetoothLink.Timeouts()
        #expect(timeouts.subscribe >= .seconds(60))
        #expect(timeouts.subscribe > timeouts.operation)
    }
}

/// Streaming image chunks with flow control, against a fake image characteristic.
@Suite struct CoreBluetoothStreamTests {
    private let data = Data((0..<1000).map { UInt8(truncatingIfNeeded: $0) })  // 5 chunks of up to 230

    /// A link whose image chunks go to `writer`. A stream that waits for room longer than
    /// `operation` closes the link: a regression fails sooner than after 30 s.
    private func makeLink(_ writer: FakeImageWriter? = nil, operation: Duration = .seconds(10)) async -> CoreBluetoothLink {
        var timeouts = CoreBluetoothLink.Timeouts()
        timeouts.operation = operation
        let link = CoreBluetoothLink(timeouts: timeouts)
        if let writer { await link.onQueue { link.imageWriter = writer } }
        return link
    }

    private func stream(_ link: CoreBluetoothLink, progress: Recorder<Int>? = nil,
                        shouldStop: @escaping @Sendable () -> Bool = { false }) -> Task<Int, any Error> {
        let data = self.data
        return Task {
            try await link.streamImage(data, chunkSize: 230, progress: { sent, _ in progress?.append(sent) },
                                       shouldStop: shouldStop)
        }
    }

    /// Return once the stream waits for room (deadline generous, see `waiting`).
    private func waitForRoomWait(_ link: CoreBluetoothLink) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(30)
        while await !link.isWaiting(.ready) {
            guard clock.now < deadline else { throw TestTimeout() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func writesEveryChunkWhileThereIsRoom() async throws {
        let writer = FakeImageWriter()
        let link = await makeLink(writer)
        let progress = Recorder<Int>()
        let sent = try await stream(link, progress: progress).value
        #expect(sent == 1000)
        #expect(progress.values == [230, 460, 690, 920, 1000])
        #expect(writer.written.reduce(Data(), +) == data)
        #expect(!writer.overflowed)
    }

    @Test func waitsForRoomThenGoesOn() async throws {
        let writer = FakeImageWriter(room: 2)
        let link = await makeLink(writer)
        let task = stream(link)
        try await waitForRoomWait(link)
        #expect(writer.written.count == 2)
        writer.setRoom(nil)
        await link.onQueue { link.readyToSend() }
        #expect(try await task.value == 1000)
        #expect(writer.written.reduce(Data(), +) == data)
        #expect(!writer.overflowed)
    }

    @Test func aReplyWhileWaitingForRoomStopsTheStream() async throws {
        // The calendar gives up (`02 01`) while CoreBluetooth has no room. The stream must
        // stop at once, even before the session's inbox has the reply (`shouldStop` still
        // false), so the session reads `02 01` instead of the link timing out.
        let writer = FakeImageWriter(room: 2)
        let link = await makeLink(writer)
        let task = stream(link)
        try await waitForRoomWait(link)
        await link.onQueue { link.valueUpdated(for: GattUUID.image, value: Reply.dataFail, error: nil) }
        #expect(try await task.value == 460)
        #expect(writer.written.count == 2)
        #expect(await !link.isWaiting(.ready))
        var notifications = link.notifications.makeAsyncIterator()
        #expect(await notifications.next() == GattNotification(characteristic: .image, value: Reply.dataFail))
    }

    @Test func aReplyBetweenChunksStopsBeforeTheNextOne() async throws {
        // Python checks the image replies before every chunk.
        let link = await makeLink()
        let writer = FakeImageWriter { count in
            if count == 2 { link.valueUpdated(for: GattUUID.image, value: Reply.dataFail, error: nil) }
        }
        await link.onQueue { link.imageWriter = writer }
        #expect(try await stream(link).value == 460)
        #expect(writer.written.count == 2)
    }

    @Test func aReplyBeforeTheStreamDoesNotStopIt() async throws {
        // A stale reply is the session's business (it drains the inbox first).
        let writer = FakeImageWriter()
        let link = await makeLink(writer)
        await link.onQueue { link.valueUpdated(for: GattUUID.image, value: Reply.dataFail, error: nil) }
        #expect(try await stream(link).value == 1000)
    }

    @Test func aCommandReplyDoesNotWakeTheStream() async throws {
        let writer = FakeImageWriter(room: 1)
        let link = await makeLink(writer)
        let task = stream(link)
        try await waitForRoomWait(link)
        await link.onQueue { link.valueUpdated(for: GattUUID.command, value: Reply.unlockOK, error: nil) }
        #expect(await link.isWaiting(.ready))
        writer.setRoom(nil)
        await link.onQueue { link.readyToSend() }
        #expect(try await task.value == 1000)
    }

    @Test func shouldStopIsAskedAfterWakingUp() async throws {
        let stop = OSAllocatedUnfairLock(initialState: false)
        let writer = FakeImageWriter(room: 1)
        let link = await makeLink(writer)
        let task = stream(link, shouldStop: { stop.withLock { $0 } })
        try await waitForRoomWait(link)
        stop.withLock { $0 = true }
        writer.setRoom(nil)
        await link.onQueue { link.readyToSend() }
        #expect(try await task.value == 230)
        #expect(writer.written.count == 1)
    }

    @Test func noRoomForTooLongClosesTheLink() async throws {
        let writer = FakeImageWriter(room: 0)
        let link = await makeLink(writer, operation: .milliseconds(50))
        do {
            _ = try await stream(link).value
            Issue.record("expected linkLost")
        } catch UlaniError.linkLost {}
        #expect(writer.written.isEmpty)
        var notifications = link.notifications.makeAsyncIterator()
        #expect(await notifications.next() == nil)
    }

    @Test func aDropWhileWaitingForRoomFailsTheStream() async throws {
        let writer = FakeImageWriter(room: 1)
        let link = await makeLink(writer)
        let task = stream(link)
        try await waitForRoomWait(link)
        await link.onQueue { link.disconnected(error: nil) }
        await #expect(throws: UlaniError.linkLost("the device disconnected")) { try await task.value }
    }

    @Test func aReplyJustBeforeADropStillStopsTheStream() async throws {
        // Python breaks on the buffered reply before writing, so the session reports the
        // reply (uploadFailed) rather than the dropped link.
        let writer = FakeImageWriter(room: 1)
        let link = await makeLink(writer)
        let task = stream(link)
        try await waitForRoomWait(link)
        await link.onQueue {
            link.valueUpdated(for: GattUUID.image, value: Reply.dataFail, error: nil)
            link.disconnected(error: nil)
        }
        #expect(try await task.value == 230)
    }
}

/// Stands in for the peripheral's image characteristic: room for `room` more writes
/// (nil: unlimited). `onWrite(count)` runs on the link's queue after each write.
final class FakeImageWriter: ImageWriter, Sendable {
    private struct State: Sendable {
        var room: Int?
        var written: [Data] = []
        var overflowed = false
    }

    private let state: OSAllocatedUnfairLock<State>
    private let onWrite: (@Sendable (Int) -> Void)?

    init(room: Int? = nil, onWrite: (@Sendable (Int) -> Void)? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(room: room))
        self.onWrite = onWrite
    }

    var canSendWriteWithoutResponse: Bool {
        state.withLock { $0.room.map { $0 > 0 } ?? true }
    }

    func writeWithoutResponse(_ chunk: Data) {
        let count = state.withLock { state in
            if let room = state.room {
                if room <= 0 { state.overflowed = true }
                state.room = room - 1
            }
            state.written.append(chunk)
            return state.written.count
        }
        onWrite?(count)
    }

    func setRoom(_ room: Int?) { state.withLock { $0.room = room } }
    var written: [Data] { state.withLock { $0.written } }
    /// A chunk was written without room (CoreBluetooth would drop it).
    var overflowed: Bool { state.withLock { $0.overflowed } }
}
