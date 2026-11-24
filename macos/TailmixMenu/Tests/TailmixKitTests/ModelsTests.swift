import Foundation
import XCTest
@testable import TailmixKit

final class ModelsTests: XCTestCase {
    func testDecodesStatus() throws {
        let status = try JSONDecoder().decode(Status.self, from: Data(Fixtures.status.utf8))
        XCTAssertEqual(status.state, "up")
        XCTAssertEqual(status.profiles.map(\.name), ["home", "work", "lab"])
        XCTAssertEqual(status.profiles[0].peerCount, 3)
        XCTAssertEqual(status.profiles[0].selfDNSName, "mac.home.ts.net.")
        XCTAssertFalse(status.profiles[1].enabled)
        XCTAssertEqual(status.profiles[2].authURL, "https://login.example/a")
        XCTAssertEqual(status.profiles[2].lastError, "boom")
    }

    func testDecodesExitNodes() throws {
        let nodes = try JSONDecoder().decode(ExitNodes.self, from: Data(Fixtures.exitNodes.utf8))
        XCTAssertEqual(nodes.selected?.nodeID, "nGW")
        XCTAssertEqual(nodes.selected?.state, "installed")
        XCTAssertEqual(nodes.available.count, 2)
        XCTAssertEqual(nodes.available[1].location?.city, "Berlin")
        XCTAssertEqual(nodes.available[1].location?.priority, 50)
        XCTAssertNil(nodes.available[0].location)
    }

    func testDecodesEmptyExitNodes() throws {
        let nodes = try JSONDecoder().decode(ExitNodes.self, from: Data("{}".utf8))
        XCTAssertNil(nodes.selected)
        XCTAssertEqual(nodes.available, [])
    }

    func testDecodesOperatorAndError() throws {
        XCTAssertEqual(try JSONDecoder().decode(Operator.self, from: Data(Fixtures.operatorInfo.utf8)),
                       Operator(uid: "501", username: "alice"))
        XCTAssertEqual(try JSONDecoder().decode(Operator.self, from: Data("{}".utf8)), Operator())
        let error = try JSONDecoder().decode(APIError.self, from: Data(Fixtures.permissionDenied.utf8))
        XCTAssertTrue(error.isPermissionDenied)
    }
}
