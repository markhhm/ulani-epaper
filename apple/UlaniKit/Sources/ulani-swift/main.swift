import Dispatch
import Foundation
import os

// ulani-swift: push photos to the ULANI calendar from a Mac, over CoreBluetooth or through
// the TCP relay; see `ulani-swift --help`. Exit status: 0 ok, 1 error, 2 usage, 130 interrupted.

let interrupts = OSAllocatedUnfairLock(initialState: 0)
let work = Task {
    await CLI.main(Array(CommandLine.arguments.dropFirst()), console: .standard, connection: .live)
}

// Ctrl-C cancels the command, so the calendar is let go of cleanly (goodbye skipped,
// link disconnected); a second Ctrl-C quits at once.
signal(SIGINT, SIG_IGN)
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interruptSource.setEventHandler {
    let count = interrupts.withLock { count in
        count += 1
        return count
    }
    if count > 1 { exit(130) }
    Console.standard.errorLine("\ninterrupted: disconnecting (Ctrl-C again to quit now)")
    work.cancel()
}
interruptSource.resume()

let status = await work.value
exit(interrupts.withLock { $0 } > 0 ? 130 : status)
