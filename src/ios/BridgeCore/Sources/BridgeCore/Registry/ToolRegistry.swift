import Foundation

/// 工具权限等级。敏感级（发邮件、删数据这类）默认不执行，
/// 必须经主人确认（调度层带确认标记）才放行——定稿的安全规矩。
public enum ToolPermission: String, Sendable, Codable {
    case standard
    case sensitive
}

/// 工具执行产出。失败也走这个结构回（isError = true），文本保留错误原文关键信息。
public struct ToolOutput: Sendable, Equatable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// 工具处理函数。入参是严格解析后的 JSON 对象；可以抛错，
/// 调度层会把错误描述原文带回，绝不吞。
public typealias ToolHandler = @Sendable (StrictJSONObject) async throws -> ToolOutput

/// 工具声明：注册进注册中心的元信息。
public struct ToolDescriptor: Sendable, Equatable {
    /// 唯一名（调度与点名执行用）。
    public var name: String
    /// 一句话简介——「搜」返回给外部 AI 的就是它，必须短、说清能干什么。
    public var summary: String
    /// 详细说明（参数含义、何时该用）。
    public var detail: String
    /// 搜索关键词（中英文都放，提高命中）。
    public var keywords: [String]
    /// 参数 JSON Schema 原文。注册时严格校验必须是合法 JSON 对象。
    public var parameterSchemaJSON: String
    public var permission: ToolPermission
    public var isEnabled: Bool

    public init(
        name: String,
        summary: String,
        detail: String = "",
        keywords: [String] = [],
        parameterSchemaJSON: String = #"{"type":"object"}"#,
        permission: ToolPermission? = nil,
        isEnabled: Bool = true
    ) {
        self.name = name
        self.summary = summary
        self.detail = detail
        self.keywords = keywords
        self.parameterSchemaJSON = parameterSchemaJSON
        self.permission = permission ?? Self.defaultPermission(for: name)
        self.isEnabled = isEnabled
    }

    /// 未显式声明权限时的兜底：名字里带 bluetooth 的默认敏感级，
    /// 其余保持标准级。蓝牙能扫描附近设备并连接读写，漏声明时也不该直接放行。
    private static func defaultPermission(for name: String) -> ToolPermission {
        name.lowercased().contains("bluetooth") ? .sensitive : .standard
    }
}

/// 一次搜索命中：名字＋一句话简介＋参数简述（AI-P1-6 起，外部 AI
/// 不用多问一轮就能知道参数怎么传）。参数简述保持短，不倒完整 schema。
public struct ToolSearchHit: Sendable, Equatable {
    public var name: String
    public var summary: String
    public var score: Int
    /// 如 "title(字符串,必填)、detail(字符串)"；解析不出时为空。
    public var parameterBrief: String

    public init(name: String, summary: String, score: Int, parameterBrief: String = "") {
        self.name = name
        self.summary = summary
        self.score = score
        self.parameterBrief = parameterBrief
    }
}

public enum ToolRegistryError: Error, Equatable, CustomStringConvertible {
    case duplicateName(String)
    case invalidDescriptor(tool: String, detail: String)
    case notFound(String)
    case disabled(String)

    public var description: String {
        switch self {
        case .duplicateName(let name):
            return "工具名重复注册：\(name)"
        case .invalidDescriptor(let tool, let detail):
            return "工具 \(tool) 的声明不合法：\(detail)"
        case .notFound(let name):
            return "工具不存在：\(name)"
        case .disabled(let name):
            return "工具已停用：\(name)"
        }
    }
}

/// 工具注册中心：声明、注册/注销、关键词搜索、启用开关、按名调用。
///
/// 桥内部所有能力（本地工具、将来挂载的外部 MCP 工具）都先注册到这里，
/// 对外只经「搜」与「命令」两个元工具露出。
public actor ToolRegistry {
    private struct Entry {
        var descriptor: ToolDescriptor
        var handler: ToolHandler
    }

    private var entries: [String: Entry] = [:]
    private var registrationOrder: [String] = []

    public init() {}

    /// 注册工具。名字重复、简介为空、参数 Schema 不是合法 JSON 对象时抛错。
    public func register(descriptor: ToolDescriptor, handler: @escaping ToolHandler) throws {
        guard entries[descriptor.name] == nil else {
            throw ToolRegistryError.duplicateName(descriptor.name)
        }
        guard !descriptor.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolRegistryError.invalidDescriptor(tool: descriptor.name, detail: "名字为空")
        }
        guard !descriptor.summary.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolRegistryError.invalidDescriptor(tool: descriptor.name, detail: "简介为空")
        }
        do {
            _ = try StrictJSON.parseObject(descriptor.parameterSchemaJSON)
        } catch {
            throw ToolRegistryError.invalidDescriptor(
                tool: descriptor.name, detail: "参数 Schema 不是合法 JSON 对象：\(error)")
        }
        entries[descriptor.name] = Entry(descriptor: descriptor, handler: handler)
        registrationOrder.append(descriptor.name)
    }

    /// 注销工具。返回是否确实删掉了一个。
    @discardableResult
    public func unregister(name: String) -> Bool {
        guard entries.removeValue(forKey: name) != nil else { return false }
        registrationOrder.removeAll { $0 == name }
        return true
    }

    /// 启用/停用开关。停用的工具不出现在搜索里、也不能被调用。
    public func setEnabled(_ enabled: Bool, for name: String) throws {
        guard var entry = entries[name] else {
            throw ToolRegistryError.notFound(name)
        }
        entry.descriptor.isEnabled = enabled
        entries[name] = entry
    }

    public func descriptor(for name: String) -> ToolDescriptor? {
        entries[name]?.descriptor
    }

    /// 全部声明，按注册顺序（稳定输出，方便界面与测试）。
    public func allDescriptors() -> [ToolDescriptor] {
        registrationOrder.compactMap { entries[$0]?.descriptor }
    }

    /// 关键词搜索。计分：命中名字 3 分、命中关键词 2 分、命中简介/详情 1 分，
    /// 多词累加；只回得分 > 0 的，按分数降序、同分按名字升序（结果稳定）。
    /// 默认只搜启用中的工具。
    public func search(
        _ query: String, limit: Int = 8, includeDisabled: Bool = false
    ) -> [ToolSearchHit] {
        let tokens = Self.searchTokens(from: query)
        guard !tokens.isEmpty else { return [] }
        var hits: [ToolSearchHit] = []
        for name in registrationOrder {
            guard let entry = entries[name] else { continue }
            let descriptor = entry.descriptor
            if !descriptor.isEnabled, !includeDisabled { continue }
            var score = 0
            let lowerName = descriptor.name.lowercased()
            let lowerKeywords = descriptor.keywords.map { $0.lowercased() }
            let lowerSummary = descriptor.summary.lowercased()
            let lowerDetail = descriptor.detail.lowercased()
            for token in tokens {
                if lowerName == token || lowerName.contains(token) {
                    score += 3
                }
                if lowerKeywords.contains(where: { $0 == token || $0.contains(token) || token.contains($0) }) {
                    score += 2
                }
                if lowerSummary.contains(token) || lowerDetail.contains(token) {
                    score += 1
                }
            }
            if score > 0 {
                hits.append(
                    ToolSearchHit(
                        name: descriptor.name,
                        summary: descriptor.summary,
                        score: score,
                        parameterBrief: Self.parameterBrief(from: descriptor.parameterSchemaJSON)))
            }
        }
        hits.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.name < $1.name
        }
        return Array(hits.prefix(limit))
    }

    /// 按名调用。工具不存在/已停用抛错；工具自己抛的错原样向上抛。
    public func invoke(name: String, arguments: StrictJSONObject) async throws -> ToolOutput {
        guard let entry = entries[name] else {
            throw ToolRegistryError.notFound(name)
        }
        guard entry.descriptor.isEnabled else {
            throw ToolRegistryError.disabled(name)
        }
        return try await entry.handler(arguments)
    }

    /// 查询切词：按空白与常见标点切，同时把整串作为一个词参与匹配。
    private static func searchTokens(from query: String) -> [String] {
        let lowered = query.lowercased()
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "，,。、；;：:／/"))
        let parts =
            lowered
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var tokens = parts
        let whole = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
        if !whole.isEmpty, !tokens.contains(whole) {
            tokens.append(whole)
        }
        return tokens
    }

    /// 从参数 JSON Schema 里抽"参数名(类型,必填)"简述，如
    /// "title(字符串,必填)、detail(字符串)"。保持短：最多 6 个参数、
    /// 总长超 120 字截断。解析失败返回 ""，不让坏 schema 污染搜索结果。
    private static func parameterBrief(from schemaJSON: String) -> String {
        guard let data = schemaJSON.data(using: .utf8),
              let root = try? StrictJSON.parseObject(data),
              let properties = root.object("properties") else { return "" }
        let requiredSet = Set(root.array("required")?.compactMap { $0 as? String } ?? [])
        var parts: [String] = []
        for key in properties.keys.sorted() {
            guard let prop = properties.object(key) else { continue }
            let type = prop.string("type").map(Self.shortTypeName) ?? "?"
            let req = requiredSet.contains(key) ? ",必填" : ""
            parts.append("\(key)(\(type)\(req))")
            if parts.count >= 6 || parts.joined(separator: "、").count > 120 { break }
        }
        return parts.joined(separator: "、")
    }

    private static func shortTypeName(_ jsonType: String) -> String {
        switch jsonType {
        case "string": return "字符串"
        case "number": return "数字"
        case "integer": return "整数"
        case "boolean": return "布尔"
        case "object": return "对象"
        case "array": return "数组"
        default: return jsonType
        }
    }
}
