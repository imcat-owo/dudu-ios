import Foundation

/// 结果清洗器：把工具的原始输出压成高密度结果再回给外部 AI。
///
/// 清洗是独立组件，每条规则都是单独的公开函数、单独可测：
/// 1. `stripControlSequences` 去 ANSI 转义与控制字符（保留换行/制表符）；
/// 2. `collapseRepeatedLines` 折叠连续重复行（进度条刷屏），标注重复次数；
/// 3. `filterJSONKeys` 整段是 JSON 时只保留关键字段；
/// 4. `truncateHeadTail` 超长时留头留尾，标明截断字数。
/// `clean(_:)` 按此顺序串起四步。清洗只做格式压缩，不改语义、不吞错误——
/// 错误文本原样穿过这条流水线（除控制字符外）。
public struct ResultCleaner: Sendable {
    public struct Configuration: Sendable {
        /// 清洗后允许的最长字符数（按 Character 计）。
        public var maxLength: Int
        /// JSON 过滤时保留的键集合。
        public var jsonKeepKeys: Set<String>

        public init(maxLength: Int = 4000, jsonKeepKeys: Set<String> = Self.defaultJSONKeepKeys) {
            self.maxLength = maxLength
            self.jsonKeepKeys = jsonKeepKeys
        }

        public static let defaultJSONKeepKeys: Set<String> = [
            "id", "name", "title", "status", "state", "ok", "success",
            "result", "error", "message", "summary", "text", "value",
            "url", "count", "total",
        ]
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// 四步流水线。
    public func clean(_ text: String) -> String {
        var result = stripControlSequences(text)
        result = collapseRepeatedLines(result)
        result = filterJSONKeys(result)
        result = truncateHeadTail(result)
        return result
    }

    // MARK: - 规则 1：去 ANSI 转义与控制字符

    /// 去掉 ANSI 转义序列（CSI / OSC / 字符集指定等）与 C0/C1 控制字符，
    /// 保留 `\n` 与 `\t`；`\r` 一并去掉（进度条回车覆写没有信息量）。
    public func stripControlSequences(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\u{1B}" {
                index = skipEscapeSequence(scalars, from: index)
                continue
            }
            if scalar == "\n" || scalar == "\t" {
                output.append(scalar)
                index += 1
                continue
            }
            if scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F) {
                index += 1
                continue
            }
            output.append(scalar)
            index += 1
        }
        var result = ""
        result.unicodeScalars.append(contentsOf: output)
        return result
    }

    /// 从 ESC 所在位置起跳过一整段转义序列，返回序列之后的位置。
    private func skipEscapeSequence(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start + 1
        guard index < scalars.count else { return index }
        let introducer = scalars[index]
        if introducer == "[" {
            // CSI：参数/中间字节 0x20–0x3F，终结字节 0x40–0x7E。
            index += 1
            while index < scalars.count {
                let value = scalars[index].value
                index += 1
                if value >= 0x40 && value <= 0x7E { break }
            }
            return index
        }
        if introducer == "]" {
            // OSC：以 BEL 或 ESC \ 结尾。
            index += 1
            while index < scalars.count {
                if scalars[index] == "\u{07}" {
                    return index + 1
                }
                if scalars[index] == "\u{1B}",
                    index + 1 < scalars.count, scalars[index + 1] == "\\"
                {
                    return index + 2
                }
                index += 1
            }
            return index
        }
        if introducer == "(" || introducer == ")" || introducer == "#" {
            // 字符集指定类：ESC + 引入符 + 1 个字节。
            return min(index + 2, scalars.count)
        }
        // 其余两字节转义：ESC + 1 个字节。
        return min(index + 1, scalars.count)
    }

    // MARK: - 规则 2：折叠连续重复行

    /// 连续完全相同的行只留一行；重复 ≥2 次时在行尾标注「（重复 N 次）」。
    /// 空行只折叠、不标注（空行计数没有信息量）。
    public func collapseRepeatedLines(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var output: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            var count = 1
            while index + count < lines.count, lines[index + count] == line {
                count += 1
            }
            if count > 1, !line.isEmpty {
                output.append("\(line)（重复 \(count) 次）")
            } else {
                output.append(String(line))
            }
            index += count
        }
        return output.joined(separator: "\n")
    }

    // MARK: - 规则 3：JSON 只留关键字段

    /// 整段文本（去首尾空白后）若是 JSON 对象或对象数组，只保留
    /// `jsonKeepKeys` 里的字段并以稳定键序重新序列化；
    /// 整段不是单一 JSON 时，逐行处理：独立成行的 JSON 对象/数组同样过滤。
    /// 不是 JSON、或过滤后会把对象掏空时，原样返回不做破坏。
    public func filterJSONKeys(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
            let whole = filterJSONValue(trimmed)
        {
            return whole
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var changed = false
        let processed = lines.map { line -> String in
            let lineTrimmed = line.trimmingCharacters(in: .whitespaces)
            guard lineTrimmed.hasPrefix("{") || lineTrimmed.hasPrefix("[") else {
                return String(line)
            }
            if let filteredLine = filterJSONValue(lineTrimmed) {
                changed = true
                return filteredLine
            }
            return String(line)
        }
        return changed ? processed.joined(separator: "\n") : text
    }

    /// 过滤一段独立 JSON 文本；不适用（非 JSON / 没删掉任何键 / 会把对象掏空）返回 nil。
    private func filterJSONValue(_ jsonText: String) -> String? {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8))
        else { return nil }

        var removedAny = false
        let filtered: Any
        if let dict = parsed as? [String: Any] {
            guard let kept = filterObject(dict, removedAny: &removedAny) else { return nil }
            filtered = kept
        } else if let array = parsed as? [Any] {
            var newArray: [Any] = []
            for element in array {
                if let dict = element as? [String: Any] {
                    // 数组里的对象若保留集合一个键都不命中，保留原对象而不是塞空壳。
                    if let kept = filterObject(dict, removedAny: &removedAny) {
                        newArray.append(kept)
                    } else {
                        newArray.append(dict)
                    }
                } else {
                    newArray.append(element)
                }
            }
            filtered = newArray
        } else {
            return nil
        }

        guard removedAny else { return nil }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: filtered, options: [.sortedKeys]),
            let serialized = String(data: data, encoding: .utf8)
        else { return nil }
        return serialized
    }

    /// 过滤单个对象；若对象非空但保留后变空，返回 nil 表示「不滤这个对象」。
    private func filterObject(_ dict: [String: Any], removedAny: inout Bool) -> [String: Any]? {
        let kept = dict.filter { configuration.jsonKeepKeys.contains($0.key) }
        if kept.isEmpty, !dict.isEmpty { return nil }
        if kept.count != dict.count { removedAny = true }
        return kept
    }

    // MARK: - 规则 4：超长留头留尾

    /// 超过 `maxLength` 时保留头部 2/3、尾部 1/3，中间以
    /// 「…（中间已截断 N 字符）…」标注，标注计入总长度预算，结果不超限。
    public func truncateHeadTail(_ text: String) -> String {
        let total = text.count
        let budget = configuration.maxLength
        guard total > budget else { return text }

        // 标注里的数字位数会影响可用长度，迭代到位数稳定（至多几轮必收敛）。
        var assumedRemovedDigits = String(total).count
        for _ in 0..<4 {
            let markerProbe = "…（中间已截断 \(String(repeating: "0", count: assumedRemovedDigits)) 字符）…"
            let keep = budget - markerProbe.count
            guard keep > 0 else {
                // 预算小到连标注都放不下：硬截断保底，不输出超限文本。
                return String(text.prefix(budget))
            }
            let headCount = keep * 2 / 3
            let tailCount = keep - headCount
            let removed = total - headCount - tailCount
            if String(removed).count == assumedRemovedDigits {
                let marker = "…（中间已截断 \(removed) 字符）…"
                let head = text.prefix(headCount)
                let tail = text.suffix(tailCount)
                return String(head) + marker + String(tail)
            }
            assumedRemovedDigits = String(removed).count
        }
        return String(text.prefix(budget))
    }
}
