//
//  SharedEventLog.swift
//  MinisApp
//
//  Cross-session shared event log (merge sting-3).
//
//  Whenever the agent changes config in-dialog (minis-config approved writes)
//  or a heavy tool finishes, one JSON object is appended to
//  /var/minis/shared/events.jsonl (host: AIChatViewModel.minisSharedPersistentDir),
//  so ANY session can read what other sessions did:
//
//      {"ts":"2026-10-01T04:20:11+08:00","event":"config.changed","session":"a1b2c3","summary":"minis-config: ..."}
//
//  Safety properties:
//  - Appends are serialized across processes with flock() on a sidecar lock
//    file; the log itself is opened O_APPEND, so concurrent writers can't
//    interleave or truncate each other.
//  - Secrets never reach the file: summaries are passed through redact()
//    (key/token/secret/password patterns and data: URIs are masked), and
//    emitters must pass already-masked display values.
//  - The file is rotated: past 2MB it is trimmed to the last ~1MB on a line
//    boundary, under the same lock.
//

import Foundation
import Darwin

final class SharedEventLog {
    static let shared = SharedEventLog()

    /// Heavy tools whose completion is worth announcing to other sessions.
    /// Anything else is announced only when it runs >= heavyDurationThreshold.
    static let heavyToolNames: Set<String> = [
        "shell_execute", "browser_use", "minis-model-use",
        "apple-player", "minis-sessions-cli",
    ]
    static let heavyDurationThreshold: Double = 30

    private let queue = DispatchQueue(label: "minis.shared-event-log", qos: .utility)

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let secretPattern: NSRegularExpression? = {
        // key = value / "key": "value" — mask the value, keep the key name.
        // The value swallows an optional second token so
        // "Authorization: Bearer <token>" is fully masked.
        // 中文键（口令/密码/密钥，AI-P2-8）：\b 在中文字符间没有词边界，
        // 所以中文分支不用 \b；分隔符认全角冒号和"是"（"密码是 xxx"）。
        // 两个分支的键分别进 $1/$3，模板 "$1$3=***REDACTED***" 两边都成立。
        try? NSRegularExpression(
            pattern: #"(?i)\b(api[_-]?key|secret|token|password|passwd|pwd|authorization|bearer|client[_-]?secret)\b(?=["']?\s*[:=])["']?\s*[:=]\s*("[^"]*"|'[^']*'|\S+(?:\s+\S+)?)|(口令|密码|密钥)(?=["']?\s*(?:[:：=]|是))["']?\s*(?:[:：=]|是)\s*("[^"]*"|'[^']*'|\S+(?:\s+\S+)?)"#)
    }()

    private static let dataURIPattern: NSRegularExpression? = {
        // Embedded images / long base64 blobs are never useful in a summary.
        try? NSRegularExpression(pattern: #"data:[A-Za-z0-9/+\-]+;base64,[A-Za-z0-9+/=]{64,}"#)
    }()

    private static let bareURLPattern: NSRegularExpression? = {
        // 裸 http(s) 网址：日志片段会进公开的 GitHub Issue，带 token 的
        // 查询串一旦落盘就等于公开，AI-P1-2 起一律遮掉。
        try? NSRegularExpression(
            pattern: "https?://[^\\s)\"<>\\]]+",
            options: [.caseInsensitive])
    }()

    private var logURL: URL {
        AIChatViewModel.minisSharedPersistentDir
            .appendingPathComponent("events.jsonl", isDirectory: false)
    }

    private var lockURL: URL {
        AIChatViewModel.minisSharedPersistentDir
            .appendingPathComponent("events.lock", isDirectory: false)
    }

    /// Fire-and-forget. Safe to call from any thread; the write happens on a
    /// private serial queue. `summary` is redacted before writing.
    func emit(event: String, summary: String, sessionId: String? = nil) {
        let name = event.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let cleanSummary = Self.redact(summary)
        let sid = sessionId
        queue.async { [weak self] in
            self?.appendLine(event: name, summary: cleanSummary, sessionId: sid)
        }
    }

    // MARK: - reading (merge s21: report_issue 附上下文用)

    /// 最近 `limit` 条、且在 `within` 时间窗口内（默认 1 小时）的事件，
    /// 格式化成 "[时间] 事件名 @会话 — 摘要" 文本行（保持日志原有先后顺序）。
    /// 读不到文件返回空数组。时间戳解析失败的老行不丢（解析失败不等于过期）。
    /// 走同一条串行队列读，与写入互斥，不会读到写一半的行；
    /// 日记内容落盘时已脱敏，这里只做格式化、不再加工原文。
    func recentEntries(limit: Int = 20, within: TimeInterval = 3600) -> [String] {
        queue.sync { readRecentEntries(limit: limit, within: within) }
    }

    private func readRecentEntries(limit: Int, within: TimeInterval) -> [String] {
        guard limit > 0,
              let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let cutoff = Date().addingTimeInterval(-within)
        return text.split(separator: "\n").suffix(limit).compactMap { line in
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let ts = obj["ts"] as? String,
                  let event = obj["event"] as? String else { return nil }
            // 时间窗口：窗口外的条目不要；时间戳解析失败的老行保留。
            if let date = Self.iso.date(from: ts), date < cutoff { return nil }
            let summary = obj["summary"] as? String ?? ""
            // session 字段是跨会话排障的线索，格式化时保留。
            let who: String
            if let session = obj["session"] as? String, !session.isEmpty {
                who = " @\(session)"
            } else {
                who = ""
            }
            return "[\(ts)] \(event)\(who) — \(summary)"
        }
    }

    // MARK: - redaction

    static func redact(_ s: String) -> String {
        // Fail closed: if the patterns somehow didn't compile, the summary
        // is useless rather than a secret leak.
        guard let dataURIPattern, let secretPattern, let bareURLPattern else { return "<redacted>" }
        var out = s
        var range = NSRange(out.startIndex..., in: out)
        out = dataURIPattern.stringByReplacingMatches(
            in: out, range: range, withTemplate: "<image>")
        range = NSRange(out.startIndex..., in: out)
        out = secretPattern.stringByReplacingMatches(
            in: out, range: range, withTemplate: "$1$3=***REDACTED***")
        range = NSRange(out.startIndex..., in: out)
        out = bareURLPattern.stringByReplacingMatches(
            in: out, range: range, withTemplate: "<url>")
        return out
    }

    // MARK: - writing (runs on `queue`)

    private func appendLine(event: String, summary: String, sessionId: String?) {
        let dir = AIChatViewModel.minisSharedPersistentDir
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        } catch {
            return // best effort — never crash the caller over a log line
        }

        let lockFd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard lockFd >= 0 else { return }
        defer { close(lockFd) }
        guard flock(lockFd, LOCK_EX) == 0 else { return }
        defer { flock(lockFd, LOCK_UN) }

        rotateIfNeededLocked()

        var obj: [String: Any] = [
            "ts": Self.iso.string(from: Date()),
            "event": event,
            "summary": String(summary.prefix(500)),
        ]
        if let sid = sessionId, !sid.isEmpty {
            obj["session"] = String(sid.prefix(16))
        }
        guard let json = try? JSONSerialization.data(withJSONObject: obj),
              let body = String(data: json, encoding: .utf8),
              let bytes = (body + "\n").data(using: .utf8) else { return }
        let fd = open(logURL.path, O_CREAT | O_WRONLY | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        bytes.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                _ = write(fd, base, bytes.count)
            }
        }
    }

    /// Must be called with the lock held. Trims the log to ~1MB when it
    /// grows past 2MB, cutting on a line boundary.
    private func rotateIfNeededLocked() {
        let maxBytes = 2 * 1024 * 1024
        let keepBytes = 1 * 1024 * 1024
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? Int,
              size > maxBytes,
              let data = try? Data(contentsOf: logURL),
              data.count > keepBytes else { return }
        let tail = data.suffix(keepBytes)
        var start = tail.startIndex
        if let nl = tail.firstIndex(of: UInt8(ascii: "\n")) {
            start = tail.index(after: nl)
        }
        try? tail[start...].write(to: logURL, options: .atomic)
    }
}
