import Foundation
import Testing
@testable import TailmixKit

@Suite struct HTTPResponseTests {
    @Test func testContentLength() throws {
        let response = try HTTPResponse.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Type: application/json\r\n\r\n{}trailing".utf8))
        #expect(response.status == 200)
        #expect(response.headers["content-type"] == "application/json")
        #expect(String(decoding: response.body, as: UTF8.self) == "{}")
    }

    @Test func testChunked() throws {
        let raw = "HTTP/1.1 403 Forbidden\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n5;ext=1\r\n:true\r\n1\r\n}\r\n0\r\n\r\n"
        let response = try HTTPResponse.parse(Data(raw.utf8))
        #expect(response.status == 403)
        #expect(String(decoding: response.body, as: UTF8.self) == "{\"a\":true}")
    }

    @Test func testCloseDelimited() throws {
        let response = try HTTPResponse.parse(Data("HTTP/1.0 200 OK\r\n\r\nhello".utf8))
        #expect(String(decoding: response.body, as: UTF8.self) == "hello")
    }

    @Test func testRejectsInvalidResponses() {
        #expect(throws: (any Error).self) { try HTTPResponse.parse(Data("HTTP/1.1 200 OK\r\n".utf8)) }
        #expect(throws: (any Error).self) { try HTTPResponse.parse(Data("SSH-2.0\r\n\r\n".utf8)) }
        #expect(throws: (any Error).self) { try HTTPResponse.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort".utf8)) }
        #expect(throws: (any Error).self) { try HTTPResponse.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n".utf8)) }
    }

    @Test func testProfilePathEscapesLikeGo() {
        #expect(ControlClient.profilePath("work") == "/v1/profiles/by-name/work")
        #expect(ControlClient.profilePath("my home/2") == "/v1/profiles/by-name/my%20home%2F2")
        #expect(ControlClient.profilePath("café") == "/v1/profiles/by-name/caf%C3%A9")
    }
}

@Suite struct ControlClientTests {
    @Test func testReadsSnapshotAndSendsMutations() throws {
        let server = try FakeDaemon { request in
            switch (request.method, request.path) {
            case ("GET", "/v1/status"): return (200, Fixtures.status)
            case ("GET", "/v1/exit-node"): return (200, Fixtures.exitNodes)
            case ("GET", "/v1/operator"): return (200, Fixtures.operatorInfo)
            case ("POST", "/v1/profiles/by-name/my%20work/enable"): return (200, #"{"name":"my work","enabled":true}"#)
            case ("PUT", "/v1/exit-node"): return (200, Fixtures.exitNodes)
            case ("DELETE", "/v1/exit-node"): return (403, Fixtures.permissionDenied)
            default: return (404, "404 page not found\n")
            }
        }
        defer { server.stop() }
        let client = ControlClient(socketDirectory: server.directory, timeout: 5)

        let snapshot = try client.snapshot()
        #expect(snapshot.status.profiles.count == 3)
        #expect(snapshot.exitNodes.available.count == 2)
        #expect(snapshot.operatorInfo == Operator(uid: "501", username: "alice"))

        let profile = try client.setProfileConnected("my work", true)
        #expect(profile.enabled)

        try client.setExitNode(profileName: "home", nodeID: "nDE")
        let put = server.requests.first { $0.method == "PUT" }
        #expect(put?.contentType == "application/json")
        let body = try JSONSerialization.jsonObject(with: put?.body ?? Data()) as? [String: String]
        #expect(body == ["profileName": "home", "peer": "nDE"])

        let error = try #require(throws: (any Error).self) { try client.clearExitNode() }
        #expect((error as? APIError)?.isPermissionDenied == true)
    }

    @Test func testOldDaemonWithoutOperator() throws {
        let server = try FakeDaemon { request in
            switch request.path {
            case "/v1/status": return (200, Fixtures.status)
            case "/v1/exit-node": return (200, "{}")
            default: return (404, "404 page not found\n")
            }
        }
        defer { server.stop() }
        let snapshot = try ControlClient(socketDirectory: server.directory, timeout: 5).snapshot()
        #expect(snapshot.operatorInfo == nil)
    }

    @Test func testMissingSocketIsTransportError() throws {
        let client = ControlClient(socketDirectory: "/nonexistent-tailmix-dir", timeout: 1)
        let error = try #require(throws: (any Error).self) { try client.status() }
        #expect(error is TransportError, "\(error)")
    }
}
