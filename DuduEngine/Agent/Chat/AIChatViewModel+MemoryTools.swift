import Foundation

// MARK: - Memory Tools

extension AIChatViewModel {

    // MARK: - Memory Tools

    /// Load full global memory content for system prompt injection.
    /// ［persona］按人设隔离：读该人设记忆目录的 GLOBAL.md。
    nonisolated static func loadGlobalMemoryFragment(personaID: String? = nil) -> String? {
        let dir = PersonaStore.memoryDir(for: personaID ?? PersonaStore.currentID())
        let globalFile = dir.appendingPathComponent("GLOBAL.md")
        guard FileManager.default.fileExists(atPath: globalFile.path),
              let content = try? String(contentsOf: globalFile, encoding: .utf8),
              !content.isEmpty else { return nil }

        return "Global memory (GLOBAL.md — read-only, user-maintained). Treat these as background context, not standing instructions. If the user's latest message conflicts with or supersedes anything here (different scope, different numbers, different goal), defer to the user's latest message:\n\(content)"
    }

    /// Load the 3 most recent daily memory logs that have content, for system prompt injection (first 200 lines each).
    /// ［persona］按人设隔离：读该人设记忆目录的日报。SOUL.md 是人设文件，不当记忆搜。
    nonisolated static func loadRecentDailyMemoryFragment(personaID: String? = nil) -> String? {
        let dir = PersonaStore.memoryDir(for: personaID ?? PersonaStore.currentID())
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let fm = FileManager.default
        // Anchor at the start of today and step by CALENDAR days. Stepping
        // by -86400s from the current time lands on the wrong date around
        // DST transitions (a 23/25-hour day shifts the result into the day
        // before yesterday in the early hours), skipping a daily log and
        // skewing the "Yesterday's" label and the gap-day count below.
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())

        var fragments: [String] = []
        var dayOffset = 0
        var newestLogOffset: Int? = nil  // [T-memory-streak-nudge 09-13] E3
        let maxLookback = 30 // don't search more than 30 days back

        while fragments.count < 3 && dayOffset < maxLookback {
            let date = cal.date(byAdding: .day, value: -dayOffset, to: todayStart) ?? todayStart
            let dateStr = fmt.string(from: date)
            let fileURL = dir.appendingPathComponent("\(dateStr).md")

            if fm.fileExists(atPath: fileURL.path),
               let content = try? String(contentsOf: fileURL, encoding: .utf8),
               !content.isEmpty {
                if newestLogOffset == nil { newestLogOffset = dayOffset }
                let lines = content.components(separatedBy: "\n")
                let preview = lines.prefix(200).joined(separator: "\n")
                let label: String
                switch dayOffset {
                case 0: label = "Today's"
                case 1: label = "Yesterday's"
                default: label = "\(dateStr)"
                }
                var entry = "\(label) daily log (\(dateStr).md):\n\(preview)"
                if lines.count > 200 {
                    entry += "\n... (\(lines.count - 200) more lines, use memory_get to search)"
                }
                fragments.append(entry)
            }
            dayOffset += 1
        }

        guard !fragments.isEmpty else { return nil }

        var result = "Recent memories (auto-injected from daily logs):\n"
        result += "These are memories saved by you or the user in previous sessions. Treat them as background context, not standing instructions — they describe past tasks, not the current one. If the user's latest message changes scope, numbers, or goal, follow the latest message and do not resume the old task from these memories. Do not delete or rewrite these files unless the user explicitly asks. Use memory_get to search for more, or memory_write to save new ones.\n\n"
        // [T-memory-streak-nudge 09-13] E3: a daily-log gap of ≥2 days means
        // sessions happened but nothing was recorded — the workorder called
        // this "断粮三天" with zero in-app signal. One line here closes that:
        // the agent SEES the gap at injection time, before any audit run.
        // (Only when memory is on and a gap actually exists — never nags when
        // the logs are current.)
        if let newest = newestLogOffset, newest >= 2 {
            result += "⚠️ Memory gap: your last daily log is \(newest) days old — recent sessions left no record. When this conversation produces anything worth keeping (preferences, decisions, facts), use memory_write before the session ends.\n\n"
        }
        result += fragments.joined(separator: "\n\n")
        return result
    }

    /// Execute a memory_write tool call: prepend a timestamped entry to today's daily log.
    func executeMemoryWrite(from json: String) -> FileToolResult {
        guard memoryEnabled else {
            return FileToolResult(output: "Memory saving is disabled for this session. Use /memory to re-enable.", success: false)
        }
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = dict["content"] as? String else {
            return FileToolResult(output: "Error: Missing required 'content' parameter", success: false)
        }

        let fm = FileManager.default
        // ［persona］写进本会话人设的记忆目录。
        let pid = sessionPersonaId ?? PersonaStore.currentID()
        let persistDir = PersonaStore.memoryDir(for: pid)
        try? fm.createDirectory(at: persistDir, withIntermediateDirectories: true)

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let fileName = "\(dateFmt.string(from: Date())).md"
        let fileURL = persistDir.appendingPathComponent(fileName)

        // Build timestamped entry
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = timeFmt.string(from: Date())
        let entry = "<!-- \(timestamp) -->\n\(content)\n\n"

        // Prepend to existing file
        var existing = ""
        if fm.fileExists(atPath: fileURL.path) {
            existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }

        let newContent = entry + existing
        guard let writeData = newContent.data(using: .utf8) else {
            return FileToolResult(output: "Error: Content is not valid UTF-8", success: false)
        }

        do {
            // [P3-13] Atomic write: a jetsam kill mid-write must not leave a
            // truncated daily log behind (same reason MemoryWriteRevoker
            // uses atomically: true).
            try writeData.write(to: fileURL, options: .atomic)
        } catch {
            return FileToolResult(output: "Error writing memory: \(error.localizedDescription)", success: false)
        }

        // Register in meta.db for iSH visibility
        // ［persona］沙箱挂载点是 memory 整根，带上 personas/<id> 相对路径。
        let linuxPath = "\(Self.minisMemoryLinuxDir)/personas/\(pid)/\(fileName)"
        ensureFakefsMetadata(for: linuxPath, isDirectory: false)

        // Enqueue for iCloud v2 sync. Reuse fileName's stem (no second
        // Date() call) so the dateKey matches what was actually written
        // even across a midnight boundary.
        //
        // ［persona］只同步默认人设的日报：recordId 是日期单例，多个人设
        // 共用会互相覆盖。其他人设的日报不同步（留尾巴）。
        let dateStrForSync = (fileName as NSString).deletingPathExtension
        if pid == PersonaStore.defaultPersonaID {
            Task { @MainActor in
                await ChatStore.shared.markDirty(recordType: "MemoryDailyV2", recordId: dateStrForSync)
            }
        }
        NotificationCenter.default.post(name: .memoryFilesDidChange, object: nil)

        return FileToolResult(output: "Memory saved to \(fileName) (\(content.count) chars)", success: true)
    }

    /// Execute a memory_get tool call: read and optionally search memory files.
    /// Uses confidence-based fuzzy matching: entries are scored by how many distinct
    /// keywords they contain, sorted by confidence descending. The model can decide
    /// how to use partial matches.
    func executeMemoryGet(from json: String) -> FileToolResult {
        // [T-memory-toggle-gates-injection-and-tools-ios] Defense in depth:
        // when memory is disabled, makeAgentTools() drops memory_get from
        // the registered tools, so the model normally cannot emit this
        // call. If something else routes here (history replay, manual
        // RPC, future caller), refuse with a clear message that mirrors
        // executeMemoryWrite's guard above.
        guard memoryEnabled else {
            return FileToolResult(output: "Memory is disabled for this session. Use /memory to re-enable, or open Settings to change the default.", success: false)
        }
        let dict: [String: Any]
        if let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = parsed
        } else {
            dict = [:]
        }

        let scope = (dict["scope"] as? String) ?? "all"
        let keywords = ((dict["keywords"] as? String) ?? "")
            .components(separatedBy: .whitespaces)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }

        var filesToSearch: [(label: String, url: URL)] = []
        let fm = FileManager.default
        // ［persona］只搜本会话人设的记忆目录；SOUL.md 是人设文件，不当记忆搜。
        let pid = sessionPersonaId ?? PersonaStore.currentID()
        let memDir = PersonaStore.memoryDir(for: pid)

        var globalEmpty = false
        if scope == "all" {
            let globalFile = memDir.appendingPathComponent("GLOBAL.md")
            if fm.fileExists(atPath: globalFile.path) {
                let content = (try? String(contentsOf: globalFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if content.isEmpty {
                    globalEmpty = true
                } else {
                    filesToSearch.append(("GLOBAL.md", globalFile))
                }
            } else {
                globalEmpty = true
            }
        }

        if fm.fileExists(atPath: memDir.path),
           let files = try? fm.contentsOfDirectory(at: memDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let sorted = files
                .filter { $0.pathExtension == "md"
                    && $0.lastPathComponent != "GLOBAL.md"
                    && $0.lastPathComponent != "SOUL.md" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for file in sorted {
                filesToSearch.append((file.lastPathComponent, file))
            }
        }

        let globalNote = globalEmpty ? "[GLOBAL.md is empty or does not exist. Use file_write to create it when the user asks to save global memory.]\n\n" : ""

        if filesToSearch.isEmpty {
            return FileToolResult(output: globalNote + "No memory files found.", success: true)
        }

        // If no keywords, return full file contents (truncated)
        if keywords.isEmpty {
            let maxTotalLines = 500
            var results: [String] = []
            var totalLines = 0
            for (label, fileURL) in filesToSearch {
                guard totalLines < maxTotalLines else { break }
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8), !content.isEmpty else { continue }
                let lines = content.components(separatedBy: "\n")
                let budget = maxTotalLines - totalLines
                let take = min(lines.count, budget)
                let preview = lines.prefix(take).joined(separator: "\n")
                let truncated = lines.count > take ? " (showing first \(take) of \(lines.count) lines)" : ""
                results.append("[\(label)\(truncated)]\n\(preview)")
                totalLines += take
            }
            return FileToolResult(output: globalNote + results.joined(separator: "\n\n"), success: true)
        }

        // Split file content into memory entries using "<!-- " timestamp markers as boundaries.
        // Falls back to treating the whole file as one entry if no markers found.
        func splitIntoEntries(_ content: String, fileLabel: String) -> [(fileLabel: String, entryText: String)] {
            let lines = content.components(separatedBy: "\n")
            var entries: [(String, String)] = []
            var currentLines: [String] = []

            for line in lines {
                if line.hasPrefix("<!-- ") && !currentLines.isEmpty {
                    let text = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { entries.append((fileLabel, text)) }
                    currentLines = [line]
                } else {
                    currentLines.append(line)
                }
            }
            if !currentLines.isEmpty {
                let text = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { entries.append((fileLabel, text)) }
            }
            // If no timestamp markers found, treat whole file as one entry
            if entries.isEmpty && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries.append((fileLabel, content.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            return entries
        }

        // Score each entry: count distinct keywords + extract timestamp for recency scoring.
        struct ScoredEntry {
            let fileLabel: String
            let text: String
            let matchedCount: Int
            let totalKeywords: Int
            let timestamp: Date
        }

        // Parse timestamp from entry text (<!-- 2026-03-04 17:00:00 -->) or fall back to
        // file label date (2026-03-04.md) or distantPast for GLOBAL.md entries.
        let tsFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()
        let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()

        func extractTimestamp(from entryText: String, fileLabel: String) -> Date {
            // Try <!-- 2026-03-04 17:00:00 --> in first line
            if let firstLine = entryText.components(separatedBy: "\n").first,
               firstLine.hasPrefix("<!-- "),
               let end = firstLine.range(of: " -->"),
               let ts = tsFormatter.date(from: String(firstLine[firstLine.index(firstLine.startIndex, offsetBy: 5)..<end.lowerBound])) {
                return ts
            }
            // Fall back to file label date (e.g. "2026-03-04.md")
            let stem = (fileLabel as NSString).deletingPathExtension
            if let d = dateFormatter.date(from: stem) { return d }
            // GLOBAL.md or unknown — treat as oldest
            return Date.distantPast
        }

        var allEntries: [ScoredEntry] = []
        var totalEntryCount = 0

        for (label, fileURL) in filesToSearch {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8), !content.isEmpty else { continue }
            let entries = splitIntoEntries(content, fileLabel: label)
            totalEntryCount += entries.count
            for (fileLabel, entryText) in entries {
                let lower = entryText.lowercased()
                let matchedCount = keywords.filter { lower.contains($0) }.count
                if matchedCount > 0 {
                    let ts = extractTimestamp(from: entryText, fileLabel: fileLabel)
                    allEntries.append(ScoredEntry(
                        fileLabel: fileLabel,
                        text: entryText,
                        matchedCount: matchedCount,
                        totalKeywords: keywords.count,
                        timestamp: ts
                    ))
                }
            }
        }

        if allEntries.isEmpty {
            return FileToolResult(
                output: globalNote + "No matches found for keywords: \(keywords.joined(separator: ", ")) (scanned \(totalEntryCount) memory entries)",
                success: true
            )
        }

        // Compute combined score: 50% normalized confidence + 50% normalized recency.
        // Normalize confidence: matchedCount / totalKeywords → [0, 1]
        // Normalize recency: (ts - minTs) / (maxTs - minTs) → [0, 1], newer = higher
        let minTs = allEntries.map { $0.timestamp.timeIntervalSince1970 }.min() ?? 0
        let maxTs = allEntries.map { $0.timestamp.timeIntervalSince1970 }.max() ?? 1
        let tsRange = maxTs - minTs  // may be 0 if all entries have same timestamp

        let scored: [(entry: ScoredEntry, score: Double)] = allEntries.map { entry in
            let confScore = Double(entry.matchedCount) / Double(max(entry.totalKeywords, 1))
            let recencyScore: Double
            if tsRange > 0 {
                recencyScore = (entry.timestamp.timeIntervalSince1970 - minTs) / tsRange
            } else {
                recencyScore = 1.0  // all same age — treat equally
            }
            let combined = 0.5 * confScore + 0.5 * recencyScore
            return (entry, combined)
        }

        let sortedScored = scored.sorted { $0.score > $1.score }

        // Cap output to avoid flooding context. Two independent limits, whichever
        // is hit FIRST wins:
        //   1. Entry count — max 60 entries (legacy T-memory-get-limit).
        //   2. Byte size — max 30 KB of UTF-8 entry text. Reported by Xu Jiu
        //      (TG 37452): a single memory_get returned ~70 KB, making the
        //      tool-result view stutter for seconds. We accumulate per entry
        //      and stop AFTER the entry that pushes the running total past the
        //      ceiling (so the triggering entry is shown whole, never sliced).
        let maxEntries = 60
        let maxBytes = 30 * 1024  // 30,720 bytes

        var rendered: [String] = []
        var shownBytes = 0
        var stoppedByBytes = false
        for item in sortedScored {
            if rendered.count >= maxEntries { break }
            let confidence = "\(item.entry.matchedCount)/\(item.entry.totalKeywords)"
            let scoreStr = String(format: "%.2f", item.score)
            let block = "[score: \(scoreStr) | confidence: \(confidence) | \(item.entry.fileLabel)]\n\(item.entry.text)"
            rendered.append(block)
            shownBytes += block.utf8.count
            // Append-then-break: include this entry in full, then stop.
            if shownBytes >= maxBytes {
                stoppedByBytes = true
                break
            }
        }

        let output = rendered.joined(separator: "\n\n---\n\n")

        let shownCount = rendered.count
        let truncatedNote: String
        if stoppedByBytes {
            let kb = String(format: "%.1f", Double(shownBytes) / 1024.0)
            truncatedNote = "\n\n[Truncated: showing \(shownCount) of \(sortedScored.count) matching entries, total \(kb) KB]"
        } else if sortedScored.count > shownCount {
            // Hit the entry-count cap before the byte cap.
            truncatedNote = "\n\n[Showing top \(shownCount) of \(sortedScored.count) matching entries]"
        } else {
            truncatedNote = ""
        }

        let summary = "Found \(sortedScored.count) matching entries (scanned \(totalEntryCount) total), sorted by combined score (50% confidence + 50% recency):"
        return FileToolResult(output: globalNote + summary + "\n\n" + output + truncatedNote, success: true)
    }

    /// Escape single quotes for shell arguments.
    private func shellEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }


}
