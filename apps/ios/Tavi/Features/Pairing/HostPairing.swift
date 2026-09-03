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

    // Both calls are HostClient routes (#96), so the pool, the bearer and
    // the "too old" reading are the ones every other request gets.
    private static let sentences = HostClient.Sentences(
        answer: "a pairing reply",
        tooOld: "This computer's Tavi host is too old to pair with this version of Tavi. Update it with `npx tavi-host update`.",
        cannotAnswer: "The host refused the pairing code"
    )

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
    static func redeem(
        _ payload: PairingPayload,
        transport: @escaping HostClient.Transport = { try await HostSession.shared.data(for: $0) }
    ) async throws -> Grant {
        // The exchange that mints the credential is the one call that has none.
        let client = HostClient(endpoint: payload.endpoint, credential: "", transport: transport)
        let reply: HostClient.Reply<GrantResponse> = await client.fetch(
            "POST",
            "/api/pair",
            body: [
                "secret": payload.secret,
                "deviceName": await MainActor.run { UIDevice.current.name },
            ],
            timeout: 15,
            saying: sentences
        )
        switch reply {
        case let .value(grant):
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
        case let .refused(_, sentence, _):
            throw Failure.codeRejected(sentence)
        case let .failure(reason):
            throw Failure.unreachable(reason)
        }
    }

    struct Checks: Equatable {
        // Round trip to an authenticated endpoint, in milliseconds.
        let latencyMilliseconds: Int
        let sessionsFound: Int
        let herdrAvailable: Bool
    }

    // Progressive proof that the credential works and the path is direct,
    // shown step by step on the done screen.
    static func verify(
        endpoint: HostEndpoint,
        credential: String,
        transport: @escaping HostClient.Transport = { try await HostSession.shared.data(for: $0) }
    ) async throws -> Checks {
        let client = HostClient(endpoint: endpoint, credential: credential, transport: transport)
        guard let request = client.request("GET", "/api/agents", timeout: 15) else {
            throw Failure.unreachable("The host address is invalid.")
        }
        let started = Date()
        switch await client.send(request) {
        case let .failure(reason):
            throw Failure.unreachable(reason)
        case let .answered(status, data, _):
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            guard status == 200 else {
                throw Failure.unreachable("The new credential was not accepted by the host.")
            }
            struct Agents: Decodable { let available: Bool; let agents: [AgentSummary] }
            let agents = (try? JSONDecoder().decode(Agents.self, from: data)) ?? Agents(available: false, agents: [])
            return Checks(latencyMilliseconds: latency, sessionsFound: agents.agents.count, herdrAvailable: agents.available)
        }
    }
}
