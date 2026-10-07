import Foundation

/// 一个请求头键值对（服务商自定义请求头用）。
public struct HeaderField: Sendable, Equatable, Codable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// 密钥池里的一把密钥。`secret` 只在内存与钥匙串里流转，不进日志。
/// `cooldownUntil` 是运行态（失败冷却到何时），由密钥池维护。
public struct ProviderKey: Sendable, Equatable {
    public var id: UUID
    public var secret: String
    public var isEnabled: Bool
    public var cooldownUntil: Date?

    public init(
        id: UUID = UUID(), secret: String, isEnabled: Bool = true, cooldownUntil: Date? = nil
    ) {
        self.id = id
        self.secret = secret
        self.isEnabled = isEnabled
        self.cooldownUntil = cooldownUntil
    }
}

/// 服务商配置——设计借鉴 Kelivo 的配置模型（代码全原创，Kelivo 是 AGPL，只学设计）：
/// 地址 / 密钥 / 模型三者解耦；密钥成池轮换；自定义请求头（键值对列表）与
/// 自定义请求体（原始 JSON 串）分开存，请求体填错必须能定位到字符位置报错。
public struct ProviderConfiguration: Sendable, Equatable {
    public var id: UUID
    /// 显示名。
    public var name: String
    /// OpenAI 兼容接口的 BaseURL，如 https://api.example.com/v1
    public var baseURL: String
    /// 模型名，与地址、密钥解耦，单独可改。
    public var model: String
    public var keys: [ProviderKey]
    public var customHeaders: [HeaderField]
    /// 自定义请求体（原始 JSON 字符串）；与桥组装的字段合并时，桥的字段优先。
    public var customBodyJSON: String?
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        model: String,
        keys: [ProviderKey] = [],
        customHeaders: [HeaderField] = [],
        customBodyJSON: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.keys = keys
        self.customHeaders = customHeaders
        self.customBodyJSON = customBodyJSON
        self.isEnabled = isEnabled
    }

    /// 严格校验 BaseURL：`URL(string:)` 对坏输入过于宽容（任务书 §7），
    /// 必须逐项查 scheme 与 host。
    public func validatedBaseURL() throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host, !host.isEmpty
        else {
            throw ProviderError.invalidBaseURL(baseURL)
        }
        return url
    }

    /// 拼接口路径：去掉 BaseURL 尾部斜杠后接 /<path>。
    public func endpointURL(_ path: String) throws -> URL {
        let base = try validatedBaseURL()
        var string = base.absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        return URL(string: string + "/" + path)!
    }
}
