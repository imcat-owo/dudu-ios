import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// 极简原始 HTTP/1.1 客户端（测试专用）：裸 socket，就是为了能验协议层
/// 细节——状态码、响应头、SSE 事件原文、断线后用 Last-Event-ID 续传——
/// 这些在 URLSession 的高层封装里看不见。
final class RawHTTPClient: @unchecked Sendable {
    struct Response {
        var statusCode: Int
        var headers: [(String, String)]
        var body: String

        func header(_ name: String) -> String? {
            headers.first { $0.0.lowercased() == name.lowercased() }?.1
        }
    }

    enum ClientError: Error, CustomStringConvertible {
        case connectFailed(String)
        case sendFailed(String)
        case receiveFailed(String)
        case malformedResponse(String)
        case timedOut(waitingFor: String)

        var description: String {
            switch self {
            case .connectFailed(let detail): return "连接失败：\(detail)"
            case .sendFailed(let detail): return "发送失败：\(detail)"
            case .receiveFailed(let detail): return "接收失败：\(detail)"
            case .malformedResponse(let detail): return "响应形状不对：\(detail)"
            case .timedOut(let marker): return "等待超时，未见：\(marker)"
            }
        }
    }

    private var fd: Int32 = -1
    private let host: String
    private let port: Int

    init(host: String = "127.0.0.1", port: Int) {
        self.host = host
        self.port = port
    }

    deinit {
        close()
    }

    func connect() throws {
        let socketFD = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard socketFD >= 0 else {
            throw ClientError.connectFailed(String(cString: strerror(errno)))
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr(host)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Glibc.connect(socketFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let detail = String(cString: strerror(errno))
            Glibc.close(socketFD)
            throw ClientError.connectFailed(detail)
        }
        fd = socketFD
    }

    func close() {
        if fd >= 0 {
            Glibc.shutdown(fd, Int32(SHUT_RDWR))
            Glibc.close(fd)
            fd = -1
        }
    }

    func sendRequest(
        method: String, path: String, headers: [(String, String)], body: String? = nil
    ) throws {
        var request = "\(method) \(path) HTTP/1.1\r\n"
        for (name, value) in headers {
            request += "\(name): \(value)\r\n"
        }
        if let body {
            request += "Content-Length: \(body.utf8.count)\r\n"
        }
        request += "\r\n"
        if let body {
            request += body
        }
        try sendAll(request)
    }

    private func sendAll(_ string: String) throws {
        var bytes = [UInt8](string.utf8)
        try bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Glibc.send(
                    fd, base.advanced(by: sent), raw.count - sent, Int32(MSG_NOSIGNAL))
                if count < 0 {
                    throw ClientError.sendFailed(String(cString: strerror(errno)))
                }
                sent += count
            }
        }
    }

    /// 读到一个完整响应为止（按 Content-Length 或 chunked 终结块判断，
    /// 或对端关闭连接）。返回去 chunk 后的正文。
    func readResponse() throws -> Response {
        var data: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            if Self.isCompleteResponse(data) {
                break
            }
            setReceiveTimeout(seconds: 15)
            let count = Glibc.recv(fd, &buffer, buffer.count, 0)
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw ClientError.timedOut(waitingFor: "完整响应")
                }
                throw ClientError.receiveFailed(String(cString: strerror(errno)))
            }
            data.append(contentsOf: buffer[..<count])
        }
        return try Self.parse(data)
    }

    /// 读原始字节直到出现标记串（验开着的 SSE 流用；返回的是含 chunk 框帧的原文）。
    func readRawUntil(marker: String, timeoutSeconds: Double = 10) throws -> String {
        var data: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            if let text = String(bytes: data, encoding: .utf8), text.contains(marker) {
                return text
            }
            if Date() > deadline {
                throw ClientError.timedOut(waitingFor: marker)
            }
            setReceiveTimeout(seconds: 1)
            let count = Glibc.recv(fd, &buffer, buffer.count, 0)
            if count == 0 {
                throw ClientError.receiveFailed("对端在标记出现前关闭了连接")
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                throw ClientError.receiveFailed(String(cString: strerror(errno)))
            }
            data.append(contentsOf: buffer[..<count])
        }
    }

    /// 在超时内收到多少算多少（诊断用）：不因超时/对端关闭抛错，返回已收到的原文。
    func readAvailable(timeoutSeconds: Double) -> String {
        var data: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            setReceiveTimeout(seconds: 1)
            let count = Glibc.recv(fd, &buffer, buffer.count, 0)
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                break
            }
            data.append(contentsOf: buffer[..<count])
        }
        return String(bytes: data, encoding: .utf8) ?? "<非 UTF-8 \(data.count) 字节>"
    }

    private func setReceiveTimeout(seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(
            fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: - 响应解析

    static func parse(_ bytes: [UInt8]) throws -> Response {
        guard let headEnd = findHeadEnd(bytes) else {
            throw ClientError.malformedResponse("找不到响应头结束标记")
        }
        let headText = String(bytes: bytes[..<headEnd], encoding: .utf8) ?? ""
        let lines = headText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw ClientError.malformedResponse("响应为空")
        }
        let statusParts = statusLine.split(separator: " ")
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw ClientError.malformedResponse("状态行不对：\(statusLine)")
        }
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        var bodyBytes = Array(bytes[(headEnd + 4)...])
        let isChunked = headers.contains {
            $0.0.lowercased() == "transfer-encoding" && $0.1.lowercased().contains("chunked")
        }
        if isChunked {
            bodyBytes = dechunk(bodyBytes).bytes
        }
        return Response(
            statusCode: statusCode,
            headers: headers,
            body: String(bytes: bodyBytes, encoding: .utf8) ?? "")
    }

    static func isCompleteResponse(_ bytes: [UInt8]) -> Bool {
        guard let headEnd = findHeadEnd(bytes) else { return false }
        let headText = String(bytes: bytes[..<headEnd], encoding: .utf8) ?? ""
        let body = Array(bytes[(headEnd + 4)...])
        let lowered = headText.lowercased()
        if lowered.contains("transfer-encoding: chunked") {
            return dechunk(body).complete
        }
        if let range = lowered.range(of: "content-length:") {
            let rest = lowered[range.upperBound...]
            // 头值在冒号后带一个空格，必须先跳过空白再取数字，
            // 否则 prefix(isNumber) 恒为空、响应永远判不了完整。
            let numberText = rest.drop(while: { $0 == " " || $0 == "\t" })
                .prefix { $0.isNumber }
            if let length = Int(numberText) {
                return body.count >= length
            }
        }
        return false
    }

    /// 去 chunk 框帧；complete 表示见到了终结 0 块。
    static func dechunk(_ bytes: [UInt8]) -> (bytes: [UInt8], complete: Bool) {
        var result: [UInt8] = []
        var cursor = 0
        while cursor < bytes.count {
            guard let lineEnd = findCRLF(bytes, from: cursor) else {
                return (result, false)
            }
            let sizeText = String(bytes: bytes[cursor..<lineEnd], encoding: .ascii) ?? ""
            let sizeToken = sizeText.split(separator: ";").first.map(String.init) ?? ""
            guard
                let size = Int(
                    sizeToken.trimmingCharacters(in: .whitespaces), radix: 16)
            else {
                return (result, false)
            }
            cursor = lineEnd + 2
            if size == 0 {
                return (result, true)
            }
            guard bytes.count >= cursor + size else {
                return (result, false)
            }
            result.append(contentsOf: bytes[cursor..<cursor + size])
            cursor += size + 2  // 内容 + 尾随 CRLF
        }
        return (result, false)
    }

    private static func findHeadEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4) {
            if bytes[index] == 0x0D, bytes[index + 1] == 0x0A,
                bytes[index + 2] == 0x0D, bytes[index + 3] == 0x0A
            {
                return index
            }
        }
        return nil
    }

    private static func findCRLF(_ bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= start + 2 else { return nil }
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == 0x0D, bytes[index + 1] == 0x0A {
                return index
            }
            index += 1
        }
        return nil
    }
}
