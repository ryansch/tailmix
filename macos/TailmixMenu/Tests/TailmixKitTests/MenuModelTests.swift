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
        #expect(model.icon == .badges([
            ProfileBadge(label: "H", connected: true, routes: false, error: false),
            ProfileBadge(label: "W", connected: false, routes: false, error: false),
            ProfileBadge(label: "L", connected: false, routes: false, error: true),
        ]))
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
        #expect(model.icon == .paused)
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
        #expect(model.icon == .badges([
            ProfileBadge(label: "H", connected: true, routes: false, error: false),
            ProfileBadge(label: "W", connected: true, routes: false, error: false),
        ]))
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
        #expect(model.icon == .badges([
            ProfileBadge(label: "H", connected: true, routes: false, error: false),
            ProfileBadge(label: "W", connected: false, routes: false, error: false),
        ]))
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

    @Test func testBadgeLabels() {
        #expect(MenuModel.badgeLabels(["home", "work"]) == ["H", "W"])
        #expect(MenuModel.badgeLabels(["home", "hq"]) == ["Ho", "Hq"])
        #expect(MenuModel.badgeLabels(["home", "homelab"]) == ["Home", "Homel"])
        #expect(MenuModel.badgeLabels(["a"]) == ["A"])
        #expect(MenuModel.badgeLabels([]) == [])
        #expect(MenuModel.badgeLabels([""]) == [""])
    }

    private func badges(_ profiles: [Profile]) -> IconState {
        MenuModel.build(snapshot: snapshot(profiles: profiles), error: nil, currentUID: "501", remembered: nil).icon
    }

    @Test func testBadgesAtHomeWithWorkOff() {
        let atHome = Profile(name: "home", enabled: true, runtimeState: "running", routesInEffect: false)
        #expect(badges([atHome, work]) == .badges([
            ProfileBadge(label: "H", connected: true, routes: false, error: false),
            ProfileBadge(label: "W", connected: false, routes: false, error: false),
        ]))
    }

    @Test func testBadgesBothOnWithRoutes() {
        let homeOn = Profile(name: "home", enabled: true, runtimeState: "running", routesInEffect: true)
        let workOn = Profile(name: "work", enabled: true, runtimeState: "running", routesInEffect: true)
        #expect(badges([homeOn, workOn]) == .badges([
            ProfileBadge(label: "H", connected: true, routes: true, error: false),
            ProfileBadge(label: "W", connected: true, routes: true, error: false),
        ]))
    }

    @Test func testBadgesAwayWithHomeRoutesOn() {
        let away = Profile(name: "home", enabled: true, runtimeState: "running", routesInEffect: true)
        let workOn = Profile(name: "work", enabled: true, runtimeState: "running", routesInEffect: false)
        #expect(badges([away, workOn]) == .badges([
            ProfileBadge(label: "H", connected: true, routes: true, error: false),
            ProfileBadge(label: "W", connected: true, routes: false, error: false),
        ]))
    }

    @Test func testBadgesHomeError() {
        let broken = Profile(name: "home", enabled: true, runtimeState: "error", lastError: "boom", routesInEffect: true)
        #expect(badges([broken, work]) == .badges([
            ProfileBadge(label: "H", connected: false, routes: false, error: true),
            ProfileBadge(label: "W", connected: false, routes: false, error: false),
        ]))
    }

    private func locationRow(
        current: String = "home", override: String = "", routesInEffect: Bool = false,
        acceptAllRoutes: Bool = true, acceptAllDNSRoutes: Bool = true,
        networkAvailable: Bool = true, onHomeNetwork: Bool = false, state: String = "up"
    ) throws -> ProfileRow {
        let profile = Profile(
            name: "home", enabled: true, runtimeState: state == "down" ? "down" : "running",
            acceptAllRoutes: acceptAllRoutes, acceptAllDNSRoutes: acceptAllDNSRoutes, routesInEffect: routesInEffect,
            location: ProfileLocation(
                supported: true, enabled: true, current: current, override: override,
                networkAvailable: networkAvailable, onHomeNetwork: onHomeNetwork))
        let model = MenuModel.build(snapshot: snapshot(state: state, profiles: [profile]), error: nil, currentUID: "501", remembered: nil)
        return try #require(model.profiles.first)
    }

    @Test func testNoLocationRowWithoutLocation() {
        let model = MenuModel.build(snapshot: snapshot(profiles: [home]), error: nil, currentUID: "501", remembered: nil)
        #expect(model.profiles[0].location == nil)
    }

    @Test func testLocationDetail() throws {
        #expect(try locationRow(current: "home", routesInEffect: false).location?.detail == "At home: routes off")
        #expect(try locationRow(current: "away", routesInEffect: true).location?.detail == "Away: routes on")
        #expect(try locationRow(current: "unknown", routesInEffect: true).location?.detail == "Location unknown: routes on")
        #expect(try locationRow(current: "away", override: "off", routesInEffect: false).location?.detail == "Away: routes off (override)")
        #expect(try locationRow(current: "home", override: "on", routesInEffect: true).location?.detail == "At home: routes on (override)")
        // Configured accept-all off everywhere: the word still follows routesInEffect.
        #expect(try locationRow(current: "away", routesInEffect: false, acceptAllRoutes: false, acceptAllDNSRoutes: false)
            .location?.detail == "Away: routes off")
    }

    @Test func testMarkAndForgetTitles() throws {
        let away = try #require(try locationRow(networkAvailable: true, onHomeNetwork: false).location)
        #expect(away.markTitle == "This network is home")
        #expect(away.forgetTitle == nil)

        let onHome = try #require(try locationRow(networkAvailable: true, onHomeNetwork: true).location)
        #expect(onHome.markTitle == nil)
        #expect(onHome.forgetTitle == "Forget this network")

        let offline = try #require(try locationRow(networkAvailable: false, onHomeNetwork: false).location)
        #expect(offline.markTitle == nil)
        #expect(offline.forgetTitle == nil)
    }

    @Test func testOverrideTitles() throws {
        let off = try #require(try locationRow(current: "home", routesInEffect: false).location)
        #expect(off.overrideTitle == "Use home routes now")
        #expect(off.overrideRoutes == "on")
        #expect(off.clearOverrideTitle == nil)

        let on = try #require(try locationRow(current: "away", routesInEffect: true).location)
        #expect(on.overrideTitle == "Skip home routes now")
        #expect(on.overrideRoutes == "off")
        #expect(on.clearOverrideTitle == nil)

        // Only one configured accept-all on is enough to offer "Use".
        let dnsOnly = try #require(try locationRow(routesInEffect: false, acceptAllRoutes: false, acceptAllDNSRoutes: true).location)
        #expect(dnsOnly.overrideTitle == "Use home routes now")
    }

    @Test func testUseRoutesHiddenWhenConfiguredOff() throws {
        let row = try #require(try locationRow(routesInEffect: false, acceptAllRoutes: false, acceptAllDNSRoutes: false).location)
        #expect(row.overrideTitle == nil)
        #expect(row.overrideRoutes == nil)
    }

    @Test func testOverrideSet() throws {
        let forcedOff = try #require(try locationRow(current: "away", override: "off", routesInEffect: false).location)
        #expect(forcedOff.overrideTitle == nil)
        #expect(forcedOff.overrideRoutes == nil)
        #expect(forcedOff.clearOverrideTitle == "Return to automatic")

        // Routes on under an override still offer "Skip".
        let forcedOn = try #require(try locationRow(current: "home", override: "on", routesInEffect: true).location)
        #expect(forcedOn.overrideTitle == "Skip home routes now")
        #expect(forcedOn.overrideRoutes == "off")
        #expect(forcedOn.clearOverrideTitle == "Return to automatic")
    }

    @Test func testLocationRowNotActionableWhilePaused() throws {
        let row = try locationRow(state: "down")
        #expect(row.location != nil)
        #expect(!row.isActionable)
    }

    @Test func testShortName() {
        #expect(MenuModel.shortName("gateway.home.ts.net.", fallback: "x") == "gateway")
        #expect(MenuModel.shortName("", fallback: "nID") == "nID")
        #expect(MenuModel.shortName("single", fallback: "x") == "single")
    }
}
