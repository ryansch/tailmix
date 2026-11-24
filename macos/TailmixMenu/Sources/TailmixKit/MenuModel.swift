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

public enum IconState: Equatable {
    /// The daemon cannot be reached.
    case unavailable
    /// No profile is connected, or tailmix is paused.
    case disconnected
    case connected
    /// Default traffic goes through an exit node.
    case exitNode
}

public struct ProfileRow: Equatable {
    public var name: String
    public var detail: String
    /// Whether the profile is enabled; shown as a checkmark.
    public var isOn: Bool
    /// False while tailmix is paused; profiles cannot change then.
    public var isActionable: Bool
    public var loginURL: URL?
    public var errorMessage: String?
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

public struct ExitNodeSection: Equatable {
    /// The row that turns the exit node on and off.
    public var toggleTitle: String
    public var isOn: Bool
    /// The node the toggle turns on; nil when it can only turn it off or
    /// there is nothing to turn on.
    public var toggleTarget: ExitNodeRef?
    public var isToggleEnabled: Bool
    /// Explains why the selected exit node is not carrying traffic.
    public var note: String?
    public var groups: [ExitNodeProfileGroup]
}

public struct MenuModel: Equatable {
    public var headline: String
    public var icon: IconState
    public var isDaemonReachable: Bool
    public var profiles: [ProfileRow]
    public var exitNode: ExitNodeSection?
    /// Set when this user must be made the operator before making changes.
    public var needsOperator: Bool
    public var operatorName: String?

    public static func build(snapshot: Snapshot?, error: Error?, currentUID: String, remembered: ExitNodeRef?) -> MenuModel {
        guard let snapshot else {
            return MenuModel(
                headline: unreachableHeadline(error), icon: .unavailable, isDaemonReachable: false,
                profiles: [], exitNode: nil, needsOperator: false, operatorName: nil)
        }
        let paused = snapshot.status.state == "down"
        let profiles = snapshot.status.profiles.map { profileRow($0, paused: paused) }
        let connected = snapshot.status.profiles.filter { $0.runtimeState == "running" }.count

        let headline: String
        if paused {
            headline = "tailmix is paused"
        } else if snapshot.status.profiles.isEmpty {
            headline = "No profiles"
        } else {
            let total = snapshot.status.profiles.count
            headline = total == 1
                ? (connected == 1 ? "Connected" : "Not connected")
                : "\(connected) of \(total) profiles connected"
        }

        let selected = snapshot.exitNodes.selected
        let icon: IconState
        if paused || connected == 0 {
            icon = .disconnected
        } else if selected?.state == "installed" {
            icon = .exitNode
        } else {
            icon = .connected
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
            headline: headline, icon: icon, isDaemonReachable: true, profiles: profiles,
            exitNode: exitNodeSection(snapshot, remembered: remembered, paused: paused),
            needsOperator: needsOperator, operatorName: operatorName)
    }

    static func unreachableHeadline(_ error: Error?) -> String {
        if error is TransportError || error == nil {
            return "tailmix daemon is not running"
        }
        return "tailmix: \(error!)"
    }

    static func profileRow(_ profile: Profile, paused: Bool) -> ProfileRow {
        let detail: String
        switch profile.runtimeState {
        case "disabled": detail = "Disconnected"
        case "down": detail = "Paused"
        case "running":
            detail = profile.peerCount > 0 ? "Connected · \(profile.peerCount) \(profile.peerCount == 1 ? "peer" : "peers")" : "Connected"
        case "starting": detail = "Connecting…"
        case "needs-login": detail = "Needs login"
        case "error": detail = "Error"
        default: detail = profile.runtimeState
        }
        let loginURL = profile.runtimeState == "needs-login" && !profile.authURL.isEmpty ? URL(string: profile.authURL) : nil
        return ProfileRow(
            name: profile.name, detail: detail, isOn: profile.enabled, isActionable: !paused,
            loginURL: loginURL, errorMessage: profile.lastError.isEmpty ? nil : profile.lastError)
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
            return ExitNodeSection(
                toggleTitle: "Exit Node: \(host) (\(selected.profileName))", isOn: true, toggleTarget: nil,
                isToggleEnabled: !paused, note: note, groups: groups)
        }
        if let remembered {
            let isAvailable = available.contains { $0.profileName == remembered.profileName && $0.nodeID == remembered.nodeID }
            return ExitNodeSection(
                toggleTitle: "Exit Node: \(remembered.label) (\(remembered.profileName))", isOn: false,
                toggleTarget: remembered, isToggleEnabled: isAvailable && !paused,
                note: isAvailable ? nil : "Not available right now", groups: groups)
        }
        return ExitNodeSection(
            toggleTitle: "Exit Node: None", isOn: false, toggleTarget: nil, isToggleEnabled: false,
            note: nil, groups: groups)
    }

    /// The first DNS label, which is the machine name within its tailnet.
    public static func shortName(_ dnsName: String, fallback: String) -> String {
        let trimmed = dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
        let first = trimmed.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        return first.isEmpty ? fallback : first
    }
}
