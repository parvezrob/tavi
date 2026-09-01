import Foundation
import UIKit

// The pairing exchange and the checks that follow it (#45). Nothing here
// stores anything: the caller decides what to keep once every step has
// passed, so a half-finished pairing leaves no credential behind.
enum HostPairing {
    struct Grant: Equatable {
        let credential: String
        let deviceId: String
        let deviceName: String
        let hostName: String
        let fingerprint: String
    }

    enum Failure: Error, Equatable, LocalizedError {
        case codeRejected(String)
        case fingerprintMismatch(shown: String, actual: String)
        case unreachable(String)

        var errorDescription: String? {
            switch self {
            case let .codeRejected(message): message
            case let .fingerprintMismatch(shown, actual):
                "The computer that answered is not the one on the code (it reported \(actual), the code said \(shown)). Nothing was saved."
            case let .unreachable(message): message
            }
        }
    }

    // Same no-disk-trace posture as every other request that carries a
    // credential (#36).
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    private struct GrantResponse: Decodable {
        struct Device: Decodable { let id: String; let name: String }
        struct Host: Decodable { let name: String; let fingerprint: String }
        let credential: String
        let device: Device
        let host: Host
    }

    // Redeems the single-use secret. The host answers with its fingerprint;
    // a mismatch with the one on the code means the phone reached a
    // different machine than the one it was shown, and the grant is dropped.
    static func redeem(_ payload: PairingPayload) async throws -> Grant {
        guard var components = URLComponents(url: payload.endpoint.baseURL, resolvingAgainstBaseURL: false) else {
            throw Failure.unreachable("The host address is invalid.")
        }
        components.path = "/api/pair"
        guard let url = components.url else { throw Failure.unreachable("The host address is invalid.") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "secret": payload.secret,
            "deviceName": await MainActor.run { UIDevice.current.name },
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw Failure.unreachable("The host did not answer.")
        }
        guard status == 201 else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw Failure.codeRejected(message ?? "The host refused the pairing code (HTTP \(status)).")
        }
        guard let grant = try? JSONDecoder().decode(GrantResponse.self, from: data) else {
            throw Failure.unreachable("This host sent a pairing reply Tavi does not understand. Update the Tavi host and the app to matching versions.")
        }
        guard grant.host.fingerprint == payload.fingerprint else {
            throw Failure.fingerprintMismatch(shown: payload.fingerprint, actual: grant.host.fingerprint)
        }
        return Grant(
            credential: grant.credential,
            deviceId: grant.device.id,
            deviceName: grant.device.name,
            hostName: grant.host.name,
            fingerprint: grant.host.fingerprint
        )
    }

    struct Checks: Equatable {
        // Round trip to an authenticated endpoint, in milliseconds.
        let latencyMilliseconds: Int
        let sessionsFound: Int
        let herdrAvailable: Bool
    }

    // Progressive proof that the credential works and the path is direct,
    // shown step by step on the done screen.
    static func verify(endpoint: HostEndpoint, credential: String) async throws -> Checks {
        guard var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false) else {
            throw Failure.unreachable("The host address is invalid.")
        }
        components.path = "/api/agents"
        guard let url = components.url else { throw Failure.unreachable("The host address is invalid.") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.unreachable("The new credential was not accepted by the host.")
        }
        struct Agents: Decodable { let available: Bool; let agents: [AgentSummary] }
        let agents = (try? JSONDecoder().decode(Agents.self, from: data)) ?? Agents(available: false, agents: [])
        return Checks(latencyMilliseconds: latency, sessionsFound: agents.agents.count, herdrAvailable: agents.available)
    }
}
