import Foundation

// The phone's side of the host's read-only file routes (#25, #57, #61). One
// client per paired computer, handed out by its AgentDirectory so the
// credential never leaves that owner. Every call is a GET; there is no
// write here to misuse.
struct HostFilesClient: Sendable {
    let endpoint: HostEndpoint
    private let credential: String

    init(endpoint: HostEndpoint, credential: String) {
        self.endpoint = endpoint
        self.credential = credential
    }

    // Same no-disk-trace policy as the directory's requests (#36).
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

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
        guard let request = request("/api/files/raw", query: ["cwd": cwd, "path": path]) else {
            return .failure("The host address is invalid.")
        }
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure("The host did not answer.") }
            if http.statusCode == 200 {
                return .value((data, http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"))
            }
            return Self.refusal(status: http.statusCode, data: data)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func get<Value: Decodable & Sendable>(_ path: String, query: [String: String]) async -> Outcome<Value> {
        guard let request = request(path, query: query) else { return .failure("The host address is invalid.") }
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure("The host did not answer.") }
            guard http.statusCode == 200 else { return Self.refusal(status: http.statusCode, data: data) }
            do {
                return .value(try JSONDecoder().decode(Value.self, from: data))
            } catch {
                return .failure("This host sent a file answer Tavi does not understand. Update the Tavi host and the app to matching versions.")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func refusal<Value>(status: Int, data: Data) -> Outcome<Value> {
        if let refusal = try? JSONDecoder().decode(FileRefusal.self, from: data) {
            return .refused(status: status, refusal)
        }
        // An older host has none of these routes: say so, not "404".
        if status == 404 {
            return .failure("This computer's Tavi host is too old to show files. Update it with `npx tavi-host update`.")
        }
        return .failure("The host could not answer (HTTP \(status)).")
    }

    private func request(_ path: String, query: [String: String]) -> URLRequest? {
        guard var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = path
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        return request
    }
}
