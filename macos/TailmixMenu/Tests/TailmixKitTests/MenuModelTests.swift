import Foundation
import Testing
@testable import TailmixKit

@Suite struct MenuModelTests {
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

    @Test func testUnreachableDaemon() {
        let model = MenuModel.build(snapshot: nil, error: TransportError("refused"), currentUID: "501", remembered: nil)
        #expect(model.icon == .unavailable)
        #expect(!model.isDaemonReachable)
        #expect(model.headline == "tailmix daemon is not running")
    }

    @Test func testProfilesAndHeadline() {
        let lab = Profile(id: "p3", name: "lab", enabled: true, runtimeState: "needs-login", authURL: "https://login.example/a", lastError: "boom")
        let model = MenuModel.build(snapshot: snapshot(profiles: [home, work, lab]), error: nil, currentUID: "501", remembered: nil)
        #expect(model.headline == "1 of 3 profiles connected")
        #expect(model.icon == .connected)
        #expect(model.profiles.map(\.detail) == ["Connected · 3 peers", "Disconnected", "Needs login"])
        #expect(model.profiles.map(\.isOn) == [true, false, true])
        #expect(model.profiles[2].loginURL == URL(string: "https://login.example/a"))
        #expect(model.profiles[2].errorMessage == "boom")
        #expect(!model.needsOperator)
        #expect(model.operatorName == "alice")
        #expect(model.exitNode == nil)
    }

    @Test func testPausedDaemonDisablesActions() {
        let paused = Profile(id: "p1", name: "home", enabled: true, runtimeState: "down")
        let model = MenuModel.build(snapshot: snapshot(state: "down", profiles: [paused]), error: nil, currentUID: "501", remembered: nil)
        #expect(model.headline == "tailmix is paused")
        #expect(model.icon == .disconnected)
        #expect(model.profiles[0].detail == "Paused")
        #expect(!model.profiles[0].isActionable)
    }

    @Test func testOperatorPrompt() {
        let other = MenuModel.build(snapshot: snapshot(profiles: [home]), error: nil, currentUID: "502", remembered: nil)
        #expect(other.needsOperator)
        let unset = MenuModel.build(snapshot: snapshot(profiles: [home], operatorInfo: Operator()), error: nil, currentUID: "501", remembered: nil)
        #expect(unset.needsOperator)
        #expect(unset.operatorName == nil)
        let root = MenuModel.build(snapshot: snapshot(profiles: [home], operatorInfo: Operator()), error: nil, currentUID: "0", remembered: nil)
        #expect(!root.needsOperator)
        let oldDaemon = MenuModel.build(snapshot: snapshot(profiles: [home], operatorInfo: nil), error: nil, currentUID: "501", remembered: nil)
        #expect(!oldDaemon.needsOperator)
    }

    @Test func testExitNodesGroupedByProfileAndCountry() throws {
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
        #expect(model.icon == .exitNode)
        let section = try #require(model.exitNode)
        #expect(section.isOn)
        #expect(section.isToggleEnabled)
        #expect(section.toggleTarget == nil)
        #expect(section.toggleTitle == "Exit Node: relay (work)")
        #expect(section.note == nil)

        #expect(section.groups.map(\.profileName) == ["home", "work"])
        let homeGroup = section.groups[0]
        #expect(homeGroup.nodes.map(\.title) == ["attic", "gateway"])
        #expect(homeGroup.nodes.map(\.isOnline) == [false, true])
        #expect(homeGroup.countries.map(\.name) == ["Germany", "USA"])
        #expect(homeGroup.countries[0].nodes.map(\.title) == ["Berlin — de-ber-wg-001", "Frankfurt — de-fra-wg-001"])
        #expect(!homeGroup.countries[0].containsSelection)
        #expect(section.groups[1].nodes.map(\.isSelected) == [true])
        #expect(section.groups[1].nodes[0].ref == ExitNodeRef(profileName: "work", nodeID: "n3", label: "relay"))
    }

    @Test func testSelectedExitNodeWaiting() {
        let nodes = ExitNodes(selected: SelectedExitNode(profileID: "p2", profileName: "work", nodeID: "n3", dnsName: "", state: "waiting", reason: "profile_unavailable"))
        let model = MenuModel.build(snapshot: snapshot(profiles: [home, work], exitNodes: nodes), error: nil, currentUID: "501", remembered: nil)
        #expect(model.icon == .connected)
        #expect(model.exitNode?.toggleTitle == "Exit Node: n3 (work)")
        #expect(model.exitNode?.note == "Waiting for work to connect")
        #expect(model.exitNode?.isOn == true)
    }

    @Test func testRememberedExitNodeCanBeTurnedBackOn() {
        let remembered = ExitNodeRef(profileName: "home", nodeID: "n1", label: "gateway")
        let available = ExitNodes(available: [AvailableExitNode(profileID: "p1", profileName: "home", nodeID: "n1", dnsName: "gateway.home.ts.net.")])
        let on = MenuModel.build(snapshot: snapshot(profiles: [home], exitNodes: available), error: nil, currentUID: "501", remembered: remembered)
        #expect(on.exitNode?.isOn == false)
        #expect(on.exitNode?.toggleTarget == remembered)
        #expect(on.exitNode?.isToggleEnabled == true)
        #expect(on.exitNode?.toggleTitle == "Exit Node: gateway (home)")

        let gone = MenuModel.build(snapshot: snapshot(profiles: [home]), error: nil, currentUID: "501", remembered: remembered)
        #expect(gone.exitNode?.isToggleEnabled == false)
        #expect(gone.exitNode?.note == "Not available right now")
    }

    @Test func testNoExitNodeChosenYet() {
        let available = ExitNodes(available: [AvailableExitNode(profileID: "p1", profileName: "home", nodeID: "n1", dnsName: "gateway.home.ts.net.")])
        let model = MenuModel.build(snapshot: snapshot(profiles: [home], exitNodes: available), error: nil, currentUID: "501", remembered: nil)
        #expect(model.exitNode?.toggleTitle == "Exit Node: None")
        #expect(model.exitNode?.isToggleEnabled == false)
    }

    @Test func testShortName() {
        #expect(MenuModel.shortName("gateway.home.ts.net.", fallback: "x") == "gateway")
        #expect(MenuModel.shortName("", fallback: "nID") == "nID")
        #expect(MenuModel.shortName("single", fallback: "x") == "single")
    }
}
