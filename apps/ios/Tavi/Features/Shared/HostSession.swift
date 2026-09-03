import Foundation

// The one connection pool for every HTTP request the phone makes to a
// computer (#86, PRD §7.13). Six separate pools used to share nothing, so
// each feature paid its own TLS handshake and a reconnect on a bad link
// raced twenty half-open sockets at once. One session, at most two
// connections per host, keep-alive; per-request `timeoutInterval` carries
// each call's own budget. Same no-disk-trace policy as the terminal
// transport (#36): ephemeral storage, no cache, no silent parking on a
// dead path.
enum HostSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()
}
