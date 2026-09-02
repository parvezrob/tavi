import Foundation

// The phone's side of the host's dev-server preview routes (#58). One
// client per paired computer, handed out by its AgentDirectory so the
// credential never leaves that owner. The credential is used for these
// calls only; the web view gets a *ticket* the host minted, never the
// credential itself.
struct HostPreviewClient: Sendable {
    let endpoint: HostEndpoint
    private let credential: String

    init(endpoint: HostEndpoint, credential: String) {
        self.endpoint = endpoint
        self.credential = credential
    }

    // Same no-disk-trace policy as the directory's requests (#36).
    // One pool for the whole app (#86); this client's budget rides on each request.
    private static var session: URLSession { HostSession.shared }

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
        guard let request = request("DELETE", "/api/preview/\(id)", query: [:], body: nil) else { return }
        _ = try? await Self.session.data(for: request)
    }

    func stop(cwd: String, port: Int) async -> Outcome<PreviewStopped> {
        await send("POST", "/api/preview/stop", query: [:], body: ["cwd": cwd, "port": port])
    }

    private func send<Value: Decodable & Sendable>(_ method: String, _ path: String, query: [String: String], body: [String: Any]?) async -> Outcome<Value> {
        guard let request = request(method, path, query: query, body: body) else { return .failure("The host address is invalid.") }
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure("The host did not answer.") }
            guard (200 ..< 300).contains(http.statusCode) else { return Self.refusal(status: http.statusCode, data: data) }
            do {
                return .value(try JSONDecoder().decode(Value.self, from: data))
            } catch {
                return .failure("This host sent a preview answer Tavi does not understand. Update the Tavi host and the app to matching versions.")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func refusal<Value>(status: Int, data: Data) -> Outcome<Value> {
        if let refusal = try? JSONDecoder().decode(PreviewRefusal.self, from: data) {
            // An older host answers 404 with its generic "Not found." — that
            // is not a preview that ended, it is a host without the feature.
            if status == 404, refusal.error == "Not found." {
                return .failure(Self.tooOld)
            }
            return .refused(status: status, refusal)
        }
        if status == 404 { return .failure(Self.tooOld) }
        return .failure("The host could not answer (HTTP \(status)).")
    }

    static let tooOld = "This computer's Tavi host is too old to show dev servers. Update it with `npx tavi-host update`."

    private func request(_ method: String, _ path: String, query: [String: String], body: [String: Any]?) -> URLRequest? {
        guard var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
}
