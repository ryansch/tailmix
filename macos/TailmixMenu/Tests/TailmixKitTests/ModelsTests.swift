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

    @Test func testDecodesProfileWithoutLocationFromOldDaemon() throws {
        let status = try JSONDecoder().decode(Status.self, from: Data(Fixtures.status.utf8))
        #expect(!status.profiles[0].routesInEffect)
        #expect(status.profiles[0].location == nil)
        #expect(!status.profiles[0].acceptAllRoutes)
        #expect(!status.profiles[0].acceptAllDNSRoutes)

        let bare = try JSONDecoder().decode(Profile.self, from: Data(#"{"name":"x"}"#.utf8))
        #expect(!bare.routesInEffect)
        #expect(bare.location == nil)
        #expect(!bare.acceptAllRoutes)
        #expect(!bare.acceptAllDNSRoutes)
    }

    @Test func testDecodesKeyExpiry() throws {
        let status = try JSONDecoder().decode(Status.self, from: Data(Fixtures.keyStatus.utf8))
        let home = status.profiles[0]
        // Go encodes time.Time with fractional seconds when it has them.
        let homeExpiry = try #require(home.keyExpiry)
        #expect(abs(homeExpiry.timeIntervalSince1970 - 1_795_773_600.123) < 0.001)
        #expect(!home.keyExpired)
        let work = status.profiles[1]
        #expect(work.keyExpiry == Date(timeIntervalSince1970: 1_795_181_400))
        #expect(work.keyExpired)
    }

    @Test func testDecodesProfileWithoutKeyFields() throws {
        let status = try JSONDecoder().decode(Status.self, from: Data(Fixtures.status.utf8))
        #expect(status.profiles.allSatisfy { $0.keyExpiry == nil && !$0.keyExpired })
        let bare = try JSONDecoder().decode(Profile.self, from: Data(#"{"name":"x"}"#.utf8))
        #expect(bare.keyExpiry == nil)
        #expect(!bare.keyExpired)
    }

    @Test func testDecodesProfileLocation() throws {
        let status = try JSONDecoder().decode(Status.self, from: Data(Fixtures.locationStatus.utf8))
        let home = status.profiles[0]
        #expect(home.acceptAllRoutes)
        #expect(home.acceptAllDNSRoutes)
        #expect(!home.routesInEffect)
        #expect(home.location == ProfileLocation(
            supported: true, enabled: true, current: "home", override: "",
            homeNetworks: ["aa:bb:cc:dd:ee:ff"], networkAvailable: true, onHomeNetwork: true))

        let work = status.profiles[1]
        #expect(!work.acceptAllRoutes)
        #expect(work.acceptAllDNSRoutes)
        #expect(work.routesInEffect)
        #expect(work.location == ProfileLocation(
            supported: true, enabled: true, current: "unknown", override: "on",
            homeNetworks: [], networkAvailable: false, onHomeNetwork: false))

        #expect(status.profiles[2].routesInEffect)
        #expect(status.profiles[2].location == nil)

        #expect(try JSONDecoder().decode(ProfileLocation.self, from: Data("{}".utf8)) == ProfileLocation())
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
