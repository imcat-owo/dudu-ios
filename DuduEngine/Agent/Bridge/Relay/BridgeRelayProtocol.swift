import Foundation

// MARK: - 「桥」中继协议 v1 —— 纯逻辑层（合并第 18(a) 条）
//
// 协议文本与 CF 侧共用，一字不许改（任务书约定）：
//
//   口令：32 随机字节 base64url（无 padding，约 43 字符），存 iOS 钥匙串
//         （kSecClassGenericPassword，service "bridge.relay"，account "token"）。
//         本文件不生成、不保存口令——只负责帧与地址的纯计算。
//   手机连：WebSocket `wss://<host>/device/<token>`。
//   帧（JSON 文本）：
//     手机→中继：{"type":"hello","app":"openminis-bridge","v":1}（连上即发）
//                {"type":"ping"}（每 25s）
//                {"type":"res","id":"<uuid>","status":200,
//                 "headers":{"content-type":"...","mcp-session-id":"..."},
//                 "body":"<base64>"}
//                本地失败回 {"type":"err","id":"<uuid>","message":"..."}
//     中继→手机：{"type":"req","id":"<uuid>","headers":{...},"body":"<base64>"}
//
// 本文件只依赖 Foundation（不碰 Security / Combine / SwiftUI / UIKit），
// 目的是让帧编解码、退避序列、请求头过滤、地址拼装都能脱离 iOS 单独测试。

/// 帧编解码失败。message 只描述结构问题，绝不携带帧内容（body 里可能有
/// 用户数据，口令虽不在帧里，但整体按「不落日志原文」处理）。
enum RelayFrameError: Error, Equatable {
    case notJSONObject
    case missingType
    case unknownType(String)
    case missingField(String)
    case wrongFieldType(String)
}

/// 中继协议帧。方向见文件头注释：hello / ping / response / error 是
/// 手机→中继，request 是中继→手机的唯一帧型。
enum RelayFrame: Equatable {
    /// 连上即发的自报家门帧。app / v 由协议常量固定，调用方不许自填别的值。
    case hello
    /// 应用层心跳（协议约定每 25s 一帧，不是 WS 协议层 ping）。
    case ping
    /// 本地 MCP 服务的完整响应回给中继。body 是原始响应字节的 base64。
    case response(id: String, status: Int, headers: [String: String], bodyBase64: String)
    /// 本地处理失败（服务没起、端口拿不到、HTTP 出错等）时回的错误帧。
    case error(id: String, message: String)
    /// 中继转来的一个 HTTP 请求：headers / body 照搬去打本地 MCP 服务。
    case request(id: String, headers: [String: String], bodyBase64: String)

    /// 协议常量：hello 帧的 app 字段。
    static let appName = "openminis-bridge"
    /// 协议常量：hello 帧的 v 字段。
    static let protocolVersion = 1
    /// 协议常量：ping 间隔（秒）。
    static let pingInterval: TimeInterval = 25

    /// 编码成一帧 JSON 文本。键序固定（sortedKeys）只为可复现，不影响解析。
    func encode() throws -> String {
        let object: [String: Any]
        switch self {
        case .hello:
            object = ["type": "hello", "app": Self.appName, "v": Self.protocolVersion]
        case .ping:
            object = ["type": "ping"]
        case .response(let id, let status, let headers, let bodyBase64):
            object = ["type": "res", "id": id, "status": status,
                      "headers": headers, "body": bodyBase64]
        case .error(let id, let message):
            object = ["type": "err", "id": id, "message": message]
        case .request(let id, let headers, let bodyBase64):
            object = ["type": "req", "id": id, "headers": headers, "body": bodyBase64]
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw RelayFrameError.notJSONObject
        }
        return text
    }

    /// 解码一帧 JSON 文本。只认协议帧型；结构不对明确抛错，由调用方决定
    /// 记日志还是断开——不在这里静默吞掉装没事。
    static func decode(_ text: String) throws -> RelayFrame {
        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else {
            throw RelayFrameError.notJSONObject
        }
        guard let type = object["type"] as? String else {
            throw RelayFrameError.missingType
        }
        switch type {
        case "hello":
            // hello 只由手机发出；解出来仅供测试与对拍，不参与收帧分发。
            guard (object["app"] as? String) != nil else { throw RelayFrameError.missingField("app") }
            guard (object["v"] as? NSNumber) != nil else { throw RelayFrameError.missingField("v") }
            return .hello
        case "ping":
            return .ping
        case "res":
            return .response(
                id: try requireString(object, "id"),
                status: try requireInt(object, "status"),
                headers: try optionalHeaders(object, "headers"),
                bodyBase64: try requireString(object, "body"))
        case "err":
            return .error(
                id: try requireString(object, "id"),
                message: try requireString(object, "message"))
        case "req":
            return .request(
                id: try requireString(object, "id"),
                headers: try optionalHeaders(object, "headers"),
                bodyBase64: try optionalString(object, "body") ?? "")
        default:
            throw RelayFrameError.unknownType(type)
        }
    }

    private static func requireString(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] else { throw RelayFrameError.missingField(key) }
        guard let string = value as? String else { throw RelayFrameError.wrongFieldType(key) }
        return string
    }

    private static func optionalString(_ object: [String: Any], _ key: String) throws -> String? {
        guard let value = object[key] else { return nil }
        guard let string = value as? String else { throw RelayFrameError.wrongFieldType(key) }
        return string
    }

    private static func requireInt(_ object: [String: Any], _ key: String) throws -> Int {
        guard let value = object[key] else { throw RelayFrameError.missingField(key) }
        guard let number = value as? NSNumber else { throw RelayFrameError.wrongFieldType(key) }
        return number.intValue
    }

    private static func optionalHeaders(_ object: [String: Any], _ key: String) throws -> [String: String] {
        guard let value = object[key] else { return [:] }
        guard let dict = value as? [String: Any] else { throw RelayFrameError.wrongFieldType(key) }
        var out: [String: String] = [:]
        for (k, v) in dict {
            guard let string = v as? String else { throw RelayFrameError.wrongFieldType(key) }
            out[k] = string
        }
        return out
    }
}

// MARK: - 断线重连退避

/// 指数退避序列：2s 起步、每次翻倍、60s 封顶；连接成功后 reset() 清零。
/// 纯值类型，便于把整条序列单测拍死。
struct RelayBackoff: Equatable {
    static let initialDelay: TimeInterval = 2
    static let maxDelay: TimeInterval = 60

    private(set) var currentDelay: TimeInterval = RelayBackoff.initialDelay

    /// 取下一次等待时长，并把序列推进一格（封顶后恒为 maxDelay）。
    mutating func nextDelay() -> TimeInterval {
        let delay = currentDelay
        currentDelay = min(currentDelay * 2, Self.maxDelay)
        return delay
    }

    /// 连接成功后调用：下次断线重新从 initialDelay 开始退避。
    mutating func reset() {
        currentDelay = Self.initialDelay
    }
}

// MARK: - 请求去重台账（第五节五-1：中继防重复转发，App 侧半边）
//
// 协议语义补充（v1 帧形一字不变，req 的 id 字段本就存在，这里立的是
// 它作为「唯一编号＋幂等键」的约定）：
//   - 每条逻辑请求有且只有一个编号（UUID），就是 req 帧的 id。
//   - 中继（Durable Object）侧的义务：同一条逻辑请求被重投时
//     （外部客户端重试、转发超时后重发等），沿用同一个 id 投递，
//     不许另编新号；并按「设备连接＋编号」记住最近处理过的编号，
//     重投的直接丢弃或回上次的结果。——这半的实现在 CF Worker
//     （仓外，bridge-merge/relay/worker.js），不在本仓，本文件只立约定。
//   - App 侧的义务（本类实现）：收到 req 先查台账——处理中的同号帧
//     直接丢弃；已完成的同号帧不重跑本地服务，把上次那份响应帧按
//     原编号重发（幂等回放）；只有新号才真正转发。
// 台账有界：已完成条目最多留 maxCompletedEntries 份、且只留
// completedTTL 秒，防长跑内存膨胀；判定与登记是同一个加锁原子动作，
// 并发重投不会两份都落进「新请求」。
final class RelayRequestLedger: @unchecked Sendable {
    enum BeginResult: Equatable {
        /// 第一次见到这个编号：已登记为处理中，调用方去真正执行。
        case newRequest
        /// 同号请求还在处理中：重投直接丢弃，第一份的响应会正常回去。
        case duplicateInFlight
        /// 同号请求已处理完：别重跑，把括号里这份响应帧按原编号重发。
        case replay(RelayFrame)
    }

    static let defaultMaxCompletedEntries = 128
    static let defaultCompletedTTL: TimeInterval = 600

    private let lock = NSLock()
    private var inFlight: Set<String> = []
    private var completed: [String: (frame: RelayFrame, completedAt: Date)] = [:]
    /// 完成顺序（FIFO），供过期修剪与超量淘汰从头部摘。
    private var completionOrder: [String] = []

    private let maxCompletedEntries: Int
    private let completedTTL: TimeInterval

    init(maxCompletedEntries: Int = RelayRequestLedger.defaultMaxCompletedEntries,
         completedTTL: TimeInterval = RelayRequestLedger.defaultCompletedTTL) {
        self.maxCompletedEntries = max(1, maxCompletedEntries)
        self.completedTTL = completedTTL
    }

    /// 收到 req 帧时先问这一句。
    func begin(id: String, now: Date = Date()) -> BeginResult {
        lock.lock()
        defer { lock.unlock() }
        pruneExpired(now: now)
        if inFlight.contains(id) { return .duplicateInFlight }
        if let entry = completed[id] { return .replay(entry.frame) }
        inFlight.insert(id)
        return .newRequest
    }

    /// 本地处理产出了响应帧（res / err 都算）时记账，之后同号重投
    /// 一律回放这一帧、不再重跑。调用方应先记账再发送：发送途中
    /// 连接被换掉，响应帧也不会丢，重投时还能补发。
    func complete(id: String, frame: RelayFrame, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        inFlight.remove(id)
        if completed[id] == nil {
            completionOrder.append(id)
        }
        completed[id] = (frame, now)
        while completionOrder.count > maxCompletedEntries {
            let oldest = completionOrder.removeFirst()
            completed.removeValue(forKey: oldest)
        }
    }

    private func pruneExpired(now: Date) {
        // completionOrder 按完成时间 FIFO，过期的一定在头部。
        while let first = completionOrder.first,
              let entry = completed[first],
              now.timeIntervalSince(entry.completedAt) > completedTTL {
            completionOrder.removeFirst()
            completed.removeValue(forKey: first)
        }
    }
}

// MARK: - 请求头过滤

/// 代理转发时的请求头清洗。协议约定 headers 照搬、hop-by-hop 头可剥；
/// 这里剥两类：
///   1. RFC 9110 的 hop-by-hop 头（含 Connection 头里点名的那批）；
///   2. host / content-length——本地这一跳由 URLSession 按实际 URL 与
///      body 重新生成，照搬中继那一跳的旧值会让本地服务收到自相矛盾
///      的请求（Host 对不上、长度对不上）。这不改变中继协议本身，
///      只是本地转发的标准做法。
enum RelayHeaderFilter {
    static let hopByHopHeaders: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade", "proxy-connection",
    ]

    /// 中继→本地：剥 hop-by-hop + Connection 点名头 + host / content-length。
    static func headersForLocalRequest(_ headers: [String: String]) -> [String: String] {
        var blocked = hopByHopHeaders
        blocked.insert("host")
        blocked.insert("content-length")
        for (key, value) in headers where key.lowercased() == "connection" {
            for token in value.split(separator: ",") {
                blocked.insert(token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
        }
        return filter(headers, blocked: blocked)
    }

    /// 本地→中继（res 帧）：只剥 hop-by-hop（含 Connection 点名头）。
    /// content-length 保留：body 字节与本地响应一致，长度是对得上的；
    /// mcp-session-id 这类端到端头原样带回（协议示例里明确有它）。
    static func headersForRelayResponse(_ headers: [String: String]) -> [String: String] {
        var blocked = hopByHopHeaders
        for (key, value) in headers where key.lowercased() == "connection" {
            for token in value.split(separator: ",") {
                blocked.insert(token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
        }
        return filter(headers, blocked: blocked)
    }

    private static func filter(_ headers: [String: String], blocked: Set<String>) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in headers where !blocked.contains(key.lowercased()) {
            out[key] = value
        }
        return out
    }
}

// MARK: - 中继地址

/// 中继地址的规范化与设备 URL 拼装。用户在设置页填的是 host
/// （如 xxx.workers.dev，可宽容带 scheme / 末尾路径），口令只出现在
/// 拼出的 URL 里——该 URL 绝不进日志、不进界面默认展示。
enum RelayEndpoint {
    /// 把用户输入规范成纯 authority（host[:port]）。接受带
    /// `wss://` / `https://` 前缀与末尾斜杠路径的粘贴，取第一段路径前
    /// 的部分。含空白或为空返回 nil。
    static func normalizedHost(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let schemeRange = text.range(of: "://") {
            text = String(text[schemeRange.upperBound...])
        }
        if let slash = text.firstIndex(of: "/") {
            text = String(text[..<slash])
        }
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { return nil }
        return text
    }

    /// 拼设备连接 URL：`wss://<host>/device/<token>`。
    /// token 是 base64url（无 padding），字符集本身 URL-safe，不需要再转义。
    static func deviceURL(host rawHost: String, token: String) -> URL? {
        guard let authority = normalizedHost(rawHost) else { return nil }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "wss"
        if let colon = authority.lastIndex(of: ":"),
           let port = Int(authority[authority.index(after: colon)...]) {
            components.host = String(authority[..<colon])
            components.port = port
        } else {
            components.host = authority
        }
        components.path = "/device/\(trimmedToken)"
        return components.url
    }

    /// 拼外部 AI 连接地址：`https://<host>/mcp/<token>`（纯字符串，不经过
    /// URLComponents——token 是 base64url 字符集，本身 URL-safe）。
    /// 对应 worker.js 的 `POST /mcp/<token>`：外部 AI 的 MCP 设置里填的
    /// 就是这一串。host / token 任一缺失返回 nil。
    static func externalMcpURLString(host rawHost: String, token: String) -> String? {
        guard let authority = normalizedHost(rawHost) else { return nil }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return nil }
        return "https://\(authority)/mcp/\(trimmedToken)"
    }

    /// 仅供日志与界面提示的脱敏 host：只露头部与尾部域名，中段打码。
    /// 口令永远不经过这个函数、也不会出现在任何展示里。
    static func maskedHost(_ raw: String) -> String {
        guard let host = normalizedHost(raw) else { return "—" }
        guard host.count > 10 else { return "••••" }
        return "\(host.prefix(3))••••\(host.suffix(7))"
    }
}
