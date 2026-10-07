import Foundation

#if canImport(CoreFoundation)
    import CoreFoundation
#endif

/// 严格 JSON 边界的错误。解析失败时把解析器原始信息带出来，不吞、不包装成空话。
public enum StrictJSONError: Error, Equatable, CustomStringConvertible {
    /// 底层 JSONSerialization 报错（附原始 localizedDescription）。
    case invalidJSON(String)
    /// 顶层不是 JSON 对象。
    case topLevelNotObject(actual: String)
    /// 必填键缺失。
    case missingKey(String)
    /// 键存在但类型不对（附期望与实际类型名）。
    case typeMismatch(key: String, expected: String, actual: String)

    public var description: String {
        switch self {
        case .invalidJSON(let detail):
            return "JSON 解析失败：\(detail)"
        case .topLevelNotObject(let actual):
            return "JSON 顶层必须是对象，实际是 \(actual)"
        case .missingKey(let key):
            return "缺少必填字段：\(key)"
        case .typeMismatch(let key, let expected, let actual):
            return "字段 \(key) 类型不对：期望 \(expected)，实际是 \(actual)"
        }
    }
}

/// `JSONSerialization` 产出的 JSON 对象包装，提供严格类型读取。
///
/// 严格的含义（任务书 §7 的坑）：JSON 数字绝不许被宽松地读成布尔，布尔也不许
/// 被读成数字。这里用 `CFGetTypeID` 区分 `__NSCFBoolean` / `__NSCFNumber`，
/// 并以 NSNumber 的 objCType 作为跨平台兜底判据（swift-corelibs-foundation
/// 的 CF 桥接对布尔后备 NSNumber 的返回与 Darwin 不完全一致；JSON 来源的
/// NSNumber 只有布尔会带 "c" 编码，整数是 "q"、浮点是 "d"，不会撞）。
///
/// 标记 `@unchecked Sendable`：内部字典来自 JSONSerialization 且解析后从不
/// 修改，按不可变数据在并发域间传递。
public struct StrictJSONObject: @unchecked Sendable {
    public let raw: [String: Any]

    public init(raw: [String: Any]) {
        self.raw = raw
    }

    public var keys: [String] { Array(raw.keys) }

    public func contains(_ key: String) -> Bool {
        raw[key] != nil
    }

    public func value(_ key: String) -> Any? {
        raw[key]
    }

    /// 严格字符串：只有真正的 JSON 字符串才返回，数字/布尔不许冒充。
    public func string(_ key: String) -> String? {
        guard let value = raw[key] else { return nil }
        return value as? String
    }

    public func requireString(_ key: String) throws -> String {
        guard let value = raw[key] else { throw StrictJSONError.missingKey(key) }
        guard let string = value as? String else {
            throw StrictJSONError.typeMismatch(
                key: key, expected: "字符串", actual: StrictJSON.typeName(of: value))
        }
        return string
    }

    /// 严格布尔：只有 JSON 的 true/false 才算，数字 0/1 不算。
    public func bool(_ key: String) -> Bool? {
        guard let value = raw[key], StrictJSON.isBoolean(value) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    public func requireBool(_ key: String) throws -> Bool {
        guard let value = raw[key] else { throw StrictJSONError.missingKey(key) }
        guard let bool = bool(key) else {
            throw StrictJSONError.typeMismatch(
                key: key, expected: "布尔", actual: StrictJSON.typeName(of: value))
        }
        return bool
    }

    /// 严格整数：只有 JSON 数字、且没有小数部分才算；布尔不算。
    public func int(_ key: String) -> Int? {
        guard let value = raw[key], StrictJSON.isNumber(value),
            let number = value as? NSNumber
        else { return nil }
        let double = number.doubleValue
        guard double == double.rounded(), abs(double) < 9.0e15 else { return nil }
        return number.intValue
    }

    public func requireInt(_ key: String) throws -> Int {
        guard let value = raw[key] else { throw StrictJSONError.missingKey(key) }
        guard let int = int(key) else {
            throw StrictJSONError.typeMismatch(
                key: key, expected: "整数", actual: StrictJSON.typeName(of: value))
        }
        return int
    }

    /// 严格浮点：JSON 数字（整数也算）才返回；布尔不算。
    public func double(_ key: String) -> Double? {
        guard let value = raw[key], StrictJSON.isNumber(value),
            let number = value as? NSNumber
        else { return nil }
        return number.doubleValue
    }

    public func object(_ key: String) -> StrictJSONObject? {
        guard let dict = raw[key] as? [String: Any] else { return nil }
        return StrictJSONObject(raw: dict)
    }

    public func requireObject(_ key: String) throws -> StrictJSONObject {
        guard let value = raw[key] else { throw StrictJSONError.missingKey(key) }
        guard let object = object(key) else {
            throw StrictJSONError.typeMismatch(
                key: key, expected: "对象", actual: StrictJSON.typeName(of: value))
        }
        return object
    }

    public func array(_ key: String) -> [Any]? {
        raw[key] as? [Any]
    }
}

/// 严格 JSON 解析工具：桥的元工具入参、外部配置等需要严判类型的边界统一走这里，
/// 不信任任何宽松解码路径。
public enum StrictJSON {
    /// 解析 Data 为顶层对象。
    ///
    /// 先按首个非空白字节预检顶层形状再调 JSONSerialization：一是任务书 §7
    /// 要求「先守卫顶层再使用」，二是顶层碎片在各平台 JSONSerialization
    /// 上的行为不一致（有的返回碎片、有的抛错），预检让本函数的行为
    /// 在所有平台完全一致。
    public static func parseObject(_ data: Data) throws -> StrictJSONObject {
        var bytes = [UInt8](data)
        // 剥掉 UTF-8 BOM，避免它干扰首字节判断。
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            bytes.removeFirst(3)
        }
        guard
            let first = bytes.first(where: {
                $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D
            })
        else {
            throw StrictJSONError.invalidJSON("空数据")
        }
        guard first == 0x7B else {  // {
            throw StrictJSONError.topLevelNotObject(actual: topLevelName(firstByte: first))
        }
        let rawValue: Any
        do {
            rawValue = try JSONSerialization.jsonObject(with: Data(bytes))
        } catch {
            throw StrictJSONError.invalidJSON(error.localizedDescription)
        }
        guard let dict = rawValue as? [String: Any] else {
            throw StrictJSONError.topLevelNotObject(actual: typeName(of: rawValue))
        }
        return StrictJSONObject(raw: dict)
    }

    private static func topLevelName(firstByte: UInt8) -> String {
        switch firstByte {
        case 0x5B: return "数组"  // [
        case 0x22: return "字符串"  // "
        case 0x74, 0x66: return "布尔"  // t / f
        case 0x6E: return "null"  // n
        case 0x2D, 0x30...0x39: return "数字"  // - / 0-9
        default: return "无法识别的内容"
        }
    }

    public static func parseObject(_ text: String) throws -> StrictJSONObject {
        try parseObject(Data(text.utf8))
    }

    /// 把对象序列化回 Data（键排序，输出稳定，便于比对与测试）。
    public static func data(from object: StrictJSONObject) throws -> Data {
        do {
            return try JSONSerialization.data(
                withJSONObject: object.raw, options: [.sortedKeys])
        } catch {
            throw StrictJSONError.invalidJSON(error.localizedDescription)
        }
    }

    /// 该值是不是 JSON 布尔。
    public static func isBoolean(_ value: Any) -> Bool {
        #if canImport(CoreFoundation)
            if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
                return true
            }
        #endif
        if let number = value as? NSNumber {
            return String(cString: number.objCType) == "c"
        }
        return false
    }

    /// 该值是不是 JSON 数字（布尔明确排除）。
    public static func isNumber(_ value: Any) -> Bool {
        guard !isBoolean(value) else { return false }
        #if canImport(CoreFoundation)
            if CFGetTypeID(value as CFTypeRef) == CFNumberGetTypeID() {
                return true
            }
        #endif
        return value is NSNumber
    }

    /// 人类可读的类型名，进错误信息用。
    public static func typeName(of value: Any) -> String {
        if value is NSNull { return "null" }
        if isBoolean(value) { return "布尔" }
        if isNumber(value) { return "数字" }
        if value is String { return "字符串" }
        if value is [String: Any] { return "对象" }
        if value is [Any] { return "数组" }
        return String(describing: type(of: value))
    }

    /// 定位一段文本里第一个 JSON 语法错误的位置（Unicode 标量偏移）。
    /// 语法完全合法返回 nil。给用户填错自定义请求体时报位置用，
    /// 不依赖各平台 JSONSerialization 错误文案的差异。
    public static func firstSyntaxErrorOffset(_ text: String) -> Int? {
        var scanner = JSONSyntaxScanner(scalars: Array(text.unicodeScalars))
        return scanner.validateDocument()
    }
}

/// 最小递归下降 JSON 语法扫描器，只判语法与错误位置，不产出值。
private struct JSONSyntaxScanner {
    let scalars: [Unicode.Scalar]
    var position = 0
    var errorOffset: Int?

    var atEnd: Bool { position >= scalars.count }

    mutating func validateDocument() -> Int? {
        skipWhitespace()
        guard parseValue() else { return errorOffset ?? position }
        skipWhitespace()
        guard atEnd else { return position }
        return nil
    }

    private func peek() -> Unicode.Scalar? {
        atEnd ? nil : scalars[position]
    }

    private mutating func fail() -> Bool {
        errorOffset = position
        return false
    }

    mutating func skipWhitespace() {
        while let scalar = peek(),
            scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
        {
            position += 1
        }
    }

    mutating func parseValue() -> Bool {
        guard let scalar = peek() else { return fail() }
        switch scalar {
        case "{": return parseObject()
        case "[": return parseArray()
        case "\"": return parseString()
        case "t": return parseLiteral("true")
        case "f": return parseLiteral("false")
        case "n": return parseLiteral("null")
        case "-", "0"..."9": return parseNumber()
        default: return fail()
        }
    }

    mutating func parseObject() -> Bool {
        position += 1  // {
        skipWhitespace()
        if peek() == "}" {
            position += 1
            return true
        }
        while true {
            skipWhitespace()
            guard peek() == "\"" else { return fail() }
            guard parseString() else { return false }
            skipWhitespace()
            guard peek() == ":" else { return fail() }
            position += 1
            skipWhitespace()
            guard parseValue() else { return false }
            skipWhitespace()
            if peek() == "," {
                position += 1
                continue
            }
            if peek() == "}" {
                position += 1
                return true
            }
            return fail()
        }
    }

    mutating func parseArray() -> Bool {
        position += 1  // [
        skipWhitespace()
        if peek() == "]" {
            position += 1
            return true
        }
        while true {
            skipWhitespace()
            guard parseValue() else { return false }
            skipWhitespace()
            if peek() == "," {
                position += 1
                continue
            }
            if peek() == "]" {
                position += 1
                return true
            }
            return fail()
        }
    }

    mutating func parseString() -> Bool {
        position += 1  // 开引号
        while let scalar = peek() {
            if scalar == "\"" {
                position += 1
                return true
            }
            if scalar == "\\" {
                position += 1
                guard let escaped = peek() else { return fail() }
                if escaped == "u" {
                    position += 1
                    for _ in 0..<4 {
                        guard let hex = peek(), hex.properties.isASCIIHexDigit else {
                            return fail()
                        }
                        position += 1
                    }
                } else if "\"\\/bfnrt".unicodeScalars.contains(escaped) {
                    position += 1
                } else {
                    return fail()
                }
                continue
            }
            if scalar.value < 0x20 {
                return fail()
            }
            position += 1
        }
        return fail()
    }

    mutating func parseNumber() -> Bool {
        if peek() == "-" {
            position += 1
        }
        guard let first = peek() else { return fail() }
        if first == "0" {
            position += 1
        } else if first >= "1", first <= "9" {
            while let scalar = peek(), scalar >= "0", scalar <= "9" {
                position += 1
            }
        } else {
            return fail()
        }
        if peek() == "." {
            position += 1
            guard let scalar = peek(), scalar >= "0", scalar <= "9" else { return fail() }
            while let scalar = peek(), scalar >= "0", scalar <= "9" {
                position += 1
            }
        }
        if let scalar = peek(), scalar == "e" || scalar == "E" {
            position += 1
            if let sign = peek(), sign == "+" || sign == "-" {
                position += 1
            }
            guard let scalar = peek(), scalar >= "0", scalar <= "9" else { return fail() }
            while let scalar = peek(), scalar >= "0", scalar <= "9" {
                position += 1
            }
        }
        return true
    }

    mutating func parseLiteral(_ literal: String) -> Bool {
        for expected in literal.unicodeScalars {
            guard peek() == expected else { return fail() }
            position += 1
        }
        return true
    }
}
