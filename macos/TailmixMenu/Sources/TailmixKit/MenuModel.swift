import Foundation

/// Identifies an exit node so the app can turn it back on after it was
/// cleared. Stored in user defaults.
public struct ExitNodeRef: Codable, Equatable {
    public var profileName: String
    public var nodeID: String
    public var label: String

    public init(profileName: String, nodeID: String, label: String) {
        self.profileName = profileName
        self.nodeID = nodeID
        self.label = label
    }
}

/// One profile's mark in the menu bar icon.
public struct ProfileBadge: Equatable {
    public var label: String
    /// Drawn solid when connected, outlined otherwise.
    public var connected: Bool
    /// The profile's routes are in effect; drawn as a bar under the label.
    public var routes: Bool
    /// The profile has an error; drawn amber.
    public var error: Bool
    /// The connected profile's node key expires soon.
    public var expiringSoon: Bool
    /// The profile needs sign-in; wins over expiringSoon.
    public var needsSignIn: Bool

    public init(label: String, connected: Bool, routes: Bool, error: Bool,
                expiringSoon: Bool = false, needsSignIn: Bool = false) {
        self.label = label
        self.connected = connected
        self.routes = routes
        self.error = error
        self.expiringSoon = expiringSoon
        self.needsSignIn = needsSignIn
    }
}

public enum IconState: Equatable {
    /// The daemon cannot be reached.
    case unavailable
    /// tailmix is paused.
    case paused
    /// One badge per profile, in the daemon's profile order.
    case badges([ProfileBadge])
}

/// The menu's two-line header.
public struct MenuHeader: Equatable {
    /// Always "tailmix".
    public var title: String
    public var status: String

    public init(title: String, status: String) {
        self.title = title
        self.status = status
    }
}

public enum StatusStyle: Equatable {
    case secondary, warning
}

public struct StatusSegment: Equatable {
    public var text: String
    public var style: StatusStyle

    public init(text: String, style: StatusStyle) {
        self.text = text
        self.style = style
    }
}

/// A profile's second row. nil on ProfileRow means the profile is one row.
public struct ProfileStatus: Equatable {
    /// Joined with " · " when drawn.
    public var segments: [StatusSegment]
    /// Set when clicking the row opens this URL (needs login, link ready).
    public var opensURL: URL?
    /// Whether the row has a submenu: the error message (if any) first,
    /// then the profile's location actions.
    public var hasSubmenu: Bool

    public init(segments: [StatusSegment], opensURL: URL?, hasSubmenu: Bool) {
        self.segments = segments
        self.opensURL = opensURL
        self.hasSubmenu = hasSubmenu
    }
}

/// An opted-in profile's location-aware routing: a summary for its status
/// row and the actions for its submenu. A nil title means that action is not
/// shown.
public struct LocationRow: Equatable {
    /// Such as "at home, routes off"; reads as a continuation of the row.
    public var summary: String
    public var markTitle: String?
    public var forgetTitle: String?
    public var overrideTitle: String?
    /// The override the override item sets: "on" or "off".
    public var overrideRoutes: String?
    public var clearOverrideTitle: String?

    public var hasActions: Bool {
        markTitle != nil || forgetTitle != nil || overrideTitle != nil || clearOverrideTitle != nil
    }
}

public struct ProfileRow: Equatable {
    public var name: String
    /// Whether the profile is enabled; shown as the switch's state.
    public var isOn: Bool
    /// False while tailmix is paused; profiles cannot change then.
    public var isActionable: Bool
    public var loginURL: URL?
    /// The profile needs sign-in but the daemon has no link yet.
    public var waitingForLogin: Bool
    public var errorMessage: String?
    /// nil when the profile does not use location-aware routing.
    public var location: LocationRow?
    /// The second row; nil when the profile is off and has no error.
    public var status: ProfileStatus?
}

public struct ExitNodeChoice: Equatable {
    public var ref: ExitNodeRef
    public var title: String
    public var isSelected: Bool
    public var isOnline: Bool
}

public struct ExitNodeCountry: Equatable {
    public var name: String
    public var nodes: [ExitNodeChoice]
    public var containsSelection: Bool { nodes.contains { $0.isSelected } }
}

public struct ExitNodeProfileGroup: Equatable {
    public var profileName: String
    public var nodes: [ExitNodeChoice]
    public var countries: [ExitNodeCountry]
}

/// The exit node used before the current "None", offered in the submenu so
/// it can be turned back on.
public struct LastUsedExitNode: Equatable {
    public var ref: ExitNodeRef
    /// "Last used: gateway (home)"
    public var title: String
    /// Offered right now and tailmix is not paused.
    public var isActionable: Bool

    public init(ref: ExitNodeRef, title: String, isActionable: Bool) {
        self.ref = ref
        self.title = title
        self.isActionable = isActionable
    }
}

/// One "Exit Node" row whose submenu holds the choices.
public struct ExitNodeSection: Equatable {
    /// Trailing value on the main row: "None" or the node's short name.
    public var value: String
    /// The selected node's profile, as its menu bar badge label ("W");
    /// nil when no exit node is selected.
    public var badge: String?
    public var isOn: Bool
    /// The main row's value is drawn amber: on, but not carrying traffic.
    public var isWarning: Bool
    /// Shown amber at the top of the submenu; only when on and not carrying traffic.
    public var note: String?
    /// Only when no exit node is selected and one is remembered.
    public var lastUsed: LastUsedExitNode?
    public var groups: [ExitNodeProfileGroup]
}

public struct MenuModel: Equatable {
    public var header: MenuHeader
    public var icon: IconState
    public var isDaemonReachable: Bool
    public var profiles: [ProfileRow]
    public var exitNode: ExitNodeSection?
    /// Set when this user must be made the operator before making changes.
    public var needsOperator: Bool
    public var operatorName: String?

    /// How long before a connected profile's key expires that it counts as
    /// expiring soon.
    public static let expiryWarning: TimeInterval = 3 * 24 * 3600

    public static func build(snapshot: Snapshot?, error: Error?, currentUID: String, remembered: ExitNodeRef?,
                             now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> MenuModel {
        guard let snapshot else {
            return MenuModel(
                header: MenuHeader(title: "tailmix", status: unreachableStatus(error)), icon: .unavailable, isDaemonReachable: false,
                profiles: [], exitNode: nil, needsOperator: false, operatorName: nil)
        }
        let paused = snapshot.status.state == "down"
        let profiles = snapshot.status.profiles.map {
            profileRow($0, paused: paused, now: now, locale: locale, timeZone: timeZone)
        }
        let connected = snapshot.status.profiles.filter { $0.runtimeState == "running" }.count

        let status: String
        if paused {
            status = "Paused"
        } else if snapshot.status.profiles.isEmpty {
            status = "No profiles"
        } else {
            let total = snapshot.status.profiles.count
            status = total == 1
                ? (connected == 1 ? "Connected" : "Not connected")
                : "\(connected) of \(total) connected"
        }

        let icon: IconState
        if paused {
            icon = .paused
        } else {
            let labels = badgeLabels(snapshot.status.profiles.map(\.name))
            icon = .badges(zip(snapshot.status.profiles, labels).map { profile, label in
                let isConnected = profile.runtimeState == "running"
                let needsSignIn = profile.runtimeState == "needs-login"
                return ProfileBadge(
                    label: label, connected: isConnected, routes: isConnected && profile.routesInEffect,
                    error: !profile.lastError.isEmpty,
                    expiringSoon: isExpiringSoon(profile, now: now) && !needsSignIn, needsSignIn: needsSignIn)
            })
        }

        var needsOperator = false
        var operatorName: String?
        if let info = snapshot.operatorInfo {
            needsOperator = currentUID != "0" && info.uid != currentUID
            if !info.uid.isEmpty {
                operatorName = info.username.isEmpty ? "uid \(info.uid)" : info.username
            }
        }

        return MenuModel(
            header: MenuHeader(title: "tailmix", status: status), icon: icon, isDaemonReachable: true, profiles: profiles,
            exitNode: exitNodeSection(snapshot, remembered: remembered, paused: paused),
            needsOperator: needsOperator, operatorName: operatorName)
    }

    /// Whether a connected profile's node key expires after now and within
    /// expiryWarning.
    public static func isExpiringSoon(_ profile: Profile, now: Date) -> Bool {
        guard profile.runtimeState == "running", let expiry = profile.keyExpiry else { return false }
        return expiry > now && expiry <= now.addingTimeInterval(expiryWarning)
    }

    /// The abbreviated weekday of a key expiry, such as "Fri".
    public static func expiryWeekday(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    /// The shortest prefix of each name that no other name shares, with its
    /// first character uppercased. A name that is a prefix of another gets
    /// its whole self.
    public static func badgeLabels(_ names: [String]) -> [String] {
        names.enumerated().map { index, name in
            let characters = Array(name)
            var length = min(1, characters.count)
            while length < characters.count {
                let prefix = String(characters[..<length])
                let shared = names.enumerated().contains { other, otherName in
                    other != index && otherName.hasPrefix(prefix)
                }
                if !shared { break }
                length += 1
            }
            let prefix = String(characters[..<length])
            return prefix.prefix(1).uppercased() + prefix.dropFirst()
        }
    }

    static func unreachableStatus(_ error: Error?) -> String {
        error is TransportError || error == nil ? "Not running" : "Unavailable"
    }

    static func profileRow(_ profile: Profile, paused: Bool, now: Date, locale: Locale, timeZone: TimeZone) -> ProfileRow {
        let needsLogin = profile.runtimeState == "needs-login"
        let loginURL = needsLogin && !profile.authURL.isEmpty ? URL(string: profile.authURL) : nil
        let location = locationRow(profile)
        return ProfileRow(
            name: profile.name, isOn: profile.enabled, isActionable: !paused,
            loginURL: loginURL, waitingForLogin: needsLogin && loginURL == nil,
            errorMessage: profile.lastError.isEmpty ? nil : profile.lastError,
            location: location,
            status: profileStatus(profile, loginURL: loginURL, location: location, now: now, locale: locale, timeZone: timeZone))
    }

    /// A profile's second row. The first matching rule wins: an error, then
    /// switched off (no row), then the runtime state.
    static func profileStatus(_ profile: Profile, loginURL: URL?, location: LocationRow?,
                              now: Date, locale: Locale, timeZone: TimeZone) -> ProfileStatus? {
        func plain(_ text: String, _ style: StatusStyle = .secondary) -> ProfileStatus {
            ProfileStatus(segments: [StatusSegment(text: text, style: style)], opensURL: nil, hasSubmenu: false)
        }
        if !profile.lastError.isEmpty {
            return ProfileStatus(segments: [StatusSegment(text: "Error", style: .warning)], opensURL: nil, hasSubmenu: true)
        }
        if !profile.enabled {
            return nil
        }
        switch profile.runtimeState {
        case "running":
            let peers: String
            switch profile.peerCount {
            case 0: peers = "Connected"
            case 1: peers = "1 peer"
            default: peers = "\(profile.peerCount) peers"
            }
            var segments = [StatusSegment(text: peers, style: .secondary)]
            if let location {
                segments.append(StatusSegment(text: location.summary, style: .secondary))
            }
            if isExpiringSoon(profile, now: now), let expiry = profile.keyExpiry {
                segments.append(StatusSegment(
                    text: "key expires \(expiryWeekday(expiry, locale: locale, timeZone: timeZone))", style: .warning))
            }
            return ProfileStatus(segments: segments, opensURL: nil, hasSubmenu: location?.hasActions ?? false)
        case "starting":
            return plain("Connecting…")
        case "needs-login":
            guard let loginURL else { return plain("Waiting for sign-in link…") }
            return ProfileStatus(
                segments: [StatusSegment(text: "Needs login — Log in…", style: .warning)], opensURL: loginURL, hasSubmenu: false)
        case "error":
            return plain("Error", .warning)
        case "down":
            return plain("Paused")
        case "disabled":
            return plain("Disconnected")
        default:
            return plain(profile.runtimeState)
        }
    }

    static func locationRow(_ profile: Profile) -> LocationRow? {
        guard let location = profile.location else { return nil }
        let place: String
        switch location.current {
        case "home": place = "at home"
        case "away": place = "away"
        default: place = "location unknown"
        }
        let hasOverride = !location.override.isEmpty
        var summary = "\(place), routes \(profile.routesInEffect ? "on" : "off")"
        if hasOverride {
            summary += " (override)"
        }

        var overrideTitle: String?
        var overrideRoutes: String?
        if profile.routesInEffect {
            overrideTitle = "Skip \(profile.name) routes now"
            overrideRoutes = "off"
        } else if !hasOverride && (profile.acceptAllRoutes || profile.acceptAllDNSRoutes) {
            // Location never turns on routes the configuration has off.
            overrideTitle = "Use \(profile.name) routes now"
            overrideRoutes = "on"
        }

        return LocationRow(
            summary: summary,
            markTitle: location.networkAvailable && !location.onHomeNetwork ? "This network is home" : nil,
            forgetTitle: location.onHomeNetwork ? "Forget this network" : nil,
            overrideTitle: overrideTitle, overrideRoutes: overrideRoutes,
            clearOverrideTitle: hasOverride ? "Return to automatic" : nil)
    }

    static func exitNodeSection(_ snapshot: Snapshot, remembered: ExitNodeRef?, paused: Bool) -> ExitNodeSection? {
        let available = snapshot.exitNodes.available
        let selected = snapshot.exitNodes.selected
        if available.isEmpty && selected == nil && remembered == nil {
            return nil
        }
        func isSelected(_ node: AvailableExitNode) -> Bool {
            guard let selected else { return false }
            return node.nodeID == selected.nodeID
                && (selected.profileID.isEmpty || node.profileID.isEmpty
                    ? node.profileName == selected.profileName
                    : node.profileID == selected.profileID)
        }

        // Group by profile in the daemon's profile order.
        var order = snapshot.status.profiles.map(\.name)
        for node in available where !order.contains(node.profileName) {
            order.append(node.profileName)
        }
        var groups: [ExitNodeProfileGroup] = []
        for profileName in order {
            let nodes = available.filter { $0.profileName == profileName }
            if nodes.isEmpty { continue }
            var direct: [ExitNodeChoice] = []
            var byCountry: [String: [(AvailableExitNode, ExitNodeChoice)]] = [:]
            for node in nodes {
                let host = shortName(node.dnsName, fallback: node.nodeID)
                let ref = ExitNodeRef(profileName: profileName, nodeID: node.nodeID, label: host)
                if let location = node.location, !location.country.isEmpty {
                    let title = location.city.isEmpty ? host : "\(location.city) — \(host)"
                    byCountry[location.country, default: []].append(
                        (node, ExitNodeChoice(ref: ref, title: title, isSelected: isSelected(node), isOnline: node.online)))
                } else {
                    direct.append(ExitNodeChoice(ref: ref, title: host, isSelected: isSelected(node), isOnline: node.online))
                }
            }
            direct.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            let countries = byCountry.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { country in
                let sorted = byCountry[country]!.sorted { a, b in
                    let cityA = a.0.location?.city ?? "", cityB = b.0.location?.city ?? ""
                    if cityA != cityB { return cityA.localizedStandardCompare(cityB) == .orderedAscending }
                    let priorityA = a.0.location?.priority ?? 0, priorityB = b.0.location?.priority ?? 0
                    if priorityA != priorityB { return priorityA > priorityB }
                    return a.1.title.localizedStandardCompare(b.1.title) == .orderedAscending
                }
                return ExitNodeCountry(name: country, nodes: sorted.map(\.1))
            }
            groups.append(ExitNodeProfileGroup(profileName: profileName, nodes: direct, countries: countries))
        }

        if let selected {
            let host = shortName(selected.dnsName, fallback: selected.nodeID)
            let note: String?
            if selected.state == "installed" {
                note = nil
            } else {
                switch selected.reason {
                case "profile_unavailable": note = "Waiting for \(selected.profileName) to connect"
                case "exit_node_unavailable": note = "\(host) is not offering an exit node"
                case "exit_node_not_applied": note = "Applying…"
                default: note = "Waiting"
                }
            }
            let names = snapshot.status.profiles.map(\.name)
            let badge = names.firstIndex(of: selected.profileName).map { badgeLabels(names)[$0] }
                ?? badgeLabels([selected.profileName]).first
            return ExitNodeSection(
                value: host, badge: badge, isOn: true, isWarning: note != nil, note: note, lastUsed: nil, groups: groups)
        }
        var lastUsed: LastUsedExitNode?
        if let remembered {
            let isAvailable = available.contains { $0.profileName == remembered.profileName && $0.nodeID == remembered.nodeID }
            lastUsed = LastUsedExitNode(
                ref: remembered, title: "Last used: \(remembered.label) (\(remembered.profileName))",
                isActionable: isAvailable && !paused)
        }
        return ExitNodeSection(
            value: "None", badge: nil, isOn: false, isWarning: false, note: nil, lastUsed: lastUsed, groups: groups)
    }

    /// The first DNS label, which is the machine name within its tailnet.
    public static func shortName(_ dnsName: String, fallback: String) -> String {
        let trimmed = dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
        let first = trimmed.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        return first.isEmpty ? fallback : first
    }
}
