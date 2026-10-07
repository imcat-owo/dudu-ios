import Foundation

private let logger = AppLogger(category: "Backup")

/// What was captured before a category was touched, so it can be undone.
///
/// §8.1 says the snapshot covers "only the categories that will be modified".
/// For file-tree categories that means copying the affected directories aside;
/// for DB-backed categories a full row-level snapshot would be prohibitive on a
/// 100k-message database, so those record no file snapshot and rely on
/// per-record LWW being idempotent (re-running a Merge import is a no-op).
struct BackupRollbackSnapshot {
    let category: BackupCategory
    /// live directory → saved copy
    var directories: [(live: URL, saved: URL)] = []
    /// live file → saved copy, for categories backed by a single file rather
    /// than a tree (provider-config.json).
    var files: [(live: URL, saved: URL)] = []

    /// True when nothing was captured, so a rollback would be a no-op and
    /// must not be reported as one having happened.
    var isEmpty: Bool { directories.isEmpty && files.isEmpty }
}

extension BackupImporter {

    // MARK: - File index

    func readFileIndex(at root: URL) -> [BackupFileIndexEntry] {
        let url = root.appendingPathComponent("files.index.jsonl")
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        var out: [BackupFileIndexEntry] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            // §2.2 rule 3: one bad line is skipped, never fatal.
            if let e = try? decoder.decode(BackupFileIndexEntry.self, from: Data(line)) {
                out.append(e)
            }
        }
        // A resumed export re-runs an interrupted category from scratch
        // while the index writer appends, so files indexed before the
        // interruption appear twice. Keep only the last row per
        // (category, path) — the re-run's row — so restore neither
        // writes nor counts the same file twice.
        var lastIndex: [String: Int] = [:]
        for (i, e) in out.enumerated() {
            lastIndex["\(e.category)\u{0}\(e.path)"] = i
        }
        return out.enumerated().filter { lastIndex["\($0.element.category)\u{0}\($0.element.path)"] == $0.offset }.map(\.element)
    }

    // MARK: - Rollback

    func snapshotForRollback(category: BackupCategory, staging: URL) throws -> BackupRollbackSnapshot {
        var snap = BackupRollbackSnapshot(category: category)
        let fm = FileManager.default

        // Only directory-backed categories get a copy-aside. Chats is excluded
        // deliberately: snapshotting every session directory could mean copying
        // gigabytes to undo a merge that is itself idempotent.
        let liveDirs: [URL]
        switch category {
        case .sharedFiles: liveDirs = [AIChatViewModel.minisSharedPersistentDir]
        case .memory: liveDirs = [AIChatViewModel.minisMemoryPersistentDir]
        // [PIC-2] The appearance tree is directory-backed like shared
        // files, so it gets the same copy-aside rollback.
        case .appearance: liveDirs = [AppearanceStudio.appearanceAssetsDirectory]
        case .mcpServers: liveDirs = [MCPStore.syncFileURL.deletingLastPathComponent()]
        // [review B3] Providers had NO rollback at all. It is a single JSON
        // file rather than a directory, so it is snapshotted via a dedicated
        // file-level entry instead of the directory copy-aside used above.
        case .providers: liveDirs = []
        // Environment variables merge into the live store rather than
        // replacing a file, so there is nothing to snapshot.
        case .chats, .skills, .voiceCorrections, .environmentVariables:
            liveDirs = []
        }

        // File-backed categories: snapshot the single file.
        if category == .providers {
            let live = ProviderConfigStore.configFileURLForBackup
            if fm.fileExists(atPath: live.path) {
                let saved = staging.appendingPathComponent("providers-provider-config.json")
                try? fm.removeItem(at: saved)
                try fm.copyItem(at: live, to: saved)
                // [review I4] Record the live target in a sidecar. Directory
                // snapshots put a `.live-path` file INSIDE themselves, which a
                // plain file cannot do — so without this, reconcileAtLaunch
                // skipped the providers snapshot entirely and a crash mid
                // provider-restore left it unrecoverable.
                try? Data(live.path.utf8).write(
                    to: staging.appendingPathComponent(
                        "providers-provider-config.json"
                        + BackupRestoreJournal.fileSnapshotSidecarSuffix),
                    options: .atomic)
                snap.files.append((live: live, saved: saved))
            }
        }

        // [p1fix] personas.json 住在 MinisConfig，不在 memory 目录树里，
        // 上面的目录 copy-aside 覆盖不到。仿 providers 做文件级快照，
        // 否则恢复中途失败时注册表回滚不了。
        if category == .memory {
            let live = AIChatViewModel.minisConfigRoot.appendingPathComponent("personas.json")
            if fm.fileExists(atPath: live.path) {
                let saved = staging.appendingPathComponent("memory-personas.json")
                try? fm.removeItem(at: saved)
                try fm.copyItem(at: live, to: saved)
                try? Data(live.path.utf8).write(
                    to: staging.appendingPathComponent(
                        "memory-personas.json"
                        + BackupRestoreJournal.fileSnapshotSidecarSuffix),
                    options: .atomic)
                snap.files.append((live: live, saved: saved))
            }
        }

        for live in liveDirs where fm.fileExists(atPath: live.path) {
            let saved = staging.appendingPathComponent(
                "\(category.rawValue)-\(live.lastPathComponent)", isDirectory: true)
            try? fm.removeItem(at: saved)
            try fm.copyItem(at: live, to: saved)
            // Record where this came from, so a launch-time reconcile after a
            // crash can restore it without re-deriving the mapping.
            try? Data(live.path.utf8).write(
                to: saved.appendingPathComponent(".live-path"), options: .atomic)
            snap.directories.append((live: live, saved: saved))
        }
        return snap
    }

    func rollback(_ snapshot: BackupRollbackSnapshot) throws {
        let fm = FileManager.default
        for pair in snapshot.directories {
            try fm.createDirectory(at: pair.live.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            // Atomic swap rather than remove-then-copy: the old pair left the
            // user's directory deleted and not yet replaced if the process died
            // between the two steps — for shared files that is the entire
            // directory.
            try BackupRestoreJournal.atomicReplace(directory: pair.saved, onto: pair.live)
        }
        for pair in snapshot.files {
            _ = try? FileManager.default.replaceItemAt(pair.live, withItemAt: pair.saved)
        }
        // A file-level provider rollback only rewrites the JSON on disk; the
        // in-memory store still holds the merged config, so it must be reloaded
        // or the UI would keep showing state that is no longer persisted.
        // [p1fix] personas.json 同理：回滚后重载 PersonaStore。
        if !snapshot.files.isEmpty {
            let rolledBackPersonas = snapshot.files.contains {
                $0.live.lastPathComponent == "personas.json"
            }
            Task { @MainActor in
                await ProviderConfigStore.shared.reloadFromDisk()
                if rolledBackPersonas { PersonaStore.shared.reloadFromDisk() }
            }
        }
        logger.info("[Restore] rolled back \(snapshot.category.rawValue) (\(snapshot.directories.count) dir(s))")
    }

    // MARK: - Dispatch

    func importCategory(_ category: BackupCategory,
                        root: URL,
                        fileIndex: [BackupFileIndexEntry],
                        options: Options) async throws -> CategoryReport {
        switch category {
        case .chats: return try await importChats(root: root, fileIndex: fileIndex, options: options)
        case .sharedFiles: return try importSharedFiles(root: root, fileIndex: fileIndex)
        case .skills: return try await importSkills(root: root, fileIndex: fileIndex)
        case .memory: return try await importMemory(root: root)
        case .providers: return try await importProviders(root: root)
        case .mcpServers: return try await importMCPServers(root: root)
        case .voiceCorrections: return try await importVoiceCorrections(root: root)
        case .environmentVariables:
            return try await importEnvironmentVariables(root: root)
        case .appearance: return try await importAppearance(root: root, fileIndex: fileIndex)
        }
    }

    // MARK: - Chats

    private func importChats(root: URL, fileIndex: [BackupFileIndexEntry],
                             options: Options) async throws -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.chats.rawValue)
        let store = ChatStore.shared
        let dataDir = root.appendingPathComponent("data", isDirectory: true)

        // Folders first: sessions carry a folderId, and applying the folder
        // beforehand means the reference resolves immediately.
        for env in readJSONL(dataDir, base: "folders", as: ChatFolder.self) {
            await store.applyRemoteFolder(env)
        }

        // Sessions before messages — restoreMessage requires the parent row.
        var restoredSessionIds: [String] = []
        var runningSessionIds: Set<String> = []
        var packageSessionIds: Set<String> = []
        struct SessionRecord: Codable {
            let session: ChatSession
            let memoryEnabled: Bool
            let modelBinding: String?
        }
        for rec in readJSONL(dataDir, base: "sessions", as: SessionRecord.self) {
            let sid = rec.session.id
            packageSessionIds.insert(sid)
            // Refuse rather than silently skip: a running agent loop owns its
            // message list, and writing under it would scramble sort_order.
            // The id is remembered so the message / marker / file-tree passes
            // below refuse to write into the same session — guarding only the
            // session row would still let its contents be overwritten, and
            // the report would count the session skipped but its messages
            // imported.
            if await store.isSessionRunning(sid) {
                runningSessionIds.insert(sid)
                report.skipped += 1
                continue
            }
            await store.clearRestoreTombstone(sessionId: sid)
            let outcome = await store.restoreSession(rec.session,
                                                     memoryEnabled: rec.memoryEnabled,
                                                     modelBinding: rec.modelBinding)
            switch outcome {
            case .inserted: report.imported += 1; restoredSessionIds.append(sid)
            case .updated: report.updated += 1; restoredSessionIds.append(sid)
            case .skippedLocalNewer: report.skipped += 1; restoredSessionIds.append(sid)
            case .skippedNoParent: report.skipped += 1
            }
        }

        let messageRecords = readJSONL(dataDir, base: "messages", as: RawMessage.self)
        let markerRecords = readJSONL(dataDir, base: "compact_markers", as: CompactMarker.self)
        // A session can also be running locally without its row being in
        // this package (its messages/markers still resolve to the local
        // parent row). Extend the same refusal to those ids before any
        // content pass writes into them.
        let contentOnlyIds = Set(messageRecords.map(\.sessionId))
            .union(markerRecords.map(\.sessionId))
            .subtracting(packageSessionIds)
            .subtracting(runningSessionIds)
        for sid in contentOnlyIds {
            if await store.isSessionRunning(sid) {
                runningSessionIds.insert(sid)
            }
        }

        for msg in messageRecords {
            if runningSessionIds.contains(msg.sessionId) {
                report.skipped += 1
                continue
            }
            guard let partsJson = encodeParts(msg.parts) else {
                report.unreadable += 1
                continue
            }
            let outcome = await store.restoreMessage(
                id: msg.id, sessionId: msg.sessionId, role: msg.role.rawValue,
                partsJson: partsJson, createdAt: msg.createdAt,
                tokenUsageJson: encodeTokenUsage(msg.tokenUsage), sortOrder: msg.sortOrder,
                reasoningContent: msg.reasoningContent,
                streamInterruptCount: msg.streamInterruptCount,
                updatedAt: msg.createdAt,
                // [T-token-attribution-snapshot] RawMessage decodes these
                // straight from the package; nil for older packages.
                modelId: msg.modelId, modelDisplayName: msg.modelDisplayName,
                providerType: msg.providerType,
                providerInstanceId: msg.providerInstanceId,
                errorInfo: msg.errorInfo)
            switch outcome {
            case .inserted: report.imported += 1
            case .updated: report.updated += 1
            case .skippedLocalNewer, .skippedNoParent: report.skipped += 1
            }
        }

        for marker in markerRecords {
            if runningSessionIds.contains(marker.sessionId) {
                report.skipped += 1
                continue
            }
            switch await store.restoreCompactMarker(marker) {
            case .inserted: report.imported += 1
            case .updated: report.updated += 1
            case .skippedLocalNewer, .skippedNoParent: report.skipped += 1
            }
        }

        // Session file trees: rebuild <sid>/ wholesale (§8.3).
        let files = try restoreFileTree(
            root: root, fileIndex: fileIndex, category: .chats,
            destinationFor: { path in
                // "chats/<sid>/<rel…>" → Library/MinisChat/minis/<sid>/<rel…>
                // Running sessions are refused here too (nil = do not write),
                // same as the row/message/marker passes above.
                let parts = path.split(separator: "/", maxSplits: 2).map(String.init)
                guard parts.count >= 3, parts[0] == "chats",
                      !runningSessionIds.contains(parts[1]) else { return nil }
                return AIChatViewModel.minisPersistentBase
                    .appendingPathComponent(parts[1], isDirectory: true)
                    .appendingPathComponent(parts[2])
            })
        report.filesWritten = files.written
        report.bytesWritten = files.bytes
        report.missingBlobs = files.missingBlobs

        // §8.3: restored rows go through NORMAL dirty marking so the local sync
        // engine re-uploads them under this device's identity. They carry no
        // inbound sync state, and nothing here writes sync_pushed_records.
        for sid in restoredSessionIds {
            await store.markDirty(recordType: "Session", recordId: sid)
        }
        return report
    }

    // MARK: - Shared files

    private func importSharedFiles(root: URL, fileIndex: [BackupFileIndexEntry]) throws
        -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.sharedFiles.rawValue)
        let base = AIChatViewModel.minisSharedPersistentDir
        let files = try restoreFileTree(
            root: root, fileIndex: fileIndex, category: .sharedFiles,
            destinationFor: { path in
                guard path.hasPrefix("shared/") else { return nil }
                return base.appendingPathComponent(String(path.dropFirst("shared/".count)))
            })
        report.filesWritten = files.written
        report.bytesWritten = files.bytes
        report.missingBlobs = files.missingBlobs
        // Per §3.2 no meta.db write is needed: every mount re-walks this
        // directory and re-registers rows, so the guest sees the files after the
        // next boot.
        return report
    }

    // MARK: - Appearance

    /// [PIC-2] The AppearanceStudio tree back to its original location
    /// (same merge semantics as Shared Files: package files overwrite,
    /// files the package doesn't mention are left alone), plus the
    /// UserDefaults half from `data/appearance_settings.json`.
    /// `applyBackupDefaults` whitelists the keys it writes and reloads
    /// the live AppearanceStudio, so the restored look applies without
    /// a relaunch.
    private func importAppearance(root: URL, fileIndex: [BackupFileIndexEntry]) async throws
        -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.appearance.rawValue)
        let base = AppearanceStudio.appearanceAssetsDirectory
        let files = try restoreFileTree(
            root: root, fileIndex: fileIndex, category: .appearance,
            destinationFor: { path in
                guard path.hasPrefix("appearance/") else { return nil }
                return base.appendingPathComponent(String(path.dropFirst("appearance/".count)))
            })
        report.filesWritten = files.written
        report.bytesWritten = files.bytes
        report.missingBlobs = files.missingBlobs

        let settingsURL = root.appendingPathComponent("data/appearance_settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let values = try? JSONDecoder().decode([String: BackupDefaultsValue].self, from: data) {
            await MainActor.run {
                AppearanceStudio.shared.applyBackupDefaults(values)
                // [batch7 用户-P2-11] 清除标记与文件 merge 语义对齐：以清除
                // 标记为准——包里没带某页壁纸文件、但标记说该页已清除时，
                // 本机残留的该页壁纸文件删掉，不让标记变死标记。
                AppearanceStudio.shared.reconcileClearedWallpapersAfterRestore(
                    packagedScopes: Self.packagedWallpaperScopes(in: fileIndex))
            }
            report.imported += 1
        }
        // [P3-16] Reconcile the theme library with its list: the file tree
        // above merges, but the list was just replaced by the backup's, so
        // pack files with no list entry are orphans (invisible in the UI,
        // undeletable) — remove them. Runs even when the package carried
        // no settings: then the local list stands, and only pre-existing
        // local orphans go.
        let orphansRemoved = await MainActor.run {
            AppearanceStudio.shared.removeOrphanedLibraryPacks()
        }
        if orphansRemoved > 0 {
            logger.info("[Restore] appearance: removed \(orphansRemoved) orphaned theme pack(s) with no library entry")
        }
        return report
    }

    /// 包里实际带了壁纸文件的 scope（文件名 appearance/wallpaper-<scope>.jpg）。
    private static func packagedWallpaperScopes(in fileIndex: [BackupFileIndexEntry])
        -> Set<AppearanceScope> {
        var out = Set<AppearanceScope>()
        for entry in fileIndex {
            guard entry.category == BackupCategory.appearance.rawValue,
                  entry.skipped == nil,
                  entry.path.hasPrefix("appearance/wallpaper-"),
                  entry.path.hasSuffix(".jpg") else { continue }
            let raw = entry.path
                .dropFirst("appearance/wallpaper-".count)
                .dropLast(".jpg".count)
            if let scope = AppearanceScope(rawValue: String(raw)) {
                out.insert(scope)
            }
        }
        return out
    }

    // MARK: - Skills

    private func importSkills(root: URL, fileIndex: [BackupFileIndexEntry]) async throws
        -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.skills.rawValue)
        let dataDir = root.appendingPathComponent("data", isDirectory: true)

        struct SkillRecord: Codable {
            let id: String, name: String, description: String, version: String
            let isEnabled: Bool, installedAt: Date, updatedAt: Date, body: String
            let sourceURL: String?
        }
        var lwwSkippedIds: Set<String> = []
        for rec in readJSONL(dataDir, base: "skills", as: SkillRecord.self) {
            // importSkillFromSync preserves the id and applies its own LWW,
            // which is exactly Merge semantics; it also skips markDirty, so the
            // rescan below stages the changes instead.
            let applied = await MainActor.run {
                SkillStore.shared.importSkillFromSync(
                    skillId: rec.id, content: rec.body,
                    source: rec.sourceURL.map { .url($0) } ?? .file,
                    isEnabled: rec.isEnabled, installedAt: rec.installedAt,
                    updatedAt: rec.updatedAt, version: rec.version,
                    name: rec.name, description: rec.description)
            }
            if applied { report.imported += 1 } else {
                report.skipped += 1
                lwwSkippedIds.insert(rec.id)
            }
        }

        let files = try restoreFileTree(
            root: root, fileIndex: fileIndex, category: .skills,
            destinationFor: { path in
                let parts = path.split(separator: "/", maxSplits: 2).map(String.init)
                guard parts.count >= 3, parts[0] == "skills" else { return nil }
                // A false from importSkillFromSync means the LOCAL skill is
                // newer than the package's record — its contract says the
                // caller MUST then stop file processing for that skill.
                // Restoring its files anyway would silently roll the skill
                // (SKILL.md and sidecars alike) back to the older backup.
                guard !lwwSkippedIds.contains(parts[1]) else { return nil }
                return AIChatViewModel.minisSkillsPersistentDir
                    .appendingPathComponent(parts[1], isDirectory: true)
                    .appendingPathComponent(parts[2])
            })
        report.filesWritten = files.written
        report.bytesWritten = files.bytes
        report.missingBlobs = files.missingBlobs
        return report
    }

    // MARK: - Memory & Soul

    private func importMemory(root: URL) async throws -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.memory.rawValue)
        let fm = FileManager.default
        let src = root.appendingPathComponent("data/memory", isDirectory: true)
        guard fm.fileExists(atPath: src.path) else { return report }
        let dst = AIChatViewModel.minisMemoryPersistentDir
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)

        for name in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where name.hasSuffix(".md") {
            let from = src.appendingPathComponent(name)
            let to = dst.appendingPathComponent(name)

            // Identical content is a skip, not an import.
            //
            // mtime cannot decide this: ZIP timestamps have 2-second
            // resolution and extraction does not preserve the original mtime
            // at all, so the package copy's date is meaningless. Restoring a
            // package onto the device that produced it was reporting all five
            // memory files as freshly "imported" — a report the user would
            // read as "5 files changed" when nothing did. These files are
            // small (a few KB), so hashing them is cheap and exact.
            if let localData = try? Data(contentsOf: to),
               let pkgData = try? Data(contentsOf: from),
               localData == pkgData {
                report.skipped += 1
                continue
            }
            // Stage next to the destination and swap, rather than
            // removeItem-then-copyItem (the pattern restoreFileTree's
            // comment documents): deleting first meant a failed copy —
            // disk full, IO error — left the user's file simply GONE.
            // A failure here now throws, so the category fails and the
            // rollback snapshot taken for .memory is actually used;
            // counting it as "unreadable" and carrying on bypassed both
            // protections.
            let staged = dst.appendingPathComponent(".restore-\(UUID().uuidString).tmp")
            do {
                try fm.copyItem(at: from, to: staged)
                if fm.fileExists(atPath: to.path) {
                    _ = try fm.replaceItemAt(to, withItemAt: staged)
                } else {
                    try fm.moveItem(at: staged, to: to)
                }
                report.imported += 1
            } catch {
                try? fm.removeItem(at: staged)
                throw error
            }
        }

        // P1-2：人设记忆目录 data/memory/personas/<id>/*.md 原样写回。
        // 旧包没有它时照常跳过；单文件走与顶层同样的 hash 比对 + staged swap。
        var registryRestored = false
        let personasSrc = src.appendingPathComponent("personas", isDirectory: true)
        if fm.fileExists(atPath: personasSrc.path) {
            let personasDst = dst.appendingPathComponent("personas", isDirectory: true)
            try fm.createDirectory(at: personasDst, withIntermediateDirectories: true)
            if let enumerator = fm.enumerator(at: personasSrc, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let fileURL as URL in enumerator {
                    guard fileURL.pathExtension == "md",
                          (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                    else { continue }
                    let rel = String(fileURL.path.dropFirst(personasSrc.path.count + 1))
                    let to = personasDst.appendingPathComponent(rel)
                    try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if let localData = try? Data(contentsOf: to),
                       let pkgData = try? Data(contentsOf: fileURL),
                       localData == pkgData {
                        report.skipped += 1
                        continue
                    }
                    let staged = dst.appendingPathComponent(".restore-\(UUID().uuidString).tmp")
                    do {
                        try fm.copyItem(at: fileURL, to: staged)
                        if fm.fileExists(atPath: to.path) {
                            _ = try fm.replaceItemAt(to, withItemAt: staged)
                        } else {
                            try fm.moveItem(at: staged, to: to)
                        }
                        report.imported += 1
                    } catch {
                        try? fm.removeItem(at: staged)
                        throw error
                    }
                }
            }
        }

        // P1-2：人设注册表 data/memory/personas.json → MinisConfig/personas.json。
        // 旧包没有它时照常跳过。
        let registrySrc = src.appendingPathComponent("personas.json")
        if fm.fileExists(atPath: registrySrc.path) {
            let registryDst = AIChatViewModel.minisConfigRoot.appendingPathComponent("personas.json")
            try fm.createDirectory(at: registryDst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let localData = try? Data(contentsOf: registryDst),
               let pkgData = try? Data(contentsOf: registrySrc),
               localData == pkgData {
                report.skipped += 1
            } else {
                let staged = registryDst.deletingLastPathComponent()
                    .appendingPathComponent(".restore-\(UUID().uuidString).tmp")
                do {
                    try fm.copyItem(at: registrySrc, to: staged)
                    if fm.fileExists(atPath: registryDst.path) {
                        _ = try fm.replaceItemAt(registryDst, withItemAt: staged)
                    } else {
                        try fm.moveItem(at: staged, to: registryDst)
                    }
                    report.imported += 1
                    registryRestored = true
                } catch {
                    try? fm.removeItem(at: staged)
                    throw error
                }
            }
        }

        // SOUL.md is cached in memory; a raw file write leaves that cache stale
        // until something else refreshes it.
        await MainActor.run { SoulStore.refreshCache() }
        // 注册表落盘后内存里的 PersonaStore 还是旧表，重载一次，
        // 否则恢复完人设列表不变——看起来像"恢复后人设全丢"没修好。
        if registryRestored {
            await MainActor.run { PersonaStore.shared.reloadFromDisk() }
        }
        return report
    }

    // MARK: - Providers

    private func importProviders(root: URL) async throws -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.providers.rawValue)
        let url = root.appendingPathComponent("data/provider_config.json")
        guard let data = try? Data(contentsOf: url) else { return report }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let config = try? decoder.decode(ProviderConfig.self, from: data) else {
            report.unreadable += 1
            return report
        }
        // [T-ios-backup-provider-merge] MUST NOT be applyConfig: that replaces
        // the entire config, so any provider / model group / session binding
        // that exists locally but not in the backup was silently deleted —
        // while the restore confirmation promised "Nothing is deleted".
        // mergeProviderConfigForRestore is the sync engine's union-by-id
        // merger, which keeps local-only items and leaves the per-device
        // pointer fields (voice/vision groups, session bindings, defaults)
        // untouched.
        // CloudSyncEngine is @available(iOS 17+) (it is CloudKit-backed), while
        // the app targets iOS 16. On 16 the merge is done inline below with the
        // same union-by-id rules — restoring must never fall back to the
        // destructive whole-config replace just because sync is unavailable.
        // Disambiguate model groups whose NAME collides with one already on
        // this device. The merge is by id, so a restored group is correctly a
        // separate entity — but on screen the user then sees two rows both
        // called "Default Models" with no way to tell which is which. Seen for
        // real: a restore produced three duplicate pairs in the model picker.
        //
        // Only collisions are touched. A group whose name is unique keeps it
        // exactly, so the common case (restoring onto a clean device) reads
        // the same as the source.
        let merged = await MainActor.run { Self.disambiguateGroupNames(config) }

        let before = await MainActor.run { ProviderConfigStore.shared.config.instances.count }
        if #available(iOS 17.0, *) {
            await CloudSyncEngine.mergeProviderConfigForRestore(merged)
        } else {
            await MainActor.run { Self.mergeProviderConfigFallback(merged) }
        }
        let after = await MainActor.run { ProviderConfigStore.shared.config.instances.count }

        // Report what the merge actually did, not the package's instance count:
        // an instance already present locally is not a new arrival.
        //
        // [T-backup-provider-false-updated] `updated` used to be
        // `config.instances.count - imported`, i.e. "every instance in the
        // package that wasn't newly inserted" — with no content comparison at
        // all. Both mergers here are union-by-id and SKIP anything already
        // present (mergeProviderConfigFallback appends only when the id is
        // absent; CloudSyncEngine's restore merge behaves the same way), so
        // those instances were not updated — they were left untouched.
        // Restoring a package onto the device that produced it therefore
        // reported "Updated 9" while changing nothing, which is the reported
        // symptom. Count them as `skipped`, which is what actually happened
        // and what every other category (chats via LWW, memory via content
        // hash) already reports for an unchanged item.
        report.imported = max(0, after - before)
        report.skipped = max(0, config.instances.count - report.imported)

        // [T-backup-thinking-rules] AFTER the instance merge, never before: a
        // rule's `instance_id` points at a ProviderInstance, so importing rules
        // first would attach them to instances that do not exist yet and they
        // would resolve to nothing, silently.
        //
        // Absent in packages written by older builds — that is not an error,
        // the file simply isn't there and `readJSONL` returns [].
        let rules = readJSONL(root.appendingPathComponent("data", isDirectory: true),
                              base: "thinking_rules", as: BackupThinkingRuleRecord.self)
        if !rules.isEmpty {
            let outcome = await Self.importThinkingRules(rules)
            report.imported += outcome.written
            report.skipped += outcome.skipped
        }

        // §3.3: credentials belong to this category and restore with it.
        // Absent for a "share copy" package, which is why nil is not an error.
        if let creds = await MainActor.run(body: { BackupSecretsImporter.restore(from: root) }) {
            // All three credential kinds count as restored: env vars and
            // MCP OAuth written back here were previously dropped from the
            // report, which under-counted "API keys restored" and could
            // drop the restore footer into its "created without API keys"
            // branch even though credentials had just been written.
            report.credentialsRestored = creds.total
            report.credentialsKept = creds.providersSkippedExisting
                + creds.envVarsSkippedExisting + creds.mcpOAuthSkippedExisting
            report.credentialsUndecodable = creds.credentialsUndecodable
                + creds.mcpOAuthUndecodable
        }
        return report
    }

    /// [T-backup-thinking-rules] Merge restored thinking rules into the
    /// provider DB.
    ///
    /// Deliberately delegates to `upsertThinkingRuleFromInbound`, the same call
    /// the iCloud sync hydrator uses, rather than writing a second merge:
    ///   * conflict is resolved by id (`ON CONFLICT(id) DO UPDATE`);
    ///   * a LOCAL row with an equal-or-newer `updated_at` wins, so restoring
    ///     an older package cannot roll back a rule edited since;
    ///   * it hard-codes `is_builtin = 0`, so nothing arriving from a package
    ///     can ever masquerade as a built-in rule.
    ///
    /// Returns (written, skipped) so the caller reports what actually changed
    /// rather than counting every record in the file as an import — the same
    /// distinction [T-backup-provider-false-updated] restored for instances.
    @MainActor
    private static func importThinkingRules(
        _ rules: [BackupThinkingRuleRecord]
    ) async -> (written: Int, skipped: Int) {
        guard let db = ProviderConfigStore.shared.db else { return (0, 0) }
        var written = 0
        var skipped = 0
        for r in rules {
            let applied = await db.upsertThinkingRuleFromInbound(
                id: r.id,
                instanceId: r.instanceId,
                sortOrder: r.sortOrder,
                scopeKind: r.scopeKind,
                scopePattern: r.scopePattern,
                wireFormatJson: r.wireFormatJson,
                echoField: r.echoField,
                echoTiming: r.echoTiming,
                label: r.label,
                createdAt: r.createdAt.timeIntervalSince1970,
                updatedAt: r.updatedAt.timeIntervalSince1970
            )
            if applied { written += 1 } else { skipped += 1 }
        }
        // The resolver reads rules through a process-wide cache, so a restore
        // that only touched SQLite would not affect the next request until the
        // app restarted.
        await ProviderConfigStore.shared.reloadThinkingRuleCache()
        logger.info("[Restore] thinking rules: \(written) applied, \(skipped) skipped (local newer or unchanged)")
        return (written, skipped)
    }

    /// Union-by-id provider merge for iOS 16, where `CloudSyncEngine` (iOS 17+,
    /// CloudKit-backed) is unavailable.
    ///
    /// Deliberately conservative and additive: local wins for anything already
    /// present, backup-only items are appended, and every per-device pointer
    /// field is left alone. It does NOT reimplement the sync merger's
    /// Suffix restored model groups whose name is already taken locally.
    ///
    /// Returns the config unchanged when there is no collision — the suffix is
    /// a disambiguator, not a label for "this came from a backup", so a group
    /// that lands on a device without a same-named one keeps its original
    /// name. A group already present BY ID is skipped too: that is the same
    /// group coming home, not a duplicate.
    @MainActor
    static func disambiguateGroupNames(_ remote: ProviderConfig) -> ProviderConfig {
        let local = ProviderConfigStore.shared.config
        let localIds = Set(local.modelGroups.map(\.id))
        var takenNames = Set(local.modelGroups.map(\.name))
        guard !takenNames.isEmpty else { return remote }

        var copy = remote
        var renamed = 0
        for i in copy.modelGroups.indices {
            let group = copy.modelGroups[i]
            // Same id => the very same group, which merge will skip entirely.
            guard !localIds.contains(group.id) else { continue }
            guard takenNames.contains(group.name) else {
                takenNames.insert(group.name)
                continue
            }
            let base = AppLocalized("\(group.name) (from backup)")
            var candidate = base
            var n = 2
            while takenNames.contains(candidate) {
                candidate = "\(base) \(n)"
                n += 1
            }
            copy.modelGroups[i].name = candidate
            takenNames.insert(candidate)
            renamed += 1
        }
        if renamed > 0 {
            logger.info("[Restore] renamed \(renamed) model group(s) whose names collided with local ones")
        }
        return copy
    }

    /// model-entry overlay or tombstone reconciliation — those matter for
    /// device-to-device convergence, not for "put my backup back" — but it
    /// must never delete, which is the property that was broken.
    @MainActor
    static func mergeProviderConfigFallback(_ remote: ProviderConfig) {
        let store = ProviderConfigStore.shared
        var local = store.config

        // [T-backup-restore-order] Restore the BACKUP's order, then keep
        // local-only items after it.
        //
        // Appending backup items to the end preserved neither side's
        // arrangement: the provider list is drag-reorderable and its order
        // lives in the array itself (ProviderConfigDB writes the array index
        // into `sort_order`), so a restore used to leave the list looking
        // shuffled — the reported "恢复会把服务商、分组的排序全部打乱".
        //
        // Local wins on CONTENT for an id present on both sides (this path is
        // deliberately additive and never overwrites), but the package decides
        // POSITION for the items it carries.
        var instanceIds = Set(local.instances.map(\.id))
        var orderedInstances: [ProviderInstance] = []
        var placedInstances = Set<String>()
        for ri in remote.instances {
            if let existing = local.instances.first(where: { $0.id == ri.id }) {
                orderedInstances.append(existing)
            } else {
                orderedInstances.append(ri)
                instanceIds.insert(ri.id)
            }
            placedInstances.insert(ri.id)
        }
        for li in local.instances where !placedInstances.contains(li.id) {
            orderedInstances.append(li)
        }
        local.instances = orderedInstances
        var entryIds = Set(local.modelEntries.map(\.id))
        for entry in remote.modelEntries where !entryIds.contains(entry.id) {
            local.modelEntries.append(entry)
            entryIds.insert(entry.id)
        }
        // [T-backup-restore-order] Same ordering rule as instances above:
        // groups are drag-reorderable too, so the package decides the position
        // of what it carries and local-only groups follow.
        var orderedGroups: [ModelGroup] = []
        var placedGroups = Set<String>()
        for rg in remote.modelGroups {
            if let existing = local.modelGroups.first(where: { $0.id == rg.id }) {
                orderedGroups.append(existing)
            } else {
                orderedGroups.append(rg)
            }
            placedGroups.insert(rg.id)
        }
        for lg in local.modelGroups where !placedGroups.contains(lg.id) {
            orderedGroups.append(lg)
        }
        local.modelGroups = orderedGroups
        // agent-loop bindings are additive sets; per-device pointers
        // (defaultPrimaryGroupId, voice*/visionGroupId, sessionBindings,
        // sessionInferenceConfigs) are intentionally NOT touched.
        local.agentLoopModelEntryIds = Array(
            Set(local.agentLoopModelEntryIds).union(remote.agentLoopModelEntryIds))
        local.agentLoopGroupIds = Array(
            Set(local.agentLoopGroupIds).union(remote.agentLoopGroupIds))

        store.applyConfig(local)
        logger.info("[Restore] provider merge (iOS16 path): instances=\(local.instances.count) entries=\(local.modelEntries.count) groups=\(local.modelGroups.count)")
    }

    // MARK: - MCP servers

    private func importMCPServers(root: URL) async throws -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.mcpServers.rawValue)
        let src = root.appendingPathComponent("data/mcp_servers.json")
        guard FileManager.default.fileExists(atPath: src.path) else { return report }
        let dst = MCPStore.syncFileURL
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
        // The store caches servers in memory; scanExternalChanges reloads from
        // disk, stamps updatedAt and marks each changed server dirty.
        await MainActor.run { MCPStore.shared.scanExternalChanges() }
        // Count the servers in the file, not the file itself — reporting 1
        // for any number of servers under-states the restore total. Same
        // lenient count the exporter uses for its manifest stat.
        // Fallback differs from the exporter's, deliberately: nil means the
        // file cannot be read as a servers file at all, and MCPStore loads
        // exactly 0 servers from such a file — reporting 1 here would claim
        // a restore that never happened.
        report.imported = BackupExporter.mcpServerCount(at: src) ?? 0
        return report
    }

    // MARK: - Environment variables

    /// MERGE, never replace.
    ///
    /// Restoring must not cost the user variables this device already has —
    /// including ones created after the backup was taken. So an existing key is
    /// left exactly as it is (entry AND value), and only genuinely new keys are
    /// added. That also makes restoring the same package twice a no-op.
    ///
    /// Values arrive separately, via secrets.json under the credential policy,
    /// and only in an encrypted package. A variable restored without its value
    /// is created with an empty one: visible in the list, flagged by its own
    /// empty state, and waiting to be filled in — which is far better than the
    /// variable not existing at all and the user not knowing it is missing.
    private func importEnvironmentVariables(root: URL) async throws -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.environmentVariables.rawValue)
        let src = root.appendingPathComponent("data/env_vars.json")
        guard FileManager.default.fileExists(atPath: src.path) else { return report }

        let data = try Data(contentsOf: src)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let incoming = try decoder.decode([EnvVarEntry].self, from: data)

        await MainActor.run {
            let store = EnvVarStore.shared
            let existing = Set(store.entries.map(\.key))
            for entry in incoming {
                guard !existing.contains(entry.key) else {
                    report.skipped += 1
                    continue
                }
                // The secrets importer may already have written this key's
                // value into the Keychain; keep it rather than blanking it.
                let value = EnvVarStore.loadValueSync(forKey: entry.key) ?? ""
                store.add(key: entry.key, value: value, note: entry.note)
                report.imported += 1
            }
        }
        return report
    }

    // MARK: - Voice corrections

    private func importVoiceCorrections(root: URL) async throws -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.voiceCorrections.rawValue)
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        guard let db = VoiceCorrectionDB.shared else {
            report.failed = "voice-correction DB unavailable"
            return report
        }

        struct ConfusionRecord: Codable {
            let id: String, phoneticKey: String, variants: [String], correctedTerm: String
            let locale: String, frequency: Int, negativeFeedbackCount: Int
            let confidence: Double, lastSeen: Double, source: String
        }
        struct VocabularyRecord: Codable {
            let id: String, term: String, phoneticKey: String, locale: String
            let posTag: String?, frequency: Int, distinctDays: Int
            let backgroundRank: Int?, lastSeen: Double, source: String
        }

        // NOTE: the DB exposes only aggregate upserts (they BUMP frequency
        // rather than setting it), so counters are not restored verbatim —
        // a restored dictionary keeps its terms but its frequencies re-converge
        // through use. Faithful counter restore needs a set-exact API; recorded
        // as a known limitation rather than silently pretending otherwise.
        for rec in readJSONL(dataDir, base: "voice_correction", as: ConfusionRecord.self)
        where !rec.correctedTerm.isEmpty {
            await db.upsertConfusion(
                phoneticKey: rec.phoneticKey,
                originalVariant: rec.variants.first ?? rec.correctedTerm,
                correctedTerm: rec.correctedTerm, locale: rec.locale,
                contextSample: nil, asrProvider: "restore", source: rec.source)
            report.imported += 1
        }
        for rec in readJSONL(dataDir, base: "voice_correction", as: VocabularyRecord.self)
        where !rec.term.isEmpty {
            await db.upsertVocabulary(
                term: rec.term, phoneticKey: rec.phoneticKey, locale: rec.locale,
                posTag: rec.posTag, backgroundRank: rec.backgroundRank,
                occurrences: max(rec.frequency, 1),
                day: Self.dayKey(from: rec.lastSeen))
            report.imported += 1
        }
        return report
    }

    private static func dayKey(from epoch: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date(timeIntervalSince1970: epoch))
    }

    // MARK: - Shared helpers

    /// The directory a category's restored files must stay inside.
    ///
    /// Single source of truth for the containment check below, kept next to it
    /// so a new category cannot be added with a destination mapping but no
    /// bound.
    func containmentRoot(for category: BackupCategory) -> URL {
        switch category {
        case .chats: return AIChatViewModel.minisPersistentBase
        case .sharedFiles: return AIChatViewModel.minisSharedPersistentDir
        case .skills: return AIChatViewModel.minisSkillsPersistentDir
        case .memory: return AIChatViewModel.minisMemoryPersistentDir
        case .appearance: return AppearanceStudio.appearanceAssetsDirectory
        case .providers, .mcpServers, .voiceCorrections, .environmentVariables:
            // These write single known files, not index-driven trees; give them
            // the app-group root so the check is still meaningful if one ever
            // starts using restoreFileTree.
            return AIChatViewModel.minisAppGroupRoot
        }
    }

    /// True when `url` really resolves inside `root`.
    ///
    /// Compares STANDARDIZED, SYMLINK-RESOLVED paths and requires a trailing
    /// separator on the prefix, so `/a/b-evil` is not accepted as being inside
    /// `/a/b`.
    ///
    /// The two steps are complementary and both are needed:
    ///   - `standardizedFileURL` is purely lexical — it collapses `.`, `..` and
    ///     redundant separators without touching the filesystem, and explicitly
    ///     does NOT resolve symlinks.
    ///   - `resolvingSymlinksInPath()` is the filesystem half. Without it a
    ///     symlink anywhere in the path (a parent component inside the root, or
    ///     the leaf itself) could point outside `root` while the lexical form
    ///     still looked contained. `minisAppGroupRoot`'s shared/skills/memory
    ///     are exposed to iOS Files via the FileProvider extension, so their
    ///     contents are not solely under this app's control.
    ///
    /// [T-ios-restore-symlink-containment] BOTH sides must be resolved, and
    /// resolving only one is worse than resolving neither. On iOS `/var` is a
    /// symlink to `/private/var`, and the container APIs
    /// (`containerURL(forSecurityApplicationGroupIdentifier:)`,
    /// `urls(for:.documentDirectory)`) hand back the UNRESOLVED `/var/…` form.
    /// Resolve just the target and it becomes `/private/var/…` while the base
    /// stays `/var/…`; the prefix test is then always false and every file in
    /// every category is rejected — i.e. restore silently stops working
    /// entirely. Resolving both keeps them in the same form.
    ///
    /// Note `resolvingSymlinksInPath()` leaves a non-existent trailing
    /// component untouched (it only resolves the portion that exists), so the
    /// normal case — writing a file that is not there yet — is unaffected.
    func isContained(_ url: URL, within root: URL) -> Bool {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        return target == base || target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// Write a category's files back out of `blobs/` using the index.
    /// - Parameter containmentRootOverride: the root that destinations must
    ///   stay inside. Defaults to `containmentRoot(for:)`, i.e. the real
    ///   category directory — production never passes this. It exists so tests
    ///   can exercise the blob-accounting logic against a temp directory
    ///   WITHOUT weakening the [B1] path-traversal guard, which would otherwise
    ///   reject every test destination before the code under test is reached.
    ///   The guard still runs; only the root it enforces is injectable.
    func restoreFileTree(root: URL,
                         fileIndex: [BackupFileIndexEntry],
                         category: BackupCategory,
                         containmentRootOverride: URL? = nil,
                         destinationFor: (String) -> URL?)
        throws -> (written: Int, bytes: Int64, missingBlobs: Int) {
        let fm = FileManager.default
        var written = 0
        var bytes: Int64 = 0
        var rejectedPaths = 0
        var missingBlobs = 0

        for entry in fileIndex where entry.category == category.rawValue {
            // §3.4 tombstones carry no content by design — counted, not written.
            if entry.skipped != nil { continue }
            guard let dest = destinationFor(entry.path) else { continue }

            // [T-ios-backup-restore-path-traversal] `entry.path` comes from
            // files.index.jsonl INSIDE the package, which is attacker-controlled
            // whenever a user restores a file someone sent them — and this
            // feature exists to accept packages from AirDrop / Files / share
            // links. `URL.appendingPathComponent` does not standardize, and
            // `copyItem` lets the kernel resolve `..`, so a path like
            // "chats/<sid>/../../../evil" resolved to <sandbox>/Library/evil
            // and wrote attacker bytes outside the intended directory.
            //
            // Note the ZIP extractor's own traversal guard does NOT cover this:
            // the archive's entry names are all benign (`blobs/<xx>/<sha>`) and
            // the malicious path lives in the index CONTENT.
            //
            // Containment is checked on the standardized path, which is what
            // the filesystem will actually use.
            guard isContained(dest, within: containmentRootOverride ?? containmentRoot(for: category)) else {
                logger.error("[Restore] REJECTED path escaping its category root: \(entry.path)")
                rejectedPaths += 1
                continue
            }

            if entry.isDirectory == true {
                try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                continue
            }
            guard let sha = entry.sha256 else { continue }
            let blob = root.appendingPathComponent("blobs")
                .appendingPathComponent(String(sha.prefix(2)))
                .appendingPathComponent(sha)
            // [review S7] The index says this file is in the package, but its
            // content blob isn't there. The export is not a snapshot: a file
            // written between the index pass and the blob copy can be recorded
            // and then not stored. This used to `continue` silently — the file
            // simply never appeared and the restore still reported success,
            // which is the one outcome a backup tool must never produce.
            // Counted here and surfaced in the report instead.
            guard fm.fileExists(atPath: blob.path) else {
                logger.warning("[Restore] index references a blob that is not in the package: \(entry.path) sha=\(sha.prefix(12))")
                missingBlobs += 1
                continue
            }

            try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            // Declared before the do block so its catch can clean the staged
            // temp up on failure (same shape as importMemory above); a
            // declaration inside do is invisible to the catch clause.
            let staged = dest.deletingLastPathComponent()
                .appendingPathComponent(".restore-\(UUID().uuidString).tmp")
            do {
                // [review I2] Stage next to the destination and swap, rather
                // than removeItem-then-copyItem. That pair left the user's file
                // NON-EXISTENT for the whole duration of the copy, so a jetsam
                // kill or crash in that window deleted it permanently with
                // nothing written back. The window was entered once per file,
                // and `.chats` / `.skills` / `.voiceCorrections` take no
                // rollback snapshot (snapshotForRollback excludes them so a
                // merge doesn't have to copy gigabytes aside), so for those
                // categories launch reconcile had nothing to restore and the
                // deletion was simply final. Merge idempotency does not help a
                // file that was deleted and never rewritten.
                try? fm.removeItem(at: staged)
                try fm.copyItem(at: blob, to: staged)
                if fm.fileExists(atPath: dest.path) {
                    _ = try fm.replaceItemAt(dest, withItemAt: staged)
                } else {
                    try fm.moveItem(at: staged, to: dest)
                }
                written += 1
                bytes += entry.size
            } catch {
                // Remove the staged temp: nothing else ever sweeps
                // `.restore-*.tmp`, so a failed copy/swap orphaned it next
                // to the destination and repeated failures accumulated
                // dead copies in the user's data directories. (importMemory's
                // identical staging above already cleans up in its catch.)
                try? fm.removeItem(at: staged)
                logger.warning("[Restore] write failed \(entry.path): \(error.localizedDescription)")
            }
        }
        if rejectedPaths > 0 {
            logger.error("[Restore] \(rejectedPaths) path(s) in \(category.rawValue) were rejected for escaping their root")
        }
        if missingBlobs > 0 {
            logger.error("[Restore] \(category.rawValue): \(missingBlobs) file(s) referenced by the index are MISSING from the package")
        }
        return (written, bytes, missingBlobs)
    }

    /// Read every shard of a JSONL stream, unwrapping the `t`/`v`/`d` envelope.
    func readJSONL<T: Codable>(_ dir: URL, base: String, as type: T.Type) -> [T] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0 == "\(base).jsonl" || ($0.hasPrefix("\(base)-") && $0.hasSuffix(".jsonl")) }
            .sorted()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [T] = []
        for name in names {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { continue }
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                // Per-line tolerance (§2.2 rule 3): a record this build cannot
                // parse is skipped, and the rest of the file still imports.
                if let env = try? decoder.decode(BackupRecordEnvelope<T>.self, from: Data(line)) {
                    out.append(env.d)
                }
            }
        }
        return out
    }

    private func encodeParts(_ parts: [ContentPart]) -> String? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let d = try? e.encode(parts) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private func encodeTokenUsage(_ usage: StoredTokenUsage?) -> String? {
        guard let usage else { return nil }
        let e = JSONEncoder()
        guard let d = try? e.encode(usage) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    // MARK: - Store reloads (§8.1)

    func reloadStores(for categories: Set<BackupCategory>) async {
        if categories.contains(.skills) {
            await MainActor.run { SkillStore.shared.reload() }
        }
        if categories.contains(.appearance) {
            // Covers packages whose appearance half is files only (no
            // settings file): the live studio must still drop its cached
            // wallpapers and re-read the icons the restore just wrote.
            await MainActor.run { AppearanceStudio.shared.reloadAfterRestore() }
        }
        if categories.contains(.chats) {
            // One batch signal is enough to refresh everything chat-related.
            await MainActor.run {
                NotificationCenter.default.post(name: .cloudSyncDidFetchChanges, object: nil)
            }
        }
    }
}
