import Foundation

// What the QR on the Mac carries (#45): `mocha://pair?u=<https url>&s=<secret>
// &f=<fingerprint>&n=<host name>`. Mirrors the host's encodePairingPayload.
struct PairingPayload: Equatable {
    let endpoint: HostEndpoint
    let secret: String
    let fingerprint: String
    let hostName: String

    enum DecodeError: Error, Equatable, LocalizedError {
        case notAPairingCode
        case incomplete
        case badHost(String)

        var errorDescription: String? {
            switch self {
            case .notAPairingCode: "That is not a Mocha pairing code."
            case .incomplete: "This pairing code is missing part of the host details."
            case let .badHost(reason): reason
            }
        }
    }

    static func decode(_ text: String) throws -> PairingPayload {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "mocha", url.host?.lowercased() == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DecodeError.notAPairingCode
        }
        let items = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value?.trimmingCharacters(in: .whitespaces) ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        guard let rawURL = items["u"], !rawURL.isEmpty,
              let secret = items["s"], !secret.isEmpty,
              let fingerprint = items["f"], !fingerprint.isEmpty else {
            throw DecodeError.incomplete
        }
        // The same rules as every other host address: HTTPS over Tailscale
        // Serve, nothing else — a pairing code cannot relax them.
        guard let hostURL = URL(string: rawURL) else { throw DecodeError.badHost("The host address is not a URL.") }
        let endpoint: HostEndpoint
        do {
            endpoint = try HostEndpoint(baseURL: hostURL)
        } catch let error as HostEndpointError {
            throw DecodeError.badHost(error.errorDescription ?? "The host address is not allowed.")
        }
        return PairingPayload(
            endpoint: endpoint,
            secret: secret,
            fingerprint: fingerprint,
            hostName: items["n"].flatMap { $0.isEmpty ? nil : $0 } ?? (hostURL.host ?? "your Mac")
        )
    }
}
