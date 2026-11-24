import Foundation
import XCTest
@testable import TailmixKit

final class MenuModelTests: XCTestCase {
    private func snapshot(
        state: String = "up",
        profiles: [Profile],
        exitNodes: ExitNodes = ExitNodes(),
        operatorInfo: Operator? = Operator(uid: "501", username: "alice")
    ) -> Snapshot {
        Snapshot(status: Status(state: state, profiles: profiles), exitNodes: exitNodes, operatorInfo: operatorInfo)
    }

    private let home = Profile(id: "p1", name: "home", enabled: true, runtimeState: "running", peerCount: 3)
    private let work = Profile(id: "p2", name: "work", enabled: false, runtimeState: "disabled")

    func testUnreachableDaemon() {
        let model = MenuModel.build(snapshot: nil, error: TransportError("refused"), currentUID: "501", remembered: nil)
        XCTAssertEqual(model.icon, .unavailable)
        XCTAssertFalse(model.isDaemonReachable)
        XCTAssertEqual(model.headline, "tailmix daemon is not running")
    }

    func testProfilesAndHeadline() {
        let lab = Profile(id: "p3", name: "lab", enabled: true, runtimeState: "needs-login", authURL: "https://login.example/a", lastError: "boom")
        let model = MenuModel.build(snapshot: snapshot(profiles: [home, work, lab]), error: nil, currentUID: "501", remembered: nil)
        XCTAssertEqual(model.headline, "1 of 3 profiles connected")
        XCTAssertEqual(model.icon, .connected)
        XCTAssertEqual(model.profiles.map(\.detail), ["Connected · 3 peers", "Disconnected", "Needs login"])
        XCTAssertEqual(model.profiles.map(\.isOn), [true, false, true])
        XCTAssertEqual(model.profiles[2].loginURL, URL(string: "https://login.example/a"))
        XCTAssertEqual(model.profiles[2].errorMessage, "boom")
        XCTAssertFalse(model.needsOperator)
        XCTAssertEqual(model.operatorName, "alice")
        XCTAssertNil(model.exitNode)
    }

    func testPausedDaemonDisablesActions() {
        let paused = Profile(id: "p1", name: "home", enabled: true, runtimeState: "down")
        let model = MenuModel.build(snapshot: snapshot(state: "down", profiles: [paused]), error: nil, currentUID: "501", remembered: nil)
        XCTAssertEqual(model.headline, "tailmix is paused")
        XCTAssertEqual(model.icon, .disconnected)
        XCTAssertEqual(model.profiles[0].detail, "Paused")
        XCTAssertFalse(model.profiles[0].isActionable)
    }

    func testOperatorPrompt() {
        let other = MenuModel.build(snapshot: snapshot(profiles: [home]), error: nil, currentUID: "502", remembered: nil)
        XCTAssertTrue(other.needsOperator)
        let unset = MenuModel.build(snapshot: snapshot(profiles: [home], operatorInfo: Operator()), error: nil, currentUID: "501", remembered: nil)
        XCTAssertTrue(unset.needsOperator)
        XCTAssertNil(unset.operatorName)
        let root = MenuModel.build(snapshot: snapshot(profiles: [home], operatorInfo: Operator()), error: nil, currentUID: "0", remembered: nil)
        XCTAssertFalse(root.needsOperator)
        let oldDaemon = MenuModel.build(snapshot: snapshot(profiles: [home], operatorInfo: nil), error: nil, currentUID: "501", remembered: nil)
        XCTAssertFalse(oldDaemon.needsOperator)
    }

    func testExitNodesGroupedByProfileAndCountry() {
        let workOn = Profile(id: "p2", name: "work", enabled: true, runtimeState: "running")
        let nodes = ExitNodes(
            selected: SelectedExitNode(profileID: "p2", profileName: "work", nodeID: "n3", dnsName: "relay.work.ts.net.", state: "installed"),
            available: [
                AvailableExitNode(profileID: "p1", profileName: "home", nodeID: "n1", dnsName: "gateway.home.ts.net."),
                AvailableExitNode(profileID: "p1", profileName: "home", nodeID: "n5", dnsName: "attic.home.ts.net.", online: false),
                AvailableExitNode(profileID: "p1", profileName: "home", nodeID: "m2", dnsName: "us-nyc-wg-002.mullvad.ts.net.",
                                  location: ExitNodeLocation(country: "USA", city: "New York", priority: 10)),
                AvailableExitNode(profileID: "p1", profileName: "home", nodeID: "m1", dnsName: "de-ber-wg-001.mullvad.ts.net.",
                                  location: ExitNodeLocation(country: "Germany", city: "Berlin", priority: 50)),
                AvailableExitNode(profileID: "p1", profileName: "home", nodeID: "m3", dnsName: "de-fra-wg-001.mullvad.ts.net.",
                                  location: ExitNodeLocation(country: "Germany", city: "Frankfurt")),
                AvailableExitNode(profileID: "p2", profileName: "work", nodeID: "n3", dnsName: "relay.work.ts.net."),
            ])
        let model = MenuModel.build(snapshot: snapshot(profiles: [home, workOn], exitNodes: nodes), error: nil, currentUID: "501", remembered: nil)
        XCTAssertEqual(model.icon, .exitNode)
        let section = try! XCTUnwrap(model.exitNode)
        XCTAssertTrue(section.isOn)
        XCTAssertTrue(section.isToggleEnabled)
        XCTAssertNil(section.toggleTarget)
        XCTAssertEqual(section.toggleTitle, "Exit Node: relay (work)")
        XCTAssertNil(section.note)

        XCTAssertEqual(section.groups.map(\.profileName), ["home", "work"])
        let homeGroup = section.groups[0]
        XCTAssertEqual(homeGroup.nodes.map(\.title), ["attic", "gateway"])
        XCTAssertEqual(homeGroup.nodes.map(\.isOnline), [false, true])
        XCTAssertEqual(homeGroup.countries.map(\.name), ["Germany", "USA"])
        XCTAssertEqual(homeGroup.countries[0].nodes.map(\.title), ["Berlin — de-ber-wg-001", "Frankfurt — de-fra-wg-001"])
        XCTAssertFalse(homeGroup.countries[0].containsSelection)
        XCTAssertEqual(section.groups[1].nodes.map(\.isSelected), [true])
        XCTAssertEqual(section.groups[1].nodes[0].ref, ExitNodeRef(profileName: "work", nodeID: "n3", label: "relay"))
    }

    func testSelectedExitNodeWaiting() {
        let nodes = ExitNodes(selected: SelectedExitNode(profileID: "p2", profileName: "work", nodeID: "n3", dnsName: "", state: "waiting", reason: "profile_unavailable"))
        let model = MenuModel.build(snapshot: snapshot(profiles: [home, work], exitNodes: nodes), error: nil, currentUID: "501", remembered: nil)
        XCTAssertEqual(model.icon, .connected)
        XCTAssertEqual(model.exitNode?.toggleTitle, "Exit Node: n3 (work)")
        XCTAssertEqual(model.exitNode?.note, "Waiting for work to connect")
        XCTAssertEqual(model.exitNode?.isOn, true)
    }

    func testRememberedExitNodeCanBeTurnedBackOn() {
        let remembered = ExitNodeRef(profileName: "home", nodeID: "n1", label: "gateway")
        let available = ExitNodes(available: [AvailableExitNode(profileID: "p1", profileName: "home", nodeID: "n1", dnsName: "gateway.home.ts.net.")])
        let on = MenuModel.build(snapshot: snapshot(profiles: [home], exitNodes: available), error: nil, currentUID: "501", remembered: remembered)
        XCTAssertEqual(on.exitNode?.isOn, false)
        XCTAssertEqual(on.exitNode?.toggleTarget, remembered)
        XCTAssertEqual(on.exitNode?.isToggleEnabled, true)
        XCTAssertEqual(on.exitNode?.toggleTitle, "Exit Node: gateway (home)")

        let gone = MenuModel.build(snapshot: snapshot(profiles: [home]), error: nil, currentUID: "501", remembered: remembered)
        XCTAssertEqual(gone.exitNode?.isToggleEnabled, false)
        XCTAssertEqual(gone.exitNode?.note, "Not available right now")
    }

    func testNoExitNodeChosenYet() {
        let available = ExitNodes(available: [AvailableExitNode(profileID: "p1", profileName: "home", nodeID: "n1", dnsName: "gateway.home.ts.net.")])
        let model = MenuModel.build(snapshot: snapshot(profiles: [home], exitNodes: available), error: nil, currentUID: "501", remembered: nil)
        XCTAssertEqual(model.exitNode?.toggleTitle, "Exit Node: None")
        XCTAssertEqual(model.exitNode?.isToggleEnabled, false)
    }

    func testShortName() {
        XCTAssertEqual(MenuModel.shortName("gateway.home.ts.net.", fallback: "x"), "gateway")
        XCTAssertEqual(MenuModel.shortName("", fallback: "nID"), "nID")
        XCTAssertEqual(MenuModel.shortName("single", fallback: "x"), "single")
    }
}
