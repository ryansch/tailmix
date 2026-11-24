import Foundation

// These types mirror the subset of github.com/maisem/tailmix/controlapi that
// the menu bar app reads. Every field is optional on the wire because the
// daemon omits empty values.

public struct APIError: Error, Equatable, Decodable, CustomStringConvertible {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case code, message }

    public var description: String { message.isEmpty ? code : message }
    public var isPermissionDenied: Bool { code == "permission_denied" }
}

public struct Profile: Equatable, Decodable {
    public var id: String
    public var name: String
    public var kind: String
    public var enabled: Bool
    public var runtimeState: String
    public var backendState: String
    public var selfDNSName: String
    public var peerCount: Int
    public var authURL: String
    public var lastError: String

    public init(id: String = "", name: String, kind: String = "tailscale", enabled: Bool,
                runtimeState: String, backendState: String = "", selfDNSName: String = "",
                peerCount: Int = 0, authURL: String = "", lastError: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
        self.runtimeState = runtimeState
        self.backendState = backendState
        self.selfDNSName = selfDNSName
        self.peerCount = peerCount
        self.authURL = authURL
        self.lastError = lastError
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        runtimeState = try c.decodeIfPresent(String.self, forKey: .runtimeState) ?? ""
        backendState = try c.decodeIfPresent(String.self, forKey: .backendState) ?? ""
        selfDNSName = try c.decodeIfPresent(String.self, forKey: .selfDNSName) ?? ""
        peerCount = try c.decodeIfPresent(Int.self, forKey: .peerCount) ?? 0
        authURL = try c.decodeIfPresent(String.self, forKey: .authURL) ?? ""
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, enabled, runtimeState, backendState, peerCount, lastError
        case selfDNSName = "selfDnsName"
        case authURL = "authUrl"
    }
}

public struct ExitNodeLocation: Equatable, Decodable {
    public var country: String
    public var countryCode: String
    public var city: String
    public var priority: Int

    public init(country: String = "", countryCode: String = "", city: String = "", priority: Int = 0) {
        self.country = country
        self.countryCode = countryCode
        self.city = city
        self.priority = priority
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        country = try c.decodeIfPresent(String.self, forKey: .country) ?? ""
        countryCode = try c.decodeIfPresent(String.self, forKey: .countryCode) ?? ""
        city = try c.decodeIfPresent(String.self, forKey: .city) ?? ""
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
    }

    private enum CodingKeys: String, CodingKey { case country, countryCode, city, priority }
}

public struct AvailableExitNode: Equatable, Decodable {
    public var profileID: String
    public var profileName: String
    public var nodeID: String
    public var dnsName: String
    public var online: Bool
    public var location: ExitNodeLocation?

    public init(profileID: String = "", profileName: String, nodeID: String, dnsName: String = "",
                online: Bool = true, location: ExitNodeLocation? = nil) {
        self.profileID = profileID
        self.profileName = profileName
        self.nodeID = nodeID
        self.dnsName = dnsName
        self.online = online
        self.location = location
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try c.decodeIfPresent(String.self, forKey: .profileID) ?? ""
        profileName = try c.decodeIfPresent(String.self, forKey: .profileName) ?? ""
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        dnsName = try c.decodeIfPresent(String.self, forKey: .dnsName) ?? ""
        online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? false
        location = try c.decodeIfPresent(ExitNodeLocation.self, forKey: .location)
    }

    private enum CodingKeys: String, CodingKey {
        case profileName, online, location
        case profileID = "profileId"
        case nodeID = "nodeId"
        case dnsName = "dnsName"
    }
}

public struct SelectedExitNode: Equatable, Decodable {
    public var profileID: String
    public var profileName: String
    public var nodeID: String
    public var dnsName: String
    public var online: Bool
    public var location: ExitNodeLocation?
    /// "installed" when traffic uses the node, otherwise "waiting".
    public var state: String
    public var reason: String

    public init(profileID: String = "", profileName: String, nodeID: String, dnsName: String = "",
                online: Bool = true, location: ExitNodeLocation? = nil, state: String = "installed",
                reason: String = "") {
        self.profileID = profileID
        self.profileName = profileName
        self.nodeID = nodeID
        self.dnsName = dnsName
        self.online = online
        self.location = location
        self.state = state
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try c.decodeIfPresent(String.self, forKey: .profileID) ?? ""
        profileName = try c.decodeIfPresent(String.self, forKey: .profileName) ?? ""
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        dnsName = try c.decodeIfPresent(String.self, forKey: .dnsName) ?? ""
        online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? false
        location = try c.decodeIfPresent(ExitNodeLocation.self, forKey: .location)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case profileName, online, location, state, reason
        case profileID = "profileId"
        case nodeID = "nodeId"
        case dnsName = "dnsName"
    }
}

public struct ExitNodes: Equatable, Decodable {
    public var selected: SelectedExitNode?
    public var available: [AvailableExitNode]
    public var reconcileError: String

    public init(selected: SelectedExitNode? = nil, available: [AvailableExitNode] = [], reconcileError: String = "") {
        self.selected = selected
        self.available = available
        self.reconcileError = reconcileError
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selected = try c.decodeIfPresent(SelectedExitNode.self, forKey: .selected)
        available = try c.decodeIfPresent([AvailableExitNode].self, forKey: .available) ?? []
        reconcileError = try c.decodeIfPresent(String.self, forKey: .reconcileError) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case selected, available, reconcileError }
}

public struct Status: Equatable, Decodable {
    /// "up" or "down".
    public var state: String
    public var profiles: [Profile]

    public init(state: String = "up", profiles: [Profile] = []) {
        self.state = state
        self.profiles = profiles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
    }

    private enum CodingKeys: String, CodingKey { case state, profiles }
}

public struct Operator: Equatable, Decodable {
    public var uid: String
    public var username: String

    public init(uid: String = "", username: String = "") {
        self.uid = uid
        self.username = username
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decodeIfPresent(String.self, forKey: .uid) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case uid, username }
}

struct SetExitNodeRequest: Encodable {
    var profileName: String
    var peer: String
}
