import Foundation
@testable import Tavi
import Testing

// The one place a request to a paired computer is built and its answer
// read (#92, #96): the bearer, the query, the decode, the host's own
// sentence, and the #81 reading that tells an old host from a refusal.
struct HostClientTests {
    private struct Answer: Decodable, Sendable, Equatable {
        let name: String
    }

    private static let sentences = HostClient.Sentences(
        answer: "a folder list",
        tooOld: "This computer's Tavi host is too old to do that. Update it with `npx tavi-host update`.",
        cannotAnswer: "The host could not list your folders"
    )

    private static func fetch(_ host: StubHost, saying sentences: HostClient.Sentences = sentences) async throws -> HostClient.Reply<Answer> {
        let client = try Fixtures.hostClient(host)
        return await client.fetch("GET", "/api/folders", saying: sentences)
    }

    @Test func decodesTheHostsAnswerIntoItsValue() async throws {
        let reply = try await Self.fetch(StubHost(.json(200, #"{"name":"tavi"}"#)))
        #expect(reply.value == Answer(name: "tavi"))
    }

    @Test func aShapeItCannotReadIsAVersionMismatchNotANetworkProblem() async throws {
        let reply = try await Self.fetch(StubHost(.json(200, #"{"nome":"tavi"}"#)))
        #expect(reply.reason == "This host sent a folder list Tavi does not understand. Update the Tavi host and the app to matching versions.")
    }

    @Test func carriesTheHostsOwnSentenceAsARefusal() async throws {
        let reply = try await Self.fetch(StubHost(.json(403, #"{"error":"That folder is outside your project roots."}"#)))
        #expect(reply.sentence == "That folder is outside your project roots.")
    }

    @Test func aRefusalKeepsTheStatusTheHostGaveIt() async throws {
        let reply = try await Self.fetch(StubHost(.json(409, #"{"error":"Already gone."}"#)))
        #expect(reply.status == 409)
    }

    @Test func aRefusalKeepsTheBodyTheFeatureStillHasToRead() async throws {
        let reply = try await Self.fetch(StubHost(.json(400, #"{"error":"No.","outsideRoots":true}"#)))
        #expect(reply.body?.contains("outsideRoots") == true)
    }

    // #81: the refusal decode used to run first, so a host that simply does
    // not have the route said "404" instead of "update your host".
    @Test func aGeneric404MeansTheHostIsTooOld() async throws {
        let reply = try await Self.fetch(StubHost(.json(404, #"{"error":"Not found."}"#)))
        #expect(reply.reason == Self.sentences.tooOld)
    }

    // The other half of #81: a route that exists and answered 404 about a
    // real thing is a refusal, and its words are the host's.
    @Test func aSpecific404IsARefusalNotAnOldHost() async throws {
        let reply = try await Self.fetch(StubHost(.json(404, #"{"error":"No such file."}"#)))
        #expect(reply.sentence == "No such file.")
    }

    @Test func a404WithNoSentenceAtAllMeansTooOld() async throws {
        let reply = try await Self.fetch(StubHost(.json(404, "")))
        #expect(reply.reason == Self.sentences.tooOld)
    }

    @Test func aFileRouteReadsTheGeneric404AsARefusalInstead() async throws {
        var sentences = Self.sentences
        sentences.genericNotFound = .isARefusal
        let reply = try await Self.fetch(StubHost(.json(404, #"{"error":"Not found."}"#)), saying: sentences)
        #expect(reply.sentence == "Not found.")
    }

    @Test func aStatusWithNoSentenceGetsTheFeaturesOwnWords() async throws {
        let reply = try await Self.fetch(StubHost(.json(500, "")))
        #expect(reply.reason == "The host could not list your folders (HTTP 500).")
    }

    @Test func aStatusWithNoSentenceAndNoWordsFallsBackToTheGeneralOne() async throws {
        let reply = try await Self.fetch(
            StubHost(.json(500, "")),
            saying: HostClient.Sentences(answer: "a folder list", tooOld: "Too old.")
        )
        #expect(reply.reason == "The host could not answer (HTTP 500).")
    }

    // A computer that never answered is a failure to say in the system's
    // own words, never a refusal this client invented words for.
    @Test func aComputerThatDoesNotAnswerIsAFailureAndNotARefusal() async throws {
        let reply = try await Self.fetch(StubHost(.silence))
        #expect(reply.reason?.isEmpty == false && reply.sentence == nil)
    }

    @Test func everyRequestCarriesTheBearer() async throws {
        let host = StubHost(.json(200, #"{"name":"tavi"}"#))
        _ = try await Self.fetch(host)
        #expect(await host.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    // Pairing is the one exchange with no credential yet (#45); an empty
    // bearer would be a header the host has to reject.
    @Test func aClientWithNoCredentialSendsNoBearer() async throws {
        let host = StubHost(.json(201, #"{"name":"tavi"}"#))
        let client = try Fixtures.hostClient(host, credential: "")
        let reply: HostClient.Reply<Answer> = await client.fetch("POST", "/api/pair", saying: Self.sentences)
        #expect(reply.value != nil)
        #expect(await host.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func theQueryIsOrderedByKeySoTwoIdenticalCallsAreIdentical() async throws {
        let host = StubHost(.json(200, #"{"name":"tavi"}"#))
        let client = try Fixtures.hostClient(host)
        let reply: HostClient.Reply<Answer> = await client.fetch(
            "GET",
            "/api/files",
            query: ["path": "src", "cwd": "/repo"],
            saying: Self.sentences
        )
        #expect(reply.value != nil)
        #expect(await host.lastRequest?.url?.query == "cwd=/repo&path=src")
    }

    @Test func aJSONBodyBringsItsContentTypeWithIt() throws {
        let request = try Fixtures.hostClient(StubHost()).request("POST", "/api/herdr/tabs", body: ["cwd": "/repo"])
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func aPerCallTimeoutOverridesTheSessionsOwn() throws {
        let request = try Fixtures.hostClient(StubHost()).request("DELETE", "/api/devices/me", timeout: 10)
        #expect(request?.timeoutInterval == 10)
    }

    // The events socket's address is built by HostEndpoint, not here, but
    // its bearer still comes from the one place that writes one (#96).
    @Test func anAddressThisClientDidNotBuildStillGetsTheBearer() throws {
        let url = try #require(URL(string: "wss://studio.tailnet.ts.net/api/events"))
        let request = try Fixtures.hostClient(StubHost()).request(url, timeout: 8)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }
}

// Reading one field out of a reply, so each test above asserts one thing.
extension HostClient.Reply {
    var value: Value? {
        if case let .value(value) = self { return value }
        return nil
    }

    var status: Int? {
        if case let .refused(status, _, _) = self { return status }
        return nil
    }

    var sentence: String? {
        if case let .refused(_, sentence, _) = self { return sentence }
        return nil
    }

    var body: String? {
        if case let .refused(_, _, body) = self { return String(bytes: body, encoding: .utf8) }
        return nil
    }

    var reason: String? {
        if case let .failure(reason) = self { return reason }
        return nil
    }
}
