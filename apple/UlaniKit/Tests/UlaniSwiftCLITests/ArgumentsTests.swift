import Foundation
import Testing
import UlaniKit
@testable import ulani_swift

private func invocation(_ arguments: [String]) throws -> Invocation {
    guard case .run(let invocation) = try Arguments.parse(arguments) else {
        throw UsageError(description: "not a run: \(arguments)")
    }
    return invocation
}

/// The usage error `arguments` cause, or nil when they parse.
private func usageError(_ arguments: [String]) -> String? {
    do {
        _ = try Arguments.parse(arguments)
        return nil
    } catch {
        return error.description
    }
}

@Suite struct ArgumentsTests {
    @Test func pushDefaults() throws {
        let push = try invocation(["push", "a.png", "b.png"])
        #expect(push == Invocation(command: .push, images: ["a.png", "b.png"], pages: [1, 2]))
        #expect(push.transport == .bluetooth)
        #expect(push.fit == .cover)
        #expect(push.dither)
        #expect(push.strength == 1)
        #expect(!push.dryRun && !push.verbose)
        #expect(push.scanTimeout == .seconds(30))
        #expect(push.assignments.map(\.page) == [1, 2])
        #expect(push.assignments.map(\.path) == ["a.png", "b.png"])
    }

    @Test func showTakesOnePage() throws {
        for page in 1...4 {
            #expect(try invocation(["show", String(page)]) == Invocation(command: .show, pages: [page]))
        }
        let show = try invocation(["--relay", "127.0.0.1:8766", "show", "-v", "3", "--scan-timeout=2"])
        #expect(show == Invocation(command: .show, pages: [3], transport: .relay(host: "127.0.0.1", port: 8766),
                                   verbose: true, scanTimeout: .seconds(2)))
        #expect(show.images.isEmpty && show.assignments.isEmpty)
        #expect(try invocation(["show", "--", "2"]).pages == [2])
    }

    @Test func strengthTakesTheGrainLevels() throws {
        for level in [1.0, 0.8, 0.65, 0.5] {
            #expect(try invocation(["push", "--strength", String(level), "a.png"]).strength == level)
        }
        for bad in ["0", "-0.5", "1.5", "x"] {
            #expect(throws: UsageError.self) { try invocation(["push", "--strength", bad, "a.png"]) }
        }
    }

    @Test func cropsArePerPage() throws {
        let push = try invocation(["push", "a.png", "b.png", "--crop", "2=0.25,0.1,0.5,0.5", "--crop= 1 = 0 , 0.1 ,1,0.8"])
        #expect(push.crops == [2: Crop(left: 0.25, top: 0.1, width: 0.5, height: 0.5),
                               1: Crop(left: 0, top: 0.1, width: 1, height: 0.8)])
        // A crop is for a page: with --pages 3,1 the one for page 3 is a.png's.
        let mapped = try invocation(["probe", "--pages", "3,1", "--crop", "3=0,0,1,0.8", "a.png", "b.png"])
        #expect(mapped.crops == [3: Crop(left: 0, top: 0, width: 1, height: 0.8)])
        #expect(try invocation(["push", "a.png"]).crops.isEmpty)
        // Any finite numbers: whether they suit the photo is checked once it is loaded.
        #expect(try invocation(["push", "a.png", "--crop", "1=-1,2,0,1e3"]).crops[1] == Crop(left: -1, top: 2, width: 0, height: 1000))
    }

    @Test func cropUsageErrors() {
        for bad in ["", "1", "1=", "=0,0,1,1", "0=0,0,1,1", "5=0,0,1,1", "x=0,0,1,1", "1=0,0,1", "1=0,0,1,1,1",
                    "1=0,0,1,x", "1=0,0,1,", "1=0,x,0,1,1", "1=0.25,,0.1,0.5,0.5", "1=0,0,1,nan", "1=0,0,inf,1",
                    "1:0,0,1,1"] {
            #expect(usageError(["push", "a", "--crop", bad]) == "--crop expects PAGE=LEFT,TOP,WIDTH,HEIGHT "
                    + "(a page 1-4 and four fractions of the photo), got '\(bad)'")
        }
        #expect(usageError(["push", "a", "b", "--crop", "1=0,0,1,1", "--crop", "1=0,0,1,0.8"]) == "--crop gives page 1 twice")
        #expect(usageError(["push", "a", "--crop", "2=0,0,1,1"]) == "--crop is for page 2, which gets no image")
        #expect(usageError(["push", "a", "b", "--pages", "4,3", "--crop", "1=0,0,1,1"])
                == "--crop is for page 1, which gets no image")
        #expect(usageError(["push", "a", "--fit", "contain", "--crop", "1=0,0,1,1"])
                == "--crop applies to --fit cover only (contain shows the whole image)")
        #expect(usageError(["info", "--crop", "1=0,0,1,1"]) == "--crop applies to push and probe only")
        #expect(usageError(["show", "1", "--crop", "1=0,0,1,1"]) == "--crop applies to push and probe only")
        #expect(usageError(["push", "a", "--crop"]) == "--crop needs a value")
    }

    @Test func optionsGoAnywhereAndTakeEqualsValues() throws {
        let push = try invocation(["--relay", "127.0.0.1:8766", "push", "--fit=contain", "a.png", "--no-dither",
                                   "--pages", "3,1", "b.png", "-v", "--scan-timeout", "2.5", "--dry-run"])
        #expect(push == Invocation(command: .push, images: ["a.png", "b.png"], pages: [3, 1],
                                   transport: .relay(host: "127.0.0.1", port: 8766), fit: .contain, dither: false,
                                   dryRun: true, verbose: true, scanTimeout: .milliseconds(2500)))
        #expect(push.assignments.map(\.page) == [3, 1])
        #expect(try invocation(["probe", "--verbose", "--pages= 4 , 2 ", "a", "b"]).pages == [4, 2])
    }

    @Test func relayAddresses() throws {
        #expect(try invocation(["info", "--relay=[::1]:8765"]).transport == .relay(host: "::1", port: 8765))
        #expect(try invocation(["info", "--relay", "pc.local:1"]).transport == .relay(host: "pc.local", port: 1))
        #expect(try invocation(["--relay", "h:2", "info", "--ble"]).transport == .bluetooth)
        for bad in ["nohost", ":8765", "h:", "h:0", "h:70000", "h:x"] {
            #expect(usageError(["info", "--relay", bad]) == "--relay expects HOST:PORT, got '\(bad)'")
        }
    }

    @Test func scanTimeoutBounds() throws {
        #expect(try invocation(["info", "--scan-timeout", "0.001"]).scanTimeout == .milliseconds(1))
        #expect(try invocation(["info", "--scan-timeout", "86400"]).scanTimeout == .seconds(86400))
    }

    @Test func flushEveryDefaultsPerTransport() throws {
        let relay = try invocation(["info", "--relay", "h:1"])
        #expect(relay.relayFlushEvery == 10)
        #expect(relay.readBarrierEvery == nil)
        let ble = try invocation(["info"])
        #expect(ble.readBarrierEvery == nil)
        let tuned = try invocation(["info", "--flush-every", "0"])
        #expect(tuned.relayFlushEvery == 0)
        #expect(tuned.readBarrierEvery == nil)
        #expect(try invocation(["info", "--flush-every=10"]).readBarrierEvery == 10)
        #expect(usageError(["info", "--flush-every", "-1"]) == "--flush-every expects a number >= 0, got '-1'")
    }

    @Test func doubleDashEndsOptions() throws {
        #expect(try invocation(["push", "--", "-odd.png", "--fit"]).images == ["-odd.png", "--fit"])
    }

    @Test func helpAndVersion() throws {
        #expect(try Arguments.parse(["-h"]) == .help)
        #expect(try Arguments.parse(["push", "--help", "--frob"]) == .help)
        #expect(try Arguments.parse(["--version"]) == .version)
        for word in ["info", "show PAGE", "push", "probe", "--relay", "--fit", "--no-dither", "--pages", "--crop", "--dry-run",
                     "--verbose", "--scan-timeout", "--flush-every", "exit status"] {
            #expect(Arguments.usage.contains(word), "usage lacks \(word)")
        }
    }

    @Test func usageErrors() {
        #expect(usageError([]) == "missing command (info, show, push or probe)")
        #expect(usageError(["-v"]) == "missing command (info, show, push or probe)")
        #expect(usageError(["frob"]) == "unknown command 'frob'")
        #expect(usageError(["--frob", "info"]) == "unknown option '--frob'")
        #expect(usageError(["push"]) == "push needs 1-4 images (one per page), got 0")
        #expect(usageError(["probe", "a", "b", "c", "d", "e"]) == "probe needs 1-4 images (one per page), got 5")
        #expect(usageError(["info", "a.png"]) == "info takes no images")
        #expect(usageError(["info", "--fit", "cover"]) == "--fit applies to push and probe only")
        #expect(usageError(["info", "--dry-run"]) == "--dry-run applies to push and probe only")
        #expect(usageError(["show"]) == "show needs one page (1-4), got 0 arguments")
        #expect(usageError(["show", "1", "2"]) == "show needs one page (1-4), got 2 arguments")
        #expect(usageError(["show", "2", "a.png"]) == "show needs one page (1-4), got 2 arguments")
        for bad in ["0", "5", "x", "1.5", "1,2", "", "a.png"] {
            #expect(usageError(["show", bad]) == "show expects a page 1-4, got '\(bad)'")
        }
        #expect(usageError(["show", "2", "--pages", "2"]) == "--pages applies to push and probe only")
        #expect(usageError(["show", "--fit", "cover", "2"]) == "--fit applies to push and probe only")
        #expect(usageError(["show", "2", "--dry-run"]) == "--dry-run applies to push and probe only")
        #expect(usageError(["push", "a", "--fit", "stretch"]) == "--fit expects cover or contain, got 'stretch'")
        #expect(usageError(["push", "a", "--relay"]) == "--relay needs a value")
        #expect(usageError(["push", "a", "--verbose=yes"]) == "--verbose takes no value")
        #expect(usageError(["push", "a", "--pages", "1,2"]) == "--pages lists 2 page(s) for 1 image(s)")
        #expect(usageError(["push", "a", "b", "--pages", "1,1"]) == "--pages lists page 1 twice")
        for bad in ["0", "5", "x", "1,", ""] {
            #expect(usageError(["push", "a", "--pages", bad]) == "--pages expects pages 1-4 separated by commas, got '\(bad)'")
        }
        for bad in ["0", "-1", "x", "inf", "nan", "1e300", "0.0009", "86400.5"] {
            #expect(usageError(["info", "--scan-timeout", bad])
                    == "--scan-timeout expects 0.001 to 86400 seconds, got '\(bad)'")
        }
    }
}
