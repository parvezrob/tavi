import Foundation
@testable import Tavi
import Testing

// The pairing exchange and the checks behind it (#45, #105). Nothing here
// is stored, so every failure must leave the phone unpaired and say why in
// words the person holding it can act on.
struct HostPairingTests {
    private static let grant = #"""
    {"credential":"token-1","device":{"id":"device-1","name":"iPhone"},
     "host":{"name":"studio-mac","fingerprint":"fp-1"}}
    """#

    private static func payload() throws -> PairingPayload {
        PairingPayload(
            endpoint: try Fixtures.hostEndpoint(),
            secret: "single-use",
            fingerprint: "fp-1",
            hostName: "studio-mac"
        )
    }

    private static func redeem(_ host: StubHost) async throws -> Result<HostPairing.Grant, HostPairing.Failure> {
        do {
            return .success(try await HostPairing.redeem(payload(), transport: host.transport))
        } catch let failure as HostPairing.Failure {
            return .failure(failure)
        }
    }

    private static func verify(_ host: StubHost) async throws -> Result<HostPairing.Checks, HostPairing.Failure> {
        do {
            return .success(try await HostPairing.verify(
                endpoint: try Fixtures.hostEndpoint(),
                credential: "token-1",
                transport: host.transport
            ))
        } catch let failure as HostPairing.Failure {
            return .failure(failure)
        }
    }

    // MARK: - Redeeming the code

    @Test func redeemingTheCodeReturnsTheGrantTheComputerMinted() async throws {
        let outcome = try await Self.redeem(StubHost(.json(200, Self.grant)))
        #expect(outcome.value == HostPairing.Grant(
            credential: "token-1",
            deviceId: "device-1",
            deviceName: "iPhone",
            hostName: "studio-mac",
            fingerprint: "fp-1"
        ))
    }

    @Test func theCodeIsRedeemedAtThePairingRoute() async throws {
        let host = StubHost(.json(200, Self.grant))
        _ = try await Self.redeem(host)
        #expect(await host.calls == ["POST /api/pair"])
    }

    // The exchange that mints the credential is the one call that has none.
    @Test func redeemingTheCodeCarriesNoBearer() async throws {
        let host = StubHost(.json(200, Self.grant))
        _ = try await Self.redeem(host)
        #expect(await host.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test(arguments: [401, 403])
    func aCodeTheComputerRejectsSaysWhatTheComputerSaid(status: Int) async throws {
        let outcome = try await Self.redeem(StubHost(.json(status, #"{"error":"That pairing code has expired."}"#)))
        #expect(outcome.failure == .codeRejected("That pairing code has expired."))
    }

    // The phone reached a different machine than the one on the code, so
    // the grant is dropped rather than stored (#45).
    @Test func aComputerWithAnotherFingerprintIsNotPairedWith() async throws {
        let outcome = try await Self.redeem(StubHost(.json(200, #"""
        {"credential":"token-1","device":{"id":"device-1","name":"iPhone"},
         "host":{"name":"studio-mac","fingerprint":"fp-9"}}
        """#)))
        #expect(outcome.failure == .fingerprintMismatch(shown: "fp-1", actual: "fp-9"))
    }

    @Test func aComputerTooOldToPairSaysToUpdateItsHost() async throws {
        let outcome = try await Self.redeem(StubHost(.json(404, #"{"error":"Not found."}"#)))
        #expect(outcome.failure == .unreachable(
            "This computer's Tavi host is too old to pair with this version of Tavi. Update it with `npx tavi-host update`."
        ))
    }

    @Test func aRefusalWithNoSentenceAtAllGetsPairingsOwnWords() async throws {
        let outcome = try await Self.redeem(StubHost(.json(500, "")))
        #expect(outcome.failure == .unreachable("The host refused the pairing code (HTTP 500)."))
    }

    @Test func aComputerThatDoesNotAnswerIsUnreachableRatherThanRejecting() async throws {
        let outcome = try await Self.redeem(StubHost(.silence))
        #expect(outcome.isUnreachable)
    }

    // MARK: - Proving the credential works

    @Test func verifyingCountsTheSessionsTheComputerReported() async throws {
        let outcome = try await Self.verify(StubHost(.json(200, #"""
        {"available":true,"agents":[{"id":"pane-1","agent":"claude","status":"working","cwd":"/repo",
          "title":"","workspaceId":"ws-1","tabId":"tab-1","focused":true}]}
        """#)))
        #expect(outcome.value?.sessionsFound == 1)
    }

    @Test func verifyingReportsWhetherTheComputerCanRunAgents() async throws {
        let outcome = try await Self.verify(StubHost(.json(200, #"{"available":true,"agents":[]}"#)))
        #expect(outcome.value?.herdrAvailable == true)
    }

    @Test func verifyingAsksAnAuthenticatedRouteWithTheNewCredential() async throws {
        let host = StubHost(.json(200, #"{"available":true,"agents":[]}"#))
        _ = try await Self.verify(host)
        #expect(await host.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
    }

    // A credential the host will not take is worth nothing, so pairing
    // stops here rather than saving it.
    @Test func aCredentialTheComputerDoesNotAcceptFailsTheCheck() async throws {
        let outcome = try await Self.verify(StubHost(.json(401, #"{"error":"Unauthorized."}"#)))
        #expect(outcome.failure == .unreachable("The new credential was not accepted by the host."))
    }

    @Test func aComputerThatStoppedAnsweringFailsTheCheckAsUnreachable() async throws {
        let outcome = try await Self.verify(StubHost(.silence))
        #expect(outcome.isUnreachable)
    }
}

// Reading one field out of an outcome, so each test above asserts one thing.
private extension Result where Failure == HostPairing.Failure {
    var value: Success? {
        if case let .success(value) = self { return value }
        return nil
    }

    var failure: HostPairing.Failure? {
        if case let .failure(failure) = self { return failure }
        return nil
    }

    var isUnreachable: Bool {
        guard case let .failure(failure) = self, case .unreachable = failure else { return false }
        return true
    }
}
