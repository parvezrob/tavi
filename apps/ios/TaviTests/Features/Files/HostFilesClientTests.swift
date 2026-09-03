import Foundation
@testable import Tavi
import Testing

// The read-only file routes as the phone reads them (#25, #57, #61, #105).
// These routes have their own 404s ("No such file."), so the #81 reading is
// inverted here: the host's sentence stands, and only a 404 with nothing in
// it means a computer whose host predates the routes.
struct HostFilesClientTests {
    private static let tooOld = "This computer's Tavi host is too old to show files. Update it with `npx tavi-host update`."

    private static func client(_ host: StubHost) throws -> HostFilesClient {
        HostFilesClient(endpoint: try Fixtures.hostEndpoint(), credential: "secret", transport: host.transport)
    }

    private static func list(_ host: StubHost) async throws -> HostFilesClient.Outcome<DirectoryListing> {
        try await client(host).list(cwd: "/repo", path: "src")
    }

    // MARK: - What the host can show

    @Test func aFolderComesBackAsTheEntriesTheSheetLists() async throws {
        let outcome = try await Self.list(StubHost(.json(200, #"""
        {"path":"/repo/src","relativePath":"src","truncated":false,
         "entries":[{"name":"main.swift","kind":"file","size":12,"ignored":false,"preview":"text"}]}
        """#)))
        #expect(outcome.value?.entries.map(\.name) == ["main.swift"])
    }

    @Test func aFileRouteAsksTheAddressItAlwaysAsked() async throws {
        let host = StubHost(.json(200, #"{"path":"/repo/src","relativePath":"src","entries":[],"truncated":false}"#))
        _ = try await Self.list(host)
        #expect(await host.calls == ["GET /api/files"])
    }

    // MARK: - What it refuses, in its own words

    // Every 404 these routes answer is about a real thing, the bare
    // "Not found." of #81 included — the host's sentence stands.
    @Test(arguments: ["No such file.", "Not found."])
    func aFileRoutes404IsARefusalInTheHostsOwnWords(sentence: String) async throws {
        let outcome = try await Self.list(StubHost(.json(404, #"{"error":"\#(sentence)"}"#)))
        #expect(outcome.refusal?.error == sentence)
    }

    // Only a 404 with nothing in it is a host that predates these routes,
    // and the words say what to do about it.
    @Test func aBare404IsAComputerWhoseHostIsTooOldToShowFiles() async throws {
        let outcome = try await Self.list(StubHost(.json(404, "")))
        #expect(outcome.reason == Self.tooOld)
    }

    // Never render a secret, not even to say how big it is (#57).
    @Test func aSecretTheHostWillNotShowComesBackAsASecretRefusal() async throws {
        let outcome = try await Self.client(StubHost(.json(403, #"""
        {"error":"That file looks like a secret.","preview":"secret","size":128,"mime":"text/plain"}
        """#))).content(cwd: "/repo", path: ".env")
        #expect(outcome.refusal?.preview == .secret)
    }

    @Test func aPathOutsideTheProjectRootsIsARefusalThatSaysWhy() async throws {
        let outcome = try await Self.client(StubHost(.json(400, #"""
        {"error":"That path is outside your project roots.","outsideRoots":true}
        """#))).stat(cwd: "/repo", path: "../../etc/passwd")
        #expect(outcome.refusal?.outsideRoots == true)
    }

    @Test func aFolderThatIsNotARepositoryIsARefusalThatSaysWhy() async throws {
        let outcome = try await Self.client(StubHost(.json(400, #"""
        {"error":"That folder is not a git repository.","notRepository":true}
        """#))).changes(cwd: "/tmp")
        #expect(outcome.refusal?.notRepository == true)
    }

    @Test func aRefusalTooLargeToShowCarriesHowBigTheFileIs() async throws {
        let outcome = try await Self.client(StubHost(.json(413, #"""
        {"error":"That file is too large to show.","preview":"binary","size":2411724}
        """#))).content(cwd: "/repo", path: "big.bin")
        #expect(outcome.refusal?.size == 2_411_724)
    }

    // MARK: - Bytes the sheet renders itself

    @Test func rawBytesComeBackWithTheTypeTheHostLabelledThem() async throws {
        let outcome = try await Self.client(StubHost(.body(200, "PNG", mime: "image/png")))
            .raw(cwd: "/repo", path: "logo.png")
        #expect(outcome.value?.mime == "image/png")
    }

    @Test func aRawFileTheHostRefusesIsStillTheHostsOwnSentence() async throws {
        let outcome = try await Self.client(StubHost(.json(404, #"{"error":"No such file."}"#)))
            .raw(cwd: "/repo", path: "gone.png")
        #expect(outcome.refusal?.error == "No such file.")
    }

    @Test func anUploadedImageComesBackWithWhereItLandedOnTheComputer() async throws {
        let outcome = try await Self.client(StubHost(.json(201, #"""
        {"path":"/repo/.tavi/uploads/a.png","bytes":3}
        """#))).upload(cwd: "/repo", data: Data("PNG".utf8), mime: "image/png")
        #expect(outcome.value?.path == "/repo/.tavi/uploads/a.png")
    }

    @Test func anUploadTheHostRefusesSaysWhyInTheHostsWords() async throws {
        let outcome = try await Self.client(StubHost(.json(413, #"{"error":"That image is too large."}"#)))
            .upload(cwd: "/repo", data: Data("PNG".utf8), mime: "image/png")
        #expect(outcome.refusal?.error == "That image is too large.")
    }

    // MARK: - No answer at all

    @Test func aComputerThatDoesNotAnswerIsAFailureAndNotARefusal() async throws {
        let outcome = try await Self.list(StubHost(.silence))
        #expect(outcome.refusal == nil)
        #expect(outcome.reason?.isEmpty == false)
    }
}

// Reading one field out of an outcome, so each test above asserts one thing.
private extension HostFilesClient.Outcome {
    var value: Value? {
        if case let .value(value) = self { return value }
        return nil
    }

    var refusal: Refusal? {
        if case let .refused(_, refusal) = self { return refusal }
        return nil
    }

    var reason: String? {
        if case let .failure(reason) = self { return reason }
        return nil
    }
}
