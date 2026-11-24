import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A minimal HTTP/1.1 server on a Unix socket that answers each connection
/// with one canned response, standing in for tailmixd.
final class FakeDaemon {
    struct Request {
        var method: String
        var path: String
        var contentType: String?
        var body: Data
    }

    let directory: String
    private let fd: Int32
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var thread: Thread?

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    init(handler: @escaping (Request) -> (Int, String)) throws {
        directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("tmx-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = (directory as NSString).appendingPathComponent("tailmixd.sock")

        #if canImport(Darwin)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            throw NSError(domain: "FakeDaemon", code: Int(errno))
        }
        let listener = fd
        thread = Thread { [weak self] in
            while true {
                let conn = accept(listener, nil, nil)
                if conn < 0 { return }
                self?.serve(conn, handler: handler)
                close(conn)
            }
        }
        thread?.start()
    }

    func stop() {
        shutdown(fd, Int32(SHUT_RDWR))
        close(fd)
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func serve(_ conn: Int32, handler: (Request) -> (Int, String)) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var request: Request?
        while request == nil {
            let n = buffer.withUnsafeMutableBytes { read(conn, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            data.append(contentsOf: buffer[0..<n])
            request = Self.parse(data)
        }
        lock.lock()
        recorded.append(request!)
        lock.unlock()
        let (status, body) = handler(request!)
        // Use chunked encoding, as Go does for larger responses, so the
        // client's chunked decoding is exercised end to end.
        let payload = Data(body.utf8)
        var response = Data("HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        response.append(Data(String(payload.count, radix: 16).utf8))
        response.append(Data("\r\n".utf8))
        response.append(payload)
        response.append(Data("\r\n0\r\n\r\n".utf8))
        _ = response.withUnsafeBytes { write(conn, $0.baseAddress, $0.count) }
    }

    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = head[0].split(separator: " ")
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(parts[0]), path: String(parts[1]), contentType: headers["content-type"], body: Data(body.prefix(length)))
    }
}
