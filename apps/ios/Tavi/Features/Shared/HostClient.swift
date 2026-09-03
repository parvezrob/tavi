import Foundation

// Every HTTP call the phone makes to a paired computer is built and read
// here (#92): the bearer header, the query and JSON body, the one
// connection pool, and the host's answer turned into a value, the host's
// own sentence, or a reason the answer could not be used. The per-computer
// clients — files, preview, source control — are route lists over this.
struct HostClient: Sendable {
    // The one call that reaches the network: the shared pool in the app, a
    // stub in a unit test, so no test opens a socket (#99).
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let endpoint: HostEndpoint
    private let credential: String
    private let transport: Transport

    init(
        endpoint: HostEndpoint,
        credential: String,
        transport: @escaping Transport = { try await HostSession.shared.data(for: $0) }
    ) {
        self.endpoint = endpoint
        self.credential = credential
        self.transport = transport
    }

    // The sentences only the feature itself can write: what it calls its
    // own answers, what to say when this computer's host predates the
    // route, and what it calls a refusal the host gave no words for.
    struct Sentences: Sendable {
        // Reads as "This host sent <answer> Tavi does not understand."
        let answer: String
        let tooOld: String
        var genericNotFound: GenericNotFound = .meansOldHost
        // Reads as "<cannotAnswer> (HTTP 500)."; nil keeps the general wording.
        var cannotAnswer: String? = nil
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

    // What a feature's routes answer with, once it has read the reply. The
    // refusal shape is the feature's own — a file's kind and size, a
    // preview door's state — so it is the parameter (#104).
    // HostSourceControlClient keeps its own `Outcome` with a String: it
    // reads no body beyond the sentence, so it has no shape to name here.
    enum Outcome<Value: Sendable, Refusal: Decodable & Sendable>: Sendable {
        case value(Value)
        // The host answered with a reason; the words are the host's and can
        // be shown as-is, and `Refusal` carries the fields beside them.
        case refused(status: Int, Refusal)
        // No usable answer: network, or a shape this client cannot read.
        case failure(String)
    }

    // A refusal whose body does not carry the feature's own shape keeps the
    // host's sentence, which is always there, and nothing more.
    static func outcome<Value: Sendable, Refusal: Decodable & Sendable>(_ reply: Reply<Value>) -> Outcome<Value, Refusal> {
        switch reply {
        case let .value(value):
            return .value(value)
        case let .refused(status, sentence, body):
            guard let refusal = try? JSONDecoder().decode(Refusal.self, from: body) else { return .failure(sentence) }
            return .refused(status: status, refusal)
        case let .failure(reason):
            return .failure(reason)
        }
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
        switch await send(method, path, query: query, body: body, timeout: timeout) {
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
            // A shape this client cannot read is a version mismatch, not a
            // network problem — say which, since retrying never helps.
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
        var request = request(url, timeout: timeout)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    // A request to an address this client did not build — the events
    // socket's own wss URL, which HostEndpoint makes — so the bearer is
    // still written in exactly one place (#96).
    func request(_ url: URL, timeout: TimeInterval? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        if let timeout { request.timeoutInterval = timeout }
        // Pairing has no credential yet (#45); every other call carries one.
        if !credential.isEmpty {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // The bytes as the host sent them, for a route that reads the status
    // itself. An address that cannot be built fails the way `fetch` fails.
    func send(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) async -> Answer {
        guard let request = request(method, path, query: query, body: body, timeout: timeout) else {
            return .failure("The host address is invalid.")
        }
        return await send(request)
    }

    func send(_ request: URLRequest) async -> Answer {
        do {
            let (body, response) = try await transport(request)
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
        guard let sentence = hostSentence(in: body),
              !(status == 404 && sentence == "Not found." && sentences.genericNotFound == .meansOldHost) else {
            return .failure(refusalMessage(status: status, body: body, saying: sentences))
        }
        return .refused(status: status, sentence: sentence, body: body)
    }

    // The same reading for a route whose answer is a message rather than a
    // value (#96): the host's own sentence, the too-old sentence, or this
    // feature's wording for a status that carried no sentence at all.
    static func refusalMessage(status: Int, body: Data, saying sentences: Sentences) -> String {
        let sentence = hostSentence(in: body)
        if status == 404, sentence == nil || (sentence == "Not found." && sentences.genericNotFound == .meansOldHost) {
            return sentences.tooOld
        }
        if let sentence { return sentence }
        if let cannotAnswer = sentences.cannotAnswer { return "\(cannotAnswer) (HTTP \(status))." }
        return "The host could not answer (HTTP \(status))."
    }

    private static func hostSentence(in body: Data) -> String? {
        (try? JSONDecoder().decode(HostSentence.self, from: body))?.error
    }

    private struct HostSentence: Decodable {
        let error: String
    }
}
