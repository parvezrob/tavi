import Foundation
import Testing
@testable import Mocha

struct HostEndpointTests {
    @Test
    func buildsSecureTerminalURL() throws {
        let endpoint = try HostEndpoint(baseURL: #require(URL(string: "https://studio.tailnet.ts.net")))
        let session = try SessionIdentifier(rawValue: "mocha-api-work-a1b2c3")

        let terminalURL = try endpoint.terminalURL(for: session)

        #expect(terminalURL.absoluteString == "wss://studio.tailnet.ts.net/api/sessions/mocha-api-work-a1b2c3/terminal")
    }

    @Test(arguments: [
        "http://studio.tailnet.ts.net",
        "https://user:secret@studio.tailnet.ts.net",
        "https://studio.tailnet.ts.net/mocha",
        "https://studio.tailnet.ts.net?token=secret",
        "https://studio.tailnet.ts.net#terminal",
        "https://public-relay.example.com",
    ])
    func rejectsUnsafeOrAmbiguousBaseURLs(_ rawURL: String) throws {
        let url = try #require(URL(string: rawURL))

        #expect(throws: HostEndpointError.self) {
            try HostEndpoint(baseURL: url)
        }
    }

    @Test(arguments: ["", "contains space", "slash/not-allowed", String(repeating: "a", count: 129)])
    func rejectsInvalidSessionIdentifiers(_ value: String) {
        #expect(throws: SessionIdentifierError.invalidValue) {
            try SessionIdentifier(rawValue: value)
        }
    }
}
