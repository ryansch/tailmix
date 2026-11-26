import Foundation
import Testing
@testable import TailmixKit

@Suite struct ModelsTests {
    @Test func testDecodesStatus() throws {
        let status = try JSONDecoder().decode(Status.self, from: Data(Fixtures.status.utf8))
        #expect(status.state == "up")
        #expect(status.profiles.map(\.name) == ["home", "work", "lab"])
        #expect(status.profiles[0].peerCount == 3)
        #expect(status.profiles[0].selfDNSName == "mac.home.ts.net.")
        #expect(!status.profiles[1].enabled)
        #expect(status.profiles[2].authURL == "https://login.example/a")
        #expect(status.profiles[2].lastError == "boom")
    }

    @Test func testDecodesExitNodes() throws {
        let nodes = try JSONDecoder().decode(ExitNodes.self, from: Data(Fixtures.exitNodes.utf8))
        #expect(nodes.selected?.nodeID == "nGW")
        #expect(nodes.selected?.state == "installed")
        #expect(nodes.available.count == 2)
        #expect(nodes.available[1].location?.city == "Berlin")
        #expect(nodes.available[1].location?.priority == 50)
        #expect(nodes.available[0].location == nil)
    }

    @Test func testDecodesEmptyExitNodes() throws {
        let nodes = try JSONDecoder().decode(ExitNodes.self, from: Data("{}".utf8))
        #expect(nodes.selected == nil)
        #expect(nodes.available == [])
    }

    @Test func testDecodesOperatorAndError() throws {
        #expect(try JSONDecoder().decode(Operator.self, from: Data(Fixtures.operatorInfo.utf8)) ==
                Operator(uid: "501", username: "alice"))
        #expect(try JSONDecoder().decode(Operator.self, from: Data("{}".utf8)) == Operator())
        let error = try JSONDecoder().decode(APIError.self, from: Data(Fixtures.permissionDenied.utf8))
        #expect(error.isPermissionDenied)
    }
}
