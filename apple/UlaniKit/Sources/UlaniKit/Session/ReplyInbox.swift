import Foundation
import os

/// Notifications waiting to be read, one FIFO per characteristic (Python: the two
/// asyncio queues of `Calendar`). A reader asks for the next value with a given opcode;
/// values that do not start with it are discarded, like `Calendar._await_reply` does.
actor ReplyInbox {
    private struct Waiter {
        let id: UInt64
        let opcode: UInt8
        let continuation: CheckedContinuation<Data, any Error>
        let timer: Task<Void, Never>
    }

    private var buffers: [GattCharacteristic: [Data]] = [:]
    private var waiters: [GattCharacteristic: [Waiter]] = [:]
    private var closedReason: String?
    private var lastID: UInt64 = 0
    /// Characteristics with buffered values. Mirrors `buffers` so `hasPending` can answer
    /// synchronously (the image stream's `shouldStop` cannot await).
    private nonisolated let pending = OSAllocatedUnfairLock(initialState: Set<GattCharacteristic>())

    /// Hand `notification` to a waiting reader, or buffer it.
    func deliver(_ notification: GattNotification) {
        let characteristic = notification.characteristic, value = notification.value
        if var list = waiters[characteristic], !list.isEmpty {
            // A waiting reader takes the value; one it does not want is dropped.
            if let i = list.firstIndex(where: { value.first == $0.opcode }) {
                let waiter = list.remove(at: i)
                waiters[characteristic] = list
                waiter.timer.cancel()
                waiter.continuation.resume(returning: value)
            }
            return
        }
        buffers[characteristic, default: []].append(value)
        syncPending(characteristic)
    }

    /// The next value on `characteristic` whose first byte is `opcode`; earlier values
    /// with another opcode are discarded. Throws `noReply(opcode:)` after `timeout`, and
    /// `linkLost` once the inbox is closed.
    func next(on characteristic: GattCharacteristic, opcode: UInt8, timeout: Duration) async throws -> Data {
        var buffer = buffers[characteristic] ?? []
        var found: Data?
        while found == nil, !buffer.isEmpty {
            let value = buffer.removeFirst()
            if value.first == opcode { found = value }
        }
        buffers[characteristic] = buffer
        syncPending(characteristic)
        if let found { return found }
        if let reason = closedReason { throw UlaniError.linkLost(reason) }
        lastID += 1
        let id = lastID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.fail(id, on: characteristic, with: UlaniError.noReply(opcode: opcode))
                }
                waiters[characteristic, default: []].append(
                    Waiter(id: id, opcode: opcode, continuation: continuation, timer: timer))
            }
        } onCancel: {
            Task { await self.fail(id, on: characteristic, with: CancellationError()) }
        }
    }

    /// Forget every buffered value on `characteristic` (stale replies).
    func drain(_ characteristic: GattCharacteristic) {
        buffers[characteristic] = []
        syncPending(characteristic)
    }

    /// Whether a value is buffered on `characteristic`. Synchronous, for `shouldStop`.
    nonisolated func hasPending(_ characteristic: GattCharacteristic) -> Bool {
        pending.withLock { $0.contains(characteristic) }
    }

    /// The link is gone: fail every waiting reader and every later `next` with `linkLost`.
    func close(reason: String) {
        closedReason = reason
        let all = waiters.values.flatMap { $0 }
        waiters = [:]
        for waiter in all {
            waiter.timer.cancel()
            waiter.continuation.resume(throwing: UlaniError.linkLost(reason))
        }
    }

    private func fail(_ id: UInt64, on characteristic: GattCharacteristic, with error: any Error) {
        guard var list = waiters[characteristic], let i = list.firstIndex(where: { $0.id == id }) else { return }
        let waiter = list.remove(at: i)
        waiters[characteristic] = list
        waiter.timer.cancel()
        waiter.continuation.resume(throwing: error)
    }

    private func syncPending(_ characteristic: GattCharacteristic) {
        let nonEmpty = !(buffers[characteristic] ?? []).isEmpty
        pending.withLock { set in
            if nonEmpty { set.insert(characteristic) } else { set.remove(characteristic) }
        }
    }
}
