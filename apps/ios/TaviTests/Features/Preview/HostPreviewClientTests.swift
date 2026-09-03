import Foundation
@testable import Tavi
import Testing

// The dev-server preview routes as the phone reads them (#58, #105). These
// routes take the ordinary #81 reading — a bare "Not found." is a computer
// whose host predates them — and the web view is handed a ticket the host
// minted, never the credential these calls carry.
struct HostPreviewClientTests {
    private static let tooOld = "This computer's Tavi host is too old to show dev servers. Update it with `npx tavi-host update`."

    private static func client(_ host: StubHost) throws -> HostPreviewClient {
        HostPreviewClient(endpoint: try Fixtures.hostEndpoint(), credential: "secret", transport: host.transport)
    }

    // MARK: - What the host can open

    @Test func theDoorComesBackWithThePortTheWebViewWillUse() async throws {
        let outcome = try await Self.client(StubHost(.json(200, #"""
        {"doorPort":8443,"ready":true,"cookieName":"tavi_preview"}
        """#))).door()
        #expect(outcome.value?.doorPort == 8443)
    }

    @Test func theCandidatesAreTheDevServersTheSheetOffers() async throws {
        let outcome = try await Self.client(StubHost(.json(200, #"""
        {"available":true,"reason":null,"servers":[{"port":5173,"command":"vite","cwd":"/repo"}]}
        """#))).candidates(cwd: "/repo")
        #expect(outcome.value?.servers.map(\.port) == [5173])
    }

    @Test func openingAPreviewComesBackWithTheTicketTheWebViewNeeds() async throws {
        let outcome = try await Self.client(StubHost(.json(200, #"""
        {"id":"p-1","port":5173,"doorPort":8443,"cookieName":"tavi_preview","ticket":"t-1"}
        """#))).open(cwd: "/repo", port: 5173)
        #expect(outcome.value?.ticket == "t-1")
    }

    @Test func stoppingADevServerSaysWhatWasStopped() async throws {
        let outcome = try await Self.client(StubHost(.json(200, #"""
        {"stopped":true,"pid":4211,"command":"vite"}
        """#))).stop(cwd: "/repo", port: 5173)
        #expect(outcome.value?.command == "vite")
    }

    // The door is the same computer on another port, so the ticket cookie
    // is scoped to this computer alone.
    @Test func theDoorAddressIsTheApiComputerOnTheDoorsPort() throws {
        let door = try Self.client(StubHost()).doorURL(port: 8443)
        #expect(door?.absoluteString == "https://studio.tailnet.ts.net:8443/")
    }

    @Test func theWebViewIsToldTheComputersNameAndNothingSecret() throws {
        let name = try Self.client(StubHost()).hostName
        #expect(name == "studio.tailnet.ts.net")
    }

    // MARK: - What it refuses, in its own words

    @Test func aComputerWithNoPreviewDoorIsARefusalThatSaysWhy() async throws {
        let outcome = try await Self.client(StubHost(.json(409, #"""
        {"error":"This computer has no preview door yet.","doorMissing":true}
        """#))).door()
        #expect(outcome.refusal?.doorMissing == true)
    }

    @Test func aFolderOutsideTheProjectRootsIsARefusalThatSaysWhy() async throws {
        let outcome = try await Self.client(StubHost(.json(400, #"""
        {"error":"That folder is outside your project roots.","outsideRoots":true}
        """#))).open(cwd: "/elsewhere", port: 5173)
        #expect(outcome.refusal?.outsideRoots == true)
    }

    @Test func aPortTheHostWillNotOpenSpeaksTheHostsOwnSentence() async throws {
        let outcome = try await Self.client(StubHost(.json(403, #"""
        {"error":"Nothing is listening on port 5173."}
        """#))).open(cwd: "/repo", port: 5173)
        #expect(outcome.refusal?.error == "Nothing is listening on port 5173.")
    }

    // #81: a route this computer's host has never heard of says what to do
    // about it rather than "404", whether or not it wrote a sentence.
    @Test(arguments: [#"{"error":"Not found."}"#, ""])
    func aPreviewRouteAnOldHostLacksSaysToUpdateIt(body: String) async throws {
        let outcome = try await Self.client(StubHost(.json(404, body))).door()
        #expect(outcome.reason == Self.tooOld)
    }

    @Test func aStatusTheHostGaveNoWordsForIsAFailureNotARefusal() async throws {
        let outcome = try await Self.client(StubHost(.json(500, ""))).door()
        #expect(outcome.reason == "The host could not answer (HTTP 500).")
    }

    @Test func aComputerThatDoesNotAnswerIsAFailureAndNotARefusal() async throws {
        let outcome = try await Self.client(StubHost(.silence)).door()
        #expect(outcome.refusal == nil)
        #expect(outcome.reason?.isEmpty == false)
    }
}

// Reading one field out of an outcome, so each test above asserts one thing.
private extension HostPreviewClient.Outcome {
    var value: Value? {
        if case let .value(value) = self { return value }
        return nil
    }

    var refusal: PreviewRefusal? {
        if case let .refused(_, refusal) = self { return refusal }
        return nil
    }

    var reason: String? {
        if case let .failure(reason) = self { return reason }
        return nil
    }
}
