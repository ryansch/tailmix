import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A transport failure: the daemon socket is missing, refused the connection,
/// timed out, or returned something that is not HTTP.
public struct TransportError: Error, Equatable, CustomStringConvertible {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

public struct HTTPResponse: Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    /// Parses one complete HTTP/1.x response read until the server closed the
    /// connection. It supports Content-Length, chunked, and close-delimited
    /// bodies.
    public static func parse(_ data: Data) throws -> HTTPResponse {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else {
            throw TransportError("incomplete HTTP response")
        }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            throw TransportError("invalid HTTP response header")
        }
        var lines = head.components(separatedBy: "\r\n")
        let statusParts = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/1."), let status = Int(statusParts[1]) else {
            throw TransportError("invalid HTTP status line")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(data[headerEnd.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try dechunk(body)
        } else if let lengthText = headers["content-length"], let length = Int(lengthText) {
            guard body.count >= length else { throw TransportError("truncated HTTP response body") }
            body = body.prefix(length)
        }
        return HTTPResponse(status: status, headers: headers, body: body)
    }

    static func dechunk(_ data: Data) throws -> Data {
        var output = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else {
                throw TransportError("truncated chunked HTTP body")
            }
            let sizeLine = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
            let sizeText = sizeLine.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                throw TransportError("invalid HTTP chunk size")
            }
            index = lineEnd.upperBound
            if size == 0 { return output }
            guard data.distance(from: index, to: data.endIndex) >= size + 2 else {
                throw TransportError("truncated HTTP chunk")
            }
            let chunkEnd = data.index(index, offsetBy: size)
            output.append(data[index..<chunkEnd])
            index = data.index(chunkEnd, offsetBy: 2)
        }
    }
}

/// Sends one HTTP request per connection over a Unix domain socket.
public struct UnixHTTPTransport: Sendable {
    public var socketPath: String
    public var timeout: TimeInterval

    public init(socketPath: String, timeout: TimeInterval = 30) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public func send(method: String, path: String, body: Data? = nil) throws -> HTTPResponse {
        let fd = try connect()
        defer { close(fd) }

        var request = "\(method) \(path) HTTP/1.1\r\nHost: tailmix\r\nConnection: close\r\nAccept: application/json\r\n"
        if let body {
            request += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        } else if method != "GET" {
            request += "Content-Length: 0\r\n"
        }
        request += "\r\n"
        var payload = Data(request.utf8)
        if let body { payload.append(body) }
        try writeAll(fd, payload)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw TransportError("tailmix daemon did not answer in time")
                }
                throw TransportError("read from tailmix daemon: \(String(cString: strerror(errno)))")
            }
            response.append(contentsOf: buffer[0..<n])
            if response.count > 16 << 20 { throw TransportError("tailmix daemon response is too large") }
        }
        return try HTTPResponse.parse(response)
    }

    private func connect() throws -> Int32 {
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw TransportError("create socket: \(String(cString: strerror(errno)))") }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw TransportError("socket path is too long: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw TransportError("connect to tailmix daemon at \(socketPath): \(reason)")
        }
        return fd
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        #if canImport(Darwin)
        let flags: Int32 = 0
        #else
        let flags = Int32(MSG_NOSIGNAL)
        #endif
        var offset = 0
        try data.withUnsafeBytes { raw in
            while offset < raw.count {
                let n = Foundation.send(fd, raw.baseAddress! + offset, raw.count - offset, flags)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw TransportError("write to tailmix daemon: \(String(cString: strerror(errno)))")
                }
                offset += n
            }
        }
    }
}
