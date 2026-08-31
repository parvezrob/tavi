import Foundation
import Testing
@testable import Mocha

struct HostEndpointTests {
    @Test
    func buildsSecureAgentTerminalURL() throws {
        let endpoint = try HostEndpoint(baseURL: #require(URL(string: "https://studio.tailnet.ts.net")))

        let terminalURL = try endpoint.agentTerminalURL(forPane: "wB:p1")

        #expect(terminalURL.absoluteString == "wss://studio.tailnet.ts.net/api/agents/wB:p1/terminal")
    }

    @Test
    func buildsSecureEventsURL() throws {
        let endpoint = try HostEndpoint(baseURL: #require(URL(string: "https://studio.tailnet.ts.net")))

        #expect(try endpoint.eventsURL().absoluteString == "wss://studio.tailnet.ts.net/api/events")
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
}
