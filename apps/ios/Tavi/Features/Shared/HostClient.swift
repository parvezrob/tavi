import Foundation

// Every HTTP call the phone makes to a paired computer is built and read
// here (#92): the bearer header, the query and JSON body, the one
// connection pool, and the host's answer turned into a value, the host's
// own sentence, or a reason the answer could not be used. The per-computer
// clients — files, preview, source control — are route lists over this.
struct HostClient: Sendable {
    let endpoint: HostEndpoint
    private let credential: String

    init(endpoint: HostEndpoint, credential: String) {
        self.endpoint = endpoint
        self.credential = credential
    }

    // The two sentences only the feature itself can write: what it calls
    // its own answers, and what to say when this computer's host predates
    // the route.
    struct Sentences: Sendable {
        // Reads as "This host sent <answer> Tavi does not understand."
        let answer: String
        let tooOld: String
        var genericNotFound: GenericNotFound = .meansOldHost
    }

    // What the host's own `Not found.` means on this feature's routes.
    enum GenericNotFound: Sendable {
        case meansOldHost
        case isARefusal
    }

    // What the host answered, before a feature gives it its own words.
    enum Reply<Value: Sendable>: Sendable {
        case value(Value)
        // The host answered with a reason; `body` carries the fields a
        // feature reads beyond the sentence.
        case refused(status: Int, sentence: String, body: Data)
        // No usable answer: network, or a shape this client cannot read.
        case failure(String)
    }

    // The bytes as the host sent them, with its content type.
    enum Answer: Sendable {
        case answered(status: Int, body: Data, mime: String)
        case failure(String)
    }

    func fetch<Value: Decodable & Sendable>(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: [String: Any]? = nil,
        timeout: TimeInterval? = nil,
        saying sentences: Sentences
    ) async -> Reply<Value> {
        guard let request = request(method, path, query: query, body: body, timeout: timeout) else {
            return .failure("The host address is invalid.")
        }
        switch await send(request) {
        case let .failure(reason):
            return .failure(reason)
        case let .answered(status, body, _):
            return Self.reply(status: status, body: body, saying: sentences)
        }
    }

    static func reply<Value: Decodable & Sendable>(status: Int, body: Data, saying sentences: Sentences) -> Reply<Value> {
        guard (200..<300).contains(status) else { return refusal(status: status, body: body, saying: sentences) }
        do {
            return .value(try JSONDecoder().decode(Value.self, from: body))
        } catch {
            return .failure("This host sent \(sentences.answer) Tavi does not understand. Update the Tavi host and the app to matching versions.")
        }
    }

    func request(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) -> URLRequest? {
        guard var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    func send(_ request: URLRequest) async -> Answer {
        do {
            let (body, response) = try await HostSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure("The host did not answer.") }
            return .answered(
                status: http.statusCode,
                body: body,
                mime: http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            )
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // A status the host did not answer 2xx with. A route the host does not
    // have answers `404 {"error":"Not found."}` — that is an old host, not a
    // refusal, and the sentence says what to do about it (#81 review: the
    // refusal decode used to run first, so this sentence never showed).
    static func refusal<Value: Sendable>(status: Int, body: Data, saying sentences: Sentences) -> Reply<Value> {
        let sentence = (try? JSONDecoder().decode(HostSentence.self, from: body))?.error
        if status == 404, sentence == nil || (sentence == "Not found." && sentences.genericNotFound == .meansOldHost) {
            return .failure(sentences.tooOld)
        }
        if let sentence { return .refused(status: status, sentence: sentence, body: body) }
        return .failure("The host could not answer (HTTP \(status)).")
    }

    private struct HostSentence: Decodable {
        let error: String
    }
}
