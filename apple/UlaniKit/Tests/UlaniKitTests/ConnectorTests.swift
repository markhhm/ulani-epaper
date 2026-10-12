import Foundation
import os
import Testing
@testable import UlaniKit

/// A link factory that follows a script, one step per call; after the script it makes
/// good links. Records every call and every link it handed out.
final class LinkScript: Sendable {
    enum Step: Sendable {
        case fail(any Error)
        case link(FakeLink)
    }

    private struct State: Sendable {
        var steps: [Step]
        var calls = 0
        var links: [FakeLink] = []
    }

    private let state: OSAllocatedUnfairLock<State>
    private let fresh: @Sendable () -> FakeLink

    init(_ steps: [Step], fresh: @escaping @Sendable () -> FakeLink = { FakeLink() }) {
        state = OSAllocatedUnfairLock(initialState: State(steps: steps))
        self.fresh = fresh
    }

    var calls: Int { state.withLock { $0.calls } }
    var links: [FakeLink] { state.withLock { $0.links } }

    func make() async throws -> any GattLink {
        let step = state.withLock { s -> Step? in
            s.calls += 1
            return s.steps.isEmpty ? nil : s.steps.removeFirst()
        }
        let link: FakeLink
        switch step {
        case .fail(let error): throw error
        case .link(let scripted): link = scripted
        case nil: link = fresh()
        }
        state.withLock { $0.links.append(link) }
        return link
    }
}

/// Setup retried as one unit, goodbye and disconnect (mirrors test_client.py's connect tests).
@Suite struct ConnectorTests {
    private func connector(_ script: LinkScript, attempts: Int = 4, retryDelay: Duration = .milliseconds(5),
                           timing: SessionTiming = .test, readBarrierEvery: Int? = nil) -> CalendarConnector {
        CalendarConnector(attempts: attempts, retryDelay: retryDelay, timing: timing,
                          readBarrierEvery: readBarrierEvery, makeLink: { try await script.make() })
    }

    @Test func factoryFailuresAreRetried() async throws {
        let script = LinkScript([.fail(UlaniError.notFound), .fail(UlaniError.linkLost("connect timed out"))])
        let bodies = Recorder<Int>()
        let battery = try await connector(script).withCalendar { session in
            bodies.append(1)
            return try await session.battery()
        }
        #expect(battery.level == 4)
        #expect(bodies.values.count == 1)
        #expect(script.calls == 3)
    }

    @Test func failedLinksAreDisconnected() async throws {
        // Python: ["connect-timeout", "notify-cancelled", "ok"]. A factory that throws has
        // no link to hand back (it cleans up itself); a link whose setup fails is ours.
        let dead = FakeLink { $0.dead = true }
        let script = LinkScript([.fail(UlaniError.linkLost("connect timed out")), .link(dead)])
        let battery = try await connector(script).withCalendar { try await $0.battery() }
        #expect(battery.level == 4)
        #expect(script.calls == 3)
        #expect(script.links.count == 2)
        #expect(script.links.map { $0.state.disconnects } == [1, 1])
    }

    @Test func silentUnlockIsRetriedOnANewLink() async throws {
        let silent = FakeLink { $0.silentOpcodes = [Opcode.unlock] }
        let script = LinkScript([.link(silent)])
        // A short reply timeout; a good link that misses it on a loaded machine only
        // costs another attempt.
        let value = try await connector(script, attempts: 10, timing: .quick(reply: .milliseconds(100)))
            .withCalendar { _ in "ran" }
        #expect(value == "ran")
        #expect(silent.state.disconnects == 1)
        #expect(silent.commandWrites == [Command.unlock])
        #expect(script.calls >= 2)
    }

    @Test func givesUpAfterTheAttempts() async throws {
        let script = LinkScript(Array(repeating: .fail(UlaniError.notFound), count: 4))
        await #expect(throws: UlaniError.connectFailed(
            attempts: 4, last: "no e-paper device found (is Bluetooth on and the device nearby?)")) {
            try await connector(script).withCalendar { _ in }
        }
        #expect(script.calls == 4)
    }

    @Test func linksOfFailedAttemptsAreDisconnectedWhenGivingUp() async throws {
        let script = LinkScript([], fresh: { FakeLink { $0.dead = true } })
        await #expect(throws: UlaniError.connectFailed(attempts: 2, last: "Bluetooth link lost: the fake link is dead")) {
            try await connector(script, attempts: 2).withCalendar { _ in }
        }
        #expect(script.links.map { $0.state.disconnects } == [1, 1])
    }

    @Test(arguments: [UlaniError.bondLost, .bluetoothUnavailable("powered off")])
    func errorsOnlyTheUserCanFixAreNotRetried(error: UlaniError) async throws {
        let script = LinkScript([.fail(error)])
        await #expect(throws: error) { try await connector(script).withCalendar { _ in } }
        #expect(script.calls == 1)
    }

    @Test func unexpectedErrorsAreRethrownAfterCleanup() async throws {
        let buggy = FakeLink { $0.buggy = true }
        let script = LinkScript([.link(buggy)])
        await #expect(throws: FakeLinkBug()) { try await connector(script).withCalendar { _ in } }
        #expect(script.calls == 1)
        #expect(buggy.state.disconnects == 1)
    }

    @Test func bodySuccessSaysGoodbyeThenDisconnects() async throws {
        let link = FakeLink()
        let script = LinkScript([.link(link)])
        let slot = try await connector(script).withCalendar { try await $0.currentSlot().page }
        #expect(slot == 3)
        #expect(link.commandWrites == [Command.unlock, Command.getSlot, Command.disconnect])
        #expect(link.state.disconnects == 1)
        #expect(link.state.writesAtDisconnect == link.writes.count)  // goodbye came first
    }

    @Test func bodyErrorStillDisconnects() async throws {
        let link = FakeLink()
        let script = LinkScript([.link(link)])
        await #expect(throws: FakeLinkBug()) {
            try await connector(script).withCalendar { _ in throw FakeLinkBug() }
        }
        #expect(link.state.disconnects == 1)
        #expect(!link.commandWrites.contains(Command.disconnect))  // no goodbye after an error
        #expect(script.calls == 1)  // the body is not retried
    }

    @Test func pushErrorsPassThrough() async throws {
        let link = FakeLink { $0.shown = 4; $0.failPages = [2] }
        let script = LinkScript([.link(link)])
        await #expect(throws: PushError(page: 2, completed: [1: .ok],
                                        underlying: .uploadFailed(page: 2, reply: Reply.dataFail))) {
            _ = try await connector(script).withCalendar {
                try await $0.push([1: filledFrame(1), 2: filledFrame(2)])
            }
        }
        #expect(link.state.disconnects == 1)
    }

    @Test func noGoodbyeAfterReplacingTheShownPage() async throws {
        let link = FakeLink { $0.shown = 2; $0.refreshSilence = true }
        let script = LinkScript([.link(link)])
        let results = try await connector(script).withCalendar {
            try await $0.push([1: filledFrame(1), 2: filledFrame(2)])
        }
        #expect(results == [1: .ok, 2: .ok])
        #expect(!link.commandWrites.contains(Command.disconnect))
        #expect(link.state.disconnects == 1)
    }

    @Test func sessionGetsTheTimingAndReadBarrier() async throws {
        // Every link ignores battery queries, so a setup retried on a loaded machine
        // changes nothing.
        let script = LinkScript([], fresh: { FakeLink { $0.silentOpcodes = [Opcode.battery] } })
        let connector = connector(script, attempts: 10, timing: .quick(reply: .milliseconds(100)),
                                  readBarrierEvery: 10)
        await #expect(throws: UlaniError.noReply(opcode: Opcode.battery)) {
            try await connector.withCalendar { session in
                #expect(try await session.upload(filledFrame(1), page: 1) == .ok)
                _ = try await session.battery()
            }
        }
        let link = try #require(script.links.last)
        #expect(link.log == String(repeating: "wwwwwwwwwwr", count: 83) + "wwwww")
    }

    @Test func waitsBetweenAttempts() async throws {
        let script = LinkScript(Array(repeating: .fail(UlaniError.notFound), count: 3))
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: UlaniError.self) {
            try await connector(script, attempts: 3, retryDelay: .milliseconds(100)).withCalendar { _ in }
        }
        #expect(clock.now - started >= .milliseconds(200))
        #expect(script.calls == 3)
    }

    @Test func doesNotWaitAfterTheLastAttempt() async throws {
        let script = LinkScript([.fail(UlaniError.notFound)])
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: UlaniError.self) {
            try await connector(script, attempts: 1, retryDelay: .seconds(30)).withCalendar { _ in }
        }
        #expect(clock.now - started < .seconds(10))
    }

    @Test func cancellationStopsRetrying() async throws {
        let script = LinkScript([], fresh: { FakeLink { $0.dead = true } })
        let connector = connector(script, attempts: 4, retryDelay: .seconds(30))
        let task = Task { try await connector.withCalendar { _ in } }
        try await waitUntil { script.calls == 1 && script.links.first?.state.disconnects == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(script.calls == 1)
    }

    @Test func zeroAttemptsMakeNoLink() async throws {
        let script = LinkScript([])
        await #expect(throws: UlaniError.connectFailed(attempts: 0, last: "no attempt was made")) {
            try await connector(script, attempts: 0).withCalendar { _ in }
        }
        #expect(script.calls == 0)
    }
}
