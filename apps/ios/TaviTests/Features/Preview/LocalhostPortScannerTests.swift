import Foundation
import Testing
@testable import Tavi

struct LocalhostPortScannerTests {
    @Test
    func findsLoopbackPortsNewestFirstWithoutDuplicates() {
        let text = """
          VITE v6.0.1  ready in 312 ms
          ➜  Local:   http://localhost:5173/
          ➜  Network: http://0.0.0.0:5173/
        API listening on 127.0.0.1:3000
        websocket at ws://[::1]:8080 (ignored scheme, port kept)
        again http://localhost:5173/about
        """
        #expect(LocalhostPortScanner.scan(text) == [5173, 8080, 3000])
    }

    @Test
    func ignoresOtherHostsVersionsAndImpossiblePorts() {
        let text = "see https://tavi.dev:8443/x and 10.0.0.5:22; version 1.2.3:4; localhost:70000 is not a port; localhost:0 neither"
        #expect(LocalhostPortScanner.scan(text) == [])
        #expect(LocalhostPortScanner.scan("") == [])
    }

    @Test
    func acceptsBarePortMentionsOfLoopbackNames() {
        #expect(LocalhostPortScanner.scan("Server running at localhost:8000.") == [8000])
        #expect(LocalhostPortScanner.scan("bound to 127.0.0.1:5000, then 127.0.0.1:5001") == [5001, 5000])
    }
}
