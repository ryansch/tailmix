import Foundation

/// The daemon state the menu shows, read in one refresh.
public struct Snapshot: Equatable {
    public var status: Status
    public var exitNodes: ExitNodes
    /// nil when the daemon predates operator support.
    public var operatorInfo: Operator?

    public init(status: Status, exitNodes: ExitNodes, operatorInfo: Operator?) {
        self.status = status
        self.exitNodes = exitNodes
        self.operatorInfo = operatorInfo
    }
}

/// A client for tailmixd's local control API (see controlapi/client.go).
public struct ControlClient {
    public static let defaultSocketDirectory = "/var/run/tailmix"
    public static let socketName = "tailmixd.sock"

    public var transport: UnixHTTPTransport

    public init(socketDirectory: String = ControlClient.defaultSocketDirectory, timeout: TimeInterval = 30) {
        let path = (socketDirectory as NSString).appendingPathComponent(ControlClient.socketName)
        transport = UnixHTTPTransport(socketPath: path, timeout: timeout)
    }

    public func status() throws -> Status {
        try request("GET", "/v1/status")
    }

    public func exitNodes() throws -> ExitNodes {
        try request("GET", "/v1/exit-node")
    }

    public func operatorInfo() throws -> Operator {
        try request("GET", "/v1/operator")
    }

    public func snapshot() throws -> Snapshot {
        let status = try status()
        let exitNodes = try exitNodes()
        var operatorInfo: Operator?
        do {
            operatorInfo = try self.operatorInfo()
        } catch let error as APIError where error.code == "unsupported" || error.code == "http_404" {
            operatorInfo = nil
        }
        return Snapshot(status: status, exitNodes: exitNodes, operatorInfo: operatorInfo)
    }

    @discardableResult
    public func setProfileConnected(_ name: String, _ connected: Bool) throws -> Profile {
        try request("POST", Self.profilePath(name) + (connected ? "/enable" : "/disable"))
    }

    @discardableResult
    public func setExitNode(profileName: String, nodeID: String) throws -> ExitNodes {
        let body = try JSONEncoder().encode(SetExitNodeRequest(profileName: profileName, peer: nodeID))
        return try request("PUT", "/v1/exit-node", body: body)
    }

    @discardableResult
    public func clearExitNode() throws -> ExitNodes {
        try request("DELETE", "/v1/exit-node")
    }

    /// Escapes a profile name like Go's url.PathEscape.
    static func profilePath(_ name: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-._~")
        return "/v1/profiles/by-name/" + (name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)
    }

    private func request<T: Decodable>(_ method: String, _ path: String, body: Data? = nil) throws -> T {
        let response = try transport.send(method: method, path: path, body: body)
        guard (200..<300).contains(response.status) else {
            if let apiError = try? JSONDecoder().decode(APIError.self, from: response.body), !apiError.code.isEmpty {
                throw apiError
            }
            throw APIError(code: "http_\(response.status)", message: "tailmix daemon returned HTTP \(response.status)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw TransportError("decode tailmix daemon response: \(error)")
        }
    }
}
