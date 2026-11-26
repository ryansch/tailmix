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

    private func texts(_ row: ProfileRow) -> [String] { row.status?.segments.map(\.text) ?? [] }

    private func row(_ profile: Profile) -> ProfileRow {
        MenuModel.build(snapshot: snapshot(profiles: [profile]), error: nil, currentUID: "501", remembered: nil).profiles[0]
    }

    @Test func testUnreachableDaemon() {
        let model = MenuModel.build(snapshot: nil, error: TransportError("refused"), currentUID: "501", remembered: nil)
        #expect(model.icon == .unavailable)
        #expect(!model.isDaemonReachable)
        #expect(model.header == MenuHeader(title: "tailmix", status: "Not running"))

        let noError = MenuModel.build(snapshot: nil, error: nil, currentUID: "501", remembered: nil)
        #expect(noError.header.status == "Not running")
        struct Other: Error {}
        let other = MenuModel.build(snapshot: nil, error: Other(), currentUID: "501", remembered: nil)
        #expect(other.header.status == "Unavailable")
    }

    @Test func testProfilesAndHeadline() {
        let lab = Profile(id: "p3", name: "lab", enabled: true, runtimeState: "needs-login", authURL: "https://login.example/a", lastError: "boom")
        let model = MenuModel.build(snapshot: snapshot(profiles: [home, work, lab]), error: nil, currentUID: "501", remembered: nil)
        #expect(model.header.status == "1 of 3 connected")
        #expect(model.icon == .badges([
            ProfileBadge(label: "H", connected: true, routes: false, error: false),
            ProfileBadge(label: "W", connected: false, routes: false, error: false),
            ProfileBadge(label: "L", connected: false, routes: false, error: true, needsSignIn: true),
        ]))
        #expect(texts(model.profiles[0]) == ["3 peers"])
        #expect(model.profiles[1].status == nil)
        #expect(model.profiles[2].status == ProfileStatus(
            segments: [StatusSegment(text: "Error", style: .warning)], opensURL: nil, hasSubmenu: true))
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
        #expect(model.header.status == "Paused")
        #expect(model.icon == .paused)
        #expect(texts(model.profiles[0]) == ["Paused"])
        #expect(!model.profiles[0].isActionable)
    }

    @Test func testSingleProfileHeader() {
        func status(_ profiles: [Profile]) -> String {
            MenuModel.build(snapshot: snapshot(profiles: profiles), error: nil, currentUID: "501", remembered: nil).header.status
        }
        #expect(status([home]) == "Connected")
        #expect(status([work]) == "Not connected")
        #expect(status([]) == "No profiles")
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
        #expect(section.value == "relay")
        #expect(section.badge == "W")
        #expect(section.isOn)
        #expect(!section.isWarning)
        #expect(section.note == nil)
        #expect(section.lastUsed == nil)

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
        #expect(model.exitNode?.value == "n3")
        #expect(model.exitNode?.badge == "W")
        #expect(model.exitNode?.isWarning == true)
        #expect(model.exitNode?.note == "Waiting for work to connect")
        #expect(model.exitNode?.isOn == true)
        #expect(model.exitNode?.lastUsed == nil)
    }

    @Test func testRememberedExitNodeCanBeTurnedBackOn() {
        let remembered = ExitNodeRef(profileName: "home", nodeID: "n1", label: "gateway")
        let available = ExitNodes(available: [AvailableExitNode(profileID: "p1", profileName: "home", nodeID: "n1", dnsName: "gateway.home.ts.net.")])
        let on = MenuModel.build(snapshot: snapshot(profiles: [home], exitNodes: available), error: nil, currentUID: "501", remembered: remembered)
        #expect(on.exitNode?.value == "None")
        #expect(on.exitNode?.isOn == false)
        #expect(on.exitNode?.isWarning == false)
        #expect(on.exitNode?.note == nil)
        #expect(on.exitNode?.lastUsed == LastUsedExitNode(ref: remembered, title: "Last used: gateway (home)", isActionable: true))
    }

    @Test func testLastUsedUnavailable() {
        let remembered = ExitNodeRef(profileName: "home", nodeID: "n1", label: "gateway")
        let gone = MenuModel.build(snapshot: snapshot(profiles: [home]), error: nil, currentUID: "501", remembered: remembered)
        #expect(gone.exitNode?.value == "None")
        #expect(gone.exitNode?.lastUsed == LastUsedExitNode(ref: remembered, title: "Last used: gateway (home)", isActionable: false))
        #expect(gone.exitNode?.isWarning == false)
        #expect(gone.exitNode?.note == nil)
    }

    @Test func testLastUsedWhilePaused() {
        let remembered = ExitNodeRef(profileName: "home", nodeID: "n1", label: "gateway")
        let pausedHome = Profile(id: "p1", name: "home", enabled: true, runtimeState: "down")
        let available = ExitNodes(available: [AvailableExitNode(profileID: "p1", profileName: "home", nodeID: "n1", dnsName: "gateway.home.ts.net.")])
        let paused = MenuModel.build(snapshot: snapshot(state: "down", profiles: [pausedHome], exitNodes: available),
                                     error: nil, currentUID: "501", remembered: remembered)
        #expect(paused.exitNode?.lastUsed?.ref == remembered)
        #expect(paused.exitNode?.lastUsed?.isActionable == false)
    }

    @Test func testLastUsedHiddenWhileSelected() {
        let remembered = ExitNodeRef(profileName: "home", nodeID: "n1", label: "gateway")
        let nodes = ExitNodes(
            selected: SelectedExitNode(profileID: "p1", profileName: "home", nodeID: "n1", dnsName: "gateway.home.ts.net.", state: "installed"),
            available: [AvailableExitNode(profileID: "p1", profileName: "home", nodeID: "n1", dnsName: "gateway.home.ts.net.")])
        let model = MenuModel.build(snapshot: snapshot(profiles: [home], exitNodes: nodes), error: nil, currentUID: "501", remembered: remembered)
        #expect(model.exitNode?.value == "gateway")
        #expect(model.exitNode?.lastUsed == nil)
    }

    @Test func testNoExitNodeChosenYet() {
        let available = ExitNodes(available: [AvailableExitNode(profileID: "p1", profileName: "home", nodeID: "n1", dnsName: "gateway.home.ts.net.")])
        let model = MenuModel.build(snapshot: snapshot(profiles: [home], exitNodes: available), error: nil, currentUID: "501", remembered: nil)
        #expect(model.exitNode?.value == "None")
        #expect(model.exitNode?.isOn == false)
        #expect(model.exitNode?.isWarning == false)
        #expect(model.exitNode?.note == nil)
        #expect(model.exitNode?.badge == nil)
        #expect(model.exitNode?.lastUsed == nil)
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

    /// Friday 2026-11-27 10:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_795_773_600)

    private func expiring(_ expiry: Date?, state: String = "running") -> Profile {
        Profile(name: "home", enabled: true, runtimeState: state, peerCount: 2, keyExpiry: expiry)
    }

    @Test func testIsExpiringSoon() {
        let window = MenuModel.expiryWarning
        #expect(window == 3 * 24 * 3600)
        #expect(MenuModel.isExpiringSoon(expiring(now.addingTimeInterval(window)), now: now))
        #expect(MenuModel.isExpiringSoon(expiring(now.addingTimeInterval(1)), now: now))
        #expect(!MenuModel.isExpiringSoon(expiring(now.addingTimeInterval(window + 1)), now: now))
        #expect(!MenuModel.isExpiringSoon(expiring(now.addingTimeInterval(-1)), now: now))
        #expect(!MenuModel.isExpiringSoon(expiring(now), now: now))
        #expect(!MenuModel.isExpiringSoon(expiring(nil), now: now))
        #expect(!MenuModel.isExpiringSoon(expiring(now.addingTimeInterval(3600), state: "starting"), now: now))
        #expect(!MenuModel.isExpiringSoon(expiring(now.addingTimeInterval(3600), state: "needs-login"), now: now))
    }

    @Test func testExpiryWeekday() {
        let utc = TimeZone(identifier: "UTC")!
        let posix = Locale(identifier: "en_US_POSIX")
        #expect(MenuModel.expiryWeekday(now, locale: posix, timeZone: utc) == "Fri")
        #expect(MenuModel.expiryWeekday(now, locale: posix, timeZone: TimeZone(identifier: "Pacific/Honolulu")!) == "Fri")
        #expect(MenuModel.expiryWeekday(now.addingTimeInterval(-11 * 3600), locale: posix, timeZone: utc) == "Thu")
    }

    @Test func testBadgeFlags() {
        let needsLogin = Profile(name: "home", enabled: true, runtimeState: "needs-login",
                                 keyExpiry: now.addingTimeInterval(3600), keyExpired: true)
        let soon = Profile(name: "work", enabled: true, runtimeState: "running", keyExpiry: now.addingTimeInterval(3600))
        let later = Profile(name: "lab", enabled: true, runtimeState: "running", keyExpiry: now.addingTimeInterval(10 * 24 * 3600))
        let model = MenuModel.build(snapshot: snapshot(profiles: [needsLogin, soon, later]), error: nil,
                                    currentUID: "501", remembered: nil, now: now)
        #expect(model.icon == .badges([
            ProfileBadge(label: "H", connected: false, routes: false, error: false, needsSignIn: true),
            ProfileBadge(label: "W", connected: true, routes: false, error: false, expiringSoon: true),
            ProfileBadge(label: "L", connected: true, routes: false, error: false),
        ]))
    }

    @Test func testExpiringRowDetail() {
        let utc = TimeZone(identifier: "UTC")!
        let posix = Locale(identifier: "en_US_POSIX")
        // now is Friday 10:00 UTC; this expiry is the same Friday at 20:00.
        let model = MenuModel.build(snapshot: snapshot(profiles: [expiring(now.addingTimeInterval(10 * 3600))]), error: nil,
                                    currentUID: "501", remembered: nil, now: now, locale: posix, timeZone: utc)
        #expect(model.profiles[0].status?.segments == [
            StatusSegment(text: "2 peers", style: .secondary),
            StatusSegment(text: "key expires Fri", style: .warning)])

        let notSoon = MenuModel.build(snapshot: snapshot(profiles: [expiring(now.addingTimeInterval(4 * 24 * 3600))]), error: nil,
                                      currentUID: "501", remembered: nil, now: now, locale: posix, timeZone: utc)
        #expect(texts(notSoon.profiles[0]) == ["2 peers"])
    }

    @Test func testSegmentOrderWithLocationAndExpiry() throws {
        let utc = TimeZone(identifier: "UTC")!
        let posix = Locale(identifier: "en_US_POSIX")
        let profile = Profile(
            name: "home", enabled: true, runtimeState: "running", peerCount: 2,
            acceptAllRoutes: true, acceptAllDNSRoutes: true, routesInEffect: false,
            location: ProfileLocation(
                supported: true, enabled: true, current: "home", override: "",
                networkAvailable: true, onHomeNetwork: true),
            keyExpiry: now.addingTimeInterval(10 * 3600))
        let model = MenuModel.build(snapshot: snapshot(profiles: [profile]), error: nil,
                                    currentUID: "501", remembered: nil, now: now, locale: posix, timeZone: utc)
        let row = try #require(model.profiles.first)
        #expect(row.status?.segments == [
            StatusSegment(text: "2 peers", style: .secondary),
            StatusSegment(text: "at home, routes off", style: .secondary),
            StatusSegment(text: "key expires Fri", style: .warning)])
    }

    @Test func testOnePeerAndZeroPeers() {
        #expect(texts(row(Profile(name: "home", enabled: true, runtimeState: "running", peerCount: 1))) == ["1 peer"])
        #expect(texts(row(Profile(name: "home", enabled: true, runtimeState: "running", peerCount: 0))) == ["Connected"])
    }

    @Test func testConnecting() {
        #expect(texts(row(Profile(name: "home", enabled: true, runtimeState: "starting"))) == ["Connecting…"])
    }

    @Test func testErrorStateWithoutMessage() {
        let profile = row(Profile(name: "home", enabled: true, runtimeState: "error", lastError: ""))
        #expect(profile.status == ProfileStatus(
            segments: [StatusSegment(text: "Error", style: .warning)], opensURL: nil, hasSubmenu: false))
    }

    @Test func testErrorShownForOffProfile() {
        let profile = row(Profile(name: "home", enabled: false, runtimeState: "disabled", lastError: "x"))
        #expect(profile.status == ProfileStatus(
            segments: [StatusSegment(text: "Error", style: .warning)], opensURL: nil, hasSubmenu: true))
        #expect(profile.errorMessage == "x")
    }

    @Test func testErrorWinsOverLogin() {
        let profile = row(Profile(name: "home", enabled: true, runtimeState: "needs-login",
                                  authURL: "https://login.example/a", lastError: "boom"))
        #expect(profile.status == ProfileStatus(
            segments: [StatusSegment(text: "Error", style: .warning)], opensURL: nil, hasSubmenu: true))
        #expect(profile.loginURL == URL(string: "https://login.example/a"))
    }

    @Test func testOtherStates() {
        #expect(texts(row(Profile(name: "home", enabled: true, runtimeState: "down"))) == ["Paused"])
        #expect(texts(row(Profile(name: "home", enabled: true, runtimeState: "disabled"))) == ["Disconnected"])
        #expect(row(Profile(name: "home", enabled: true, runtimeState: "odd")).status == ProfileStatus(
            segments: [StatusSegment(text: "odd", style: .secondary)], opensURL: nil, hasSubmenu: false))
    }

    @Test func testWaitingForLogin() {
        let waiting = Profile(name: "home", enabled: true, runtimeState: "needs-login", keyExpired: true)
        let withLink = Profile(name: "work", enabled: true, runtimeState: "needs-login", authURL: "https://login.example/a")
        let model = MenuModel.build(snapshot: snapshot(profiles: [waiting, withLink, home]), error: nil, currentUID: "501", remembered: nil)
        #expect(model.profiles.map(\.waitingForLogin) == [true, false, false])
        #expect(model.profiles[0].loginURL == nil)
        #expect(model.profiles[1].loginURL == URL(string: "https://login.example/a"))
        #expect(texts(model.profiles[0]) == ["Waiting for sign-in link…"])
        #expect(model.profiles[0].status?.opensURL == nil)
        #expect(model.profiles[1].status == ProfileStatus(
            segments: [StatusSegment(text: "Needs login — Log in…", style: .warning)],
            opensURL: URL(string: "https://login.example/a"), hasSubmenu: false))
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

    @Test func testLocationSummary() throws {
        #expect(try locationRow(current: "home", routesInEffect: false).location?.summary == "at home, routes off")
        #expect(try locationRow(current: "away", routesInEffect: true).location?.summary == "away, routes on")
        #expect(try locationRow(current: "unknown", routesInEffect: true).location?.summary == "location unknown, routes on")
        #expect(try locationRow(current: "away", override: "off", routesInEffect: false).location?.summary == "away, routes off (override)")
        #expect(try locationRow(current: "home", override: "on", routesInEffect: true).location?.summary == "at home, routes on (override)")
        // Configured accept-all off everywhere: the word still follows routesInEffect.
        #expect(try locationRow(current: "away", routesInEffect: false, acceptAllRoutes: false, acceptAllDNSRoutes: false)
            .location?.summary == "away, routes off")
    }

    @Test func testLocationRowSegments() throws {
        let profile = try locationRow(current: "home", routesInEffect: false)
        #expect(texts(profile) == ["Connected", "at home, routes off"])
        #expect(profile.status?.segments.map(\.style) == [.secondary, .secondary])
        #expect(profile.location?.overrideTitle == "Use home routes now")
        #expect(profile.status?.hasSubmenu == true)
    }

    @Test func testLocationWithoutActionsIsPlain() throws {
        let profile = try locationRow(routesInEffect: false, acceptAllRoutes: false, acceptAllDNSRoutes: false,
                                      networkAvailable: false)
        #expect(profile.location?.hasActions == false)
        #expect(profile.status?.hasSubmenu == false)
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
