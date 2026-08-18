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
        guard components.host?.isEmpty == false else {
            throw HostEndpointError.missingHost
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

    func terminalURL(for session: SessionIdentifier) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw HostEndpointError.invalidURL
        }
        components.scheme = "wss"
        components.path = "/api/sessions/\(session.rawValue)/terminal"
        guard let url = components.url else {
            throw HostEndpointError.invalidURL
        }
        return url
    }
}

enum HostEndpointError: Error, Equatable {
    case basePathNotAllowed
    case embeddedCredentialsNotAllowed
    case invalidURL
    case missingHost
    case queryOrFragmentNotAllowed
    case secureTransportRequired
}

struct SessionIdentifier: Equatable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) throws {
        guard (1...128).contains(rawValue.count), rawValue.unicodeScalars.allSatisfy(Self.isAllowed) else {
            throw SessionIdentifierError.invalidValue
        }
        self.rawValue = rawValue
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            true
        case 45, 46, 58, 95:
            true
        default:
            false
        }
    }
}

enum SessionIdentifierError: Error, Equatable {
    case invalidValue
}
