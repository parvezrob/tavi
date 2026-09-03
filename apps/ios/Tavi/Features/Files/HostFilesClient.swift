import Foundation

// The phone's side of the host's read-only file routes (#25, #57, #61). One
// client per paired computer, handed out by its AgentDirectory so the
// credential never leaves that owner. Every call is a GET; there is no
// write here to misuse.
struct HostFilesClient: Sendable {
    private let client: HostClient

    init(
        endpoint: HostEndpoint,
        credential: String,
        transport: @escaping HostClient.Transport = { try await HostSession.shared.data(for: $0) }
    ) {
        client = HostClient(endpoint: endpoint, credential: credential, transport: transport)
    }

    private static let tooOld = "This computer's Tavi host is too old to show files. Update it with `npx tavi-host update`."

    // A file route's own 404 is "No such file.", so the host's sentence
    // stands as the refusal; a 404 with no sentence at all is an older host
    // that has none of these routes, and says so rather than "404".
    private static func sentences(answer: String) -> HostClient.Sentences {
        HostClient.Sentences(answer: answer, tooOld: tooOld, genericNotFound: .isARefusal)
    }

    enum Outcome<Value: Sendable>: Sendable {
        case value(Value)
        // The host answered with a reason (a refusal, a missing file, not a
        // repository); the words are the host's and can be shown as-is.
        case refused(status: Int, FileRefusal)
        // No usable answer: network, or a shape this client cannot read.
        case failure(String)
    }

    func changes(cwd: String) async -> Outcome<ChangesResponse> {
        await get("/api/changes", query: ["cwd": cwd])
    }

    func diff(cwd: String, path: String) async -> Outcome<FileDiff> {
        await get("/api/changes/file", query: ["cwd": cwd, "path": path])
    }

    func stat(cwd: String, path: String) async -> Outcome<FileStatInfo> {
        await get("/api/files/stat", query: ["cwd": cwd, "path": path])
    }

    func list(cwd: String, path: String) async -> Outcome<DirectoryListing> {
        await get("/api/files", query: ["cwd": cwd, "path": path])
    }

    func content(cwd: String, path: String) async -> Outcome<FileContent> {
        await get("/api/files/content", query: ["cwd": cwd, "path": path])
    }

    // Bytes of an image or PDF, with the host's content type.
    func raw(cwd: String, path: String) async -> Outcome<(data: Data, mime: String)> {
        guard let request = client.request("GET", "/api/files/raw", query: ["cwd": cwd, "path": path]) else {
            return .failure("The host address is invalid.")
        }
        switch await client.send(request) {
        case let .failure(reason):
            return .failure(reason)
        case let .answered(status, body, mime):
            guard status == 200 else {
                return Self.outcome(HostClient.refusal(status: status, body: body, saying: Self.sentences(answer: "a file answer")))
            }
            return .value((body, mime))
        }
    }

    // An image attached from the composer (#88): the body is the image,
    // the answer is where it landed on the computer.
    func upload(cwd: String, data: Data, mime: String) async -> Outcome<UploadReceipt> {
        guard var request = client.request("POST", "/api/files/upload", query: ["cwd": cwd], timeout: 90) else {
            return .failure("The host address is invalid.")
        }
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        switch await client.send(request) {
        case let .failure(reason):
            return .failure(reason)
        case let .answered(status, body, _):
            return Self.outcome(HostClient.reply(status: status, body: body, saying: Self.sentences(answer: "an upload answer")))
        }
    }

    private func get<Value: Decodable & Sendable>(_ path: String, query: [String: String]) async -> Outcome<Value> {
        Self.outcome(await client.fetch("GET", path, query: query, saying: Self.sentences(answer: "a file answer")))
    }

    // The refusal carries which kind of file and how big, not only the
    // sentence, so the sheet can say "binary, 2.3 MB".
    private static func outcome<Value: Sendable>(_ reply: HostClient.Reply<Value>) -> Outcome<Value> {
        switch reply {
        case let .value(value):
            return .value(value)
        case let .refused(status, sentence, body):
            guard let refusal = try? JSONDecoder().decode(FileRefusal.self, from: body) else { return .failure(sentence) }
            return .refused(status: status, refusal)
        case let .failure(reason):
            return .failure(reason)
        }
    }
}
