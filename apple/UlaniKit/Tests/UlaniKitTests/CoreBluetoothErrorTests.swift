import CoreBluetooth
import Foundation
import Testing
@testable import UlaniKit

/// How CoreBluetooth errors and manager states become UlaniErrors. Pure:
/// no central manager is created, nothing touches the radio.
@Suite struct CoreBluetoothErrorTests {
    /// What the delegate callbacks hand over: plain NSErrors in the CoreBluetooth domains.
    static let bondLostErrors: [NSError] = [
        NSError(domain: CBErrorDomain, code: CBError.Code.peerRemovedPairingInformation.rawValue),
        NSError(domain: CBATTErrorDomain, code: CBATTError.Code.insufficientAuthentication.rawValue),
        NSError(domain: CBATTErrorDomain, code: CBATTError.Code.insufficientEncryption.rawValue),
        NSError(domain: CBATTErrorDomain, code: CBATTError.Code.insufficientEncryptionKeySize.rawValue),
    ]

    @Test(arguments: bondLostErrors)
    func lostBondsNeedTheUser(error: NSError) {
        let mapped = CoreBluetoothLink.ulaniError(for: error, during: "subscribing to notifications")
        #expect(mapped == .bondLost)
        #expect(!mapped.isRetryable)
    }

    @Test func swiftErrorValuesMapLikeTheirNSErrors() {
        #expect(CoreBluetoothLink.ulaniError(for: CBError(.peerRemovedPairingInformation), during: "connecting")
                == .bondLost)
        #expect(CoreBluetoothLink.ulaniError(for: CBATTError(.insufficientAuthentication), during: "writing")
                == .bondLost)
        #expect(CoreBluetoothLink.ulaniError(for: CBATTError(.insufficientEncryption), during: "reading")
                == .bondLost)
        #expect(CoreBluetoothLink.ulaniError(for: CBATTError(.insufficientEncryptionKeySize), during: "reading")
                == .bondLost)
    }

    @Test func otherBluetoothErrorsAreLinkFailuresNamingTheStep() {
        let timeout = CoreBluetoothLink.ulaniError(for: CBError(.connectionTimeout), during: "connecting")
        guard case .linkLost(let reason) = timeout else {
            Issue.record("expected linkLost, got \(timeout)")
            return
        }
        #expect(reason.hasPrefix("connecting failed: "))
        #expect(reason.contains("connection timeout"))
        #expect(timeout.isRetryable)

        let att = CoreBluetoothLink.ulaniError(for: CBATTError(.writeNotPermitted), during: "writing a command")
        guard case .linkLost(let attReason) = att else {
            Issue.record("expected linkLost, got \(att)")
            return
        }
        #expect(attReason.hasPrefix("writing a command failed: "))
        #expect(attReason.contains("0x03"))
    }

    @Test func authorizationIsNotABondProblem() {
        // ATT "insufficient authorization" is an application-level refusal, not pairing.
        let mapped = CoreBluetoothLink.ulaniError(for: CBATTError(.insufficientAuthorization), during: "reading")
        #expect(mapped != .bondLost)
    }

    @Test func ulaniErrorsPassThrough() {
        #expect(CoreBluetoothLink.ulaniError(for: UlaniError.notFound, during: "scanning") == .notFound)
        #expect(CoreBluetoothLink.ulaniError(for: UlaniError.linkLost("x"), during: "y") == .linkLost("x"))
    }

    @Test func unknownErrorsAreLinkFailures() {
        let mapped = CoreBluetoothLink.ulaniError(for: NSError(domain: "Elsewhere", code: 42), during: "reading")
        guard case .linkLost(let reason) = mapped else {
            Issue.record("expected linkLost, got \(mapped)")
            return
        }
        #expect(reason.hasPrefix("reading failed: "))
    }

    // MARK: manager state

    @Test(arguments: [CBManagerState.poweredOff, .unauthorized, .unsupported])
    func bluetoothOffOrForbiddenIsUnavailable(state: CBManagerState) {
        guard case .unavailable(let error) = CoreBluetoothLink.readiness(of: state),
              case .bluetoothUnavailable = error else {
            Issue.record("state \(state.rawValue) should be unavailable")
            return
        }
        #expect(!error.isRetryable)
        #expect(CoreBluetoothLink.stateChangeError(state) == error)
    }

    @Test func poweredOnIsReady() {
        #expect(CoreBluetoothLink.readiness(of: .poweredOn) == .ready)
        #expect(CoreBluetoothLink.stateChangeError(.poweredOn) == nil)
    }

    @Test(arguments: [CBManagerState.unknown, .resetting])
    func transientStatesAreWaitedOut(state: CBManagerState) {
        #expect(CoreBluetoothLink.readiness(of: state) == .pending)
    }

    @Test(arguments: [CBManagerState.unknown, .resetting])
    func losingPowerMidSessionDropsTheLink(state: CBManagerState) {
        // A reset invalidates every peripheral; it is transient, so the connector retries.
        guard case .linkLost = CoreBluetoothLink.stateChangeError(state) else {
            Issue.record("state \(state.rawValue) should end the link with linkLost")
            return
        }
    }

    @Test func messagesTellWhatIsWrong() {
        #expect(CoreBluetoothLink.readiness(of: .poweredOff) == .unavailable(.bluetoothUnavailable("Bluetooth is off")))
        #expect(CoreBluetoothLink.readiness(of: .unauthorized)
                == .unavailable(.bluetoothUnavailable("this app is not allowed to use Bluetooth")))
        #expect(CoreBluetoothLink.readiness(of: .unsupported)
                == .unavailable(.bluetoothUnavailable("this device does not support Bluetooth LE")))
    }
}
