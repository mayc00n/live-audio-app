import XCTest

final class PairingTests: XCTestCase {
    func testExistingExtensionQR() throws {
        let pairing = try Pairing("https://192.168.18.69:8443/iphone?token=test-pairing-token")
        XCTAssertEqual(pairing.baseURL.absoluteString, "https://192.168.18.69:8443")
        XCTAssertEqual(pairing.token, "test-pairing-token")
        XCTAssertEqual(pairing.endpoint("api/iphone/poll").path, "/api/iphone/poll")
    }
    func testRejectsUnpairedOrPublicAddresses() {
        for text in ["http://192.168.18.69:8765/iphone?token=x", "https://vdo.ninja/?view=x",
                     "https://8.8.8.8/iphone?token=x", "https://192.168.18.69/iphone",
                     "https://192.168.18.69/setup?token=x", "https://user:password@192.168.18.69/iphone?token=x"] {
            XCTAssertThrowsError(try Pairing(text), text)
        }
    }
    func testPrivateAddressRanges() {
        for host in ["10.1.2.3", "172.16.1.1", "172.31.255.255", "192.168.1.100", "computador.local"] {
            XCTAssertNoThrow(try Pairing("https://\(host)/iphone?token=x"))
        }
        for host in ["172.15.1.1", "172.32.1.1", "192.168.999.1", "192.169.1.1"] {
            XCTAssertThrowsError(try Pairing("https://\(host)/iphone?token=x"))
        }
    }
    func testAllExistingHostCommandsDecode() throws {
        let fixture = #"{"ok":true,"seq":7,"messages":[{"seq":1,"type":"SDP_ANSWER","payload":{"sdp":{"type":"answer","sdp":"v=0"}}},{"seq":2,"type":"ICE_CANDIDATE","payload":{"candidate":{"candidate":"candidate:sample","sdpMid":"0","sdpMLineIndex":0}}},{"seq":3,"type":"SET_AUDIO_ENABLED","payload":{"audioEnabled":false}},{"seq":4,"type":"SWITCH_FACING","payload":{"facingMode":"user"}},{"seq":5,"type":"SET_RESOLUTION","payload":{"resolutionPreset":"1280x720@30"}},{"seq":6,"type":"REQUEST_OFFER","payload":{}},{"seq":7,"type":"DISCONNECT","payload":{}}]}"#
        let decoded = try JSONDecoder().decode(PollResult.self, from: Data(fixture.utf8))
        XCTAssertEqual(decoded.messages.count, 7)
        XCTAssertEqual(decoded.messages[1].payload.candidate?.sdpMLineIndex, 0)
        XCTAssertEqual(decoded.messages[2].payload.audioEnabled, false)
        XCTAssertEqual(decoded.messages[6].type, "DISCONNECT")
    }
}
