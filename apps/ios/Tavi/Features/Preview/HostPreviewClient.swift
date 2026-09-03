import Foundation

// The phone's side of the host's dev-server preview routes (#58). One
// client per paired computer, handed out by its AgentDirectory so the
// credential never leaves that owner. The credential is used for these
// calls only; the web view gets a *ticket* the host minted, never the
// credential itself.
struct HostPreviewClient: Sendable {
    private let client: HostClient

    init(endpoint: HostEndpoint, credential: String) {
        client = HostClient(endpoint: endpoint, credential: credential)
    }

    var endpoint: HostEndpoint { client.endpoint }

    static let tooOld = "This computer's Tavi host is too old to show dev servers. Update it with `npx tavi-host update`."

    private static let sentences = HostClient.Sentences(answer: "a preview answer", tooOld: tooOld)

    enum Outcome<Value: Sendable>: Sendable {
        case value(Value)
        // The host answered with a reason; the words are the host's and can
        // be shown as-is.
        case refused(status: Int, PreviewRefusal)
        // No usable answer: network, or a shape this client cannot read.
        case failure(String)
    }

    // The computer's name as the web view will address it, and the door's
    // address: `https://<name>.ts.net:<doorPort>/`. Same host as the API,
    // another port — so the ticket cookie is scoped to this computer only.
    var hostName: String { endpoint.baseURL.host ?? "" }

    func doorURL(port doorPort: Int) -> URL? {
        guard var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.port = doorPort
        components.path = "/"
        components.query = nil
        return components.url
    }

    func door() async -> Outcome<PreviewDoorInfo> {
        await send("GET", "/api/preview/door", query: [:], body: nil)
    }

    func candidates(cwd: String) async -> Outcome<PreviewCandidates> {
        await send("GET", "/api/preview/candidates", query: ["cwd": cwd], body: nil)
    }

    func open(cwd: String, port: Int) async -> Outcome<OpenedPreview> {
        await send("POST", "/api/preview", query: [:], body: ["cwd": cwd, "port": port])
    }

    func keepAlive(id: String) async -> Outcome<PreviewHeartbeat> {
        await send("POST", "/api/preview/\(id)/keepalive", query: [:], body: nil)
    }

    // Fire-and-forget on dismiss; the host would also let it lapse.
    func close(id: String) async {
        guard let request = client.request("DELETE", "/api/preview/\(id)") else { return }
        _ = await client.send(request)
    }

    func stop(cwd: String, port: Int) async -> Outcome<PreviewStopped> {
        await send("POST", "/api/preview/stop", query: [:], body: ["cwd": cwd, "port": port])
    }

    private func send<Value: Decodable & Sendable>(_ method: String, _ path: String, query: [String: String], body: [String: Any]?) async -> Outcome<Value> {
        Self.outcome(await client.fetch(method, path, query: query, body: body, saying: Self.sentences))
    }

    // The refusal carries the door's state beyond the sentence, so the
    // sheet can tell a missing door from a port it may not reach.
    private static func outcome<Value: Sendable>(_ reply: HostClient.Reply<Value>) -> Outcome<Value> {
        switch reply {
        case let .value(value):
            return .value(value)
        case let .refused(status, sentence, body):
            guard let refusal = try? JSONDecoder().decode(PreviewRefusal.self, from: body) else { return .failure(sentence) }
            return .refused(status: status, refusal)
        case let .failure(reason):
            return .failure(reason)
        }
    }
}
