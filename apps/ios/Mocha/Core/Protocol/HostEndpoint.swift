import Foundation

struct HostEndpoint: Equatable, Hashable, Sendable {
    let baseURL: URL

    init(baseURL: URL) throws {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw HostEndpointError.invalidURL
        }
        guard components.scheme?.lowercased() == "https" else {
            throw HostEndpointError.secureTransportRequired
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw HostEndpointError.missingHost
        }
        guard host.hasSuffix(".ts.net"), host != "ts.net" else {
            throw HostEndpointError.tailscaleServeRequired
        }
        guard components.user == nil, components.password == nil else {
            throw HostEndpointError.embeddedCredentialsNotAllowed
        }
        guard components.path.isEmpty || components.path == "/" else {
            throw HostEndpointError.basePathNotAllowed
        }
        guard components.query == nil, components.fragment == nil else {
            throw HostEndpointError.queryOrFragmentNotAllowed
        }

        self.baseURL = baseURL
    }

    // The only terminal route: a herdr agent pane (#53). Pane ids come from
    // the host's own agent list, so the path needs no validation of its
    // own beyond the percent-encoding URLComponents applies.
    func agentTerminalURL(forPane paneID: String) throws -> URL {
        try websocketURL(path: "/api/agents/\(paneID)/terminal")
    }

    func eventsURL() throws -> URL {
        try websocketURL(path: "/api/events")
    }

    private func websocketURL(path: String) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw HostEndpointError.invalidURL
        }
        components.scheme = "wss"
        components.path = path
        guard let url = components.url else {
            throw HostEndpointError.invalidURL
        }
        return url
    }
}

enum HostEndpointError: Error, Equatable, LocalizedError {
    case basePathNotAllowed
    case embeddedCredentialsNotAllowed
    case invalidURL
    case missingHost
    case queryOrFragmentNotAllowed
    case secureTransportRequired
    case tailscaleServeRequired

    var errorDescription: String? {
        switch self {
        case .basePathNotAllowed:
            "Enter only the host origin, without an extra path."
        case .embeddedCredentialsNotAllowed:
            "Credentials must not be embedded in the host URL."
        case .invalidURL:
            "Enter a valid host URL."
        case .missingHost:
            "The host URL is missing a hostname."
        case .queryOrFragmentNotAllowed:
            "The host URL must not contain a query or fragment."
        case .secureTransportRequired:
            "The host must use HTTPS through Tailscale Serve."
        case .tailscaleServeRequired:
            "Enter a Tailscale Serve hostname ending in .ts.net."
        }
    }
}
