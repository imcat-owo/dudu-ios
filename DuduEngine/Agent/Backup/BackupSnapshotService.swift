import Foundation

private let logger = AppLogger(category: "Backup")

/// [第20条 · 快照半边] Automatic on-device snapshots: the safety net
/// between manual backups.
///
/// A manual backup only exists when the user remembers to make one, so
/// the failure this guards against is "the data broke / the phone was
/// reset, and the newest package is weeks old". The app therefore takes
/// a snapshot by itself — a full package built by the SAME
/// `BackupExporter` a manual run uses, so there is exactly one packaging
/// implementation to trust — and keeps it in the same delivered-packages
/// folder, renamed with a `snapshot-` prefix. The existing restore flow
/// picks `.minisbak` files from Files, and the Backups folder is visible
/// there, so a snapshot is restorable with no new UI; snapshot runs also
/// appear in Backup History like any other run, first log line
/// "Automatic snapshot".
///
/// Deliberate scope limits (the other half of 第20条 — importing OTHER
/// apps' backups — is not built):
///   * On-device only. Nothing is uploaded anywhere; destinations and
///     delivery are the manual flow's job.
///   * Credentials are NOT included. A snapshot is an unencrypted
///     package sitting in user-visible storage; the manual flow only
///     ships secrets inside an encrypted package, and a same-device
///     restore keeps the Keychain anyway.
///   * No settings UI. Whether a toggle should exist is a product
///     decision, not made here.
/// [P3-10] That decision is now made: Backup settings has an Automatic
/// Snapshots switch (default ON) plus the current storage footprint, and
/// the switch gates both triggers in `scheduleCheck` below.
///
/// Triggering follows the Kelivo snapshot shape: shortly after launch
/// (≈8s) and after returning to the foreground (≈3s) the service checks
/// whether the newest snapshot is still fresh; if not, it takes one.
/// The required freshness interval grows with the size of the last
/// snapshot (bigger data → rarer snapshots), so a large install doesn't
/// pay a full export every day.
@MainActor
final class BackupSnapshotService {
    static let shared = BackupSnapshotService()

    /// Package-name prefix marking a delivered package as a snapshot.
    /// Cosmetic only — retention never trusts the name alone (a hand-made
    /// backup can be named `snapshot-…` by its device name or by renaming),
    /// it only ever touches names recorded in the snapshot manifest below.
    static let filePrefix = "snapshot-"

    /// Name of the snapshot ledger kept next to the packages.
    /// `listSnapshots` only recognises files whose names are in here AND
    /// exist on disk; retention only deletes ledger entries. A hand-made
    /// backup is never in the ledger, so it can never be pruned — even when
    /// its filename starts with `snapshot-`.
    private static let manifestFileName = "snapshot-manifest.json"

    /// [P3-10] UserDefaults key for the Automatic Snapshots switch in
    /// Backup settings. Default ON: the snapshot is the safety net this
    /// feature was built as, and the switch is how the user opts out.
    nonisolated static let automaticSnapshotsEnabledKey = "backup.automaticSnapshots"

    /// [P3-10] Whether the launch / foreground freshness checks may take
    /// snapshots. `nonisolated`: UserDefaults is thread-safe, and the
    /// settings UI reads this outside the service's actor.
    nonisolated static var isAutomaticSnapshotEnabled: Bool {
        get { UserDefaults.standard.object(forKey: automaticSnapshotsEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: automaticSnapshotsEnabledKey) }
    }

    private var pendingCheck: Task<Void, Never>?
    /// The export actually running, if any — a separate handle from
    /// `pendingCheck`, which only ever carries the scheduled wait (P2-2).
    /// Also the handle handed to BackupRunController, so Stop can reach a
    /// snapshot the same way it reaches a manual run (P2-1).
    private var snapshotTask: Task<Void, Never>?
    private var isSnapshotting = false

    private init() {}

    // MARK: - Triggers

    /// Called once the app has launched and settled.
    func scheduleLaunchCheck() { scheduleCheck(after: 8) }

    /// Called when the app returns to the foreground.
    func scheduleForegroundCheck() { scheduleCheck(after: 3) }

    private func scheduleCheck(after delay: TimeInterval) {
        // [P3-10] The user can switch automatic snapshots off in Settings;
        // off means no new snapshots from either trigger (launch or
        // foreground). Existing snapshots are kept — the switch stops
        // future ones, it doesn't delete anything.
        guard Self.isAutomaticSnapshotEnabled else { return }
        // P2-2: never touch a snapshot that is already running. The old code
        // used one handle for both the scheduled wait and the export, so a
        // fresh trigger during a long export cancelled it mid-flight — and
        // the replacement check then died on the isSnapshotting guard,
        // silently losing the round. While an export runs, a new trigger is
        // simply ignored; the export itself will satisfy freshness.
        guard !isSnapshotting else { return }
        pendingCheck?.cancel()
        pendingCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Fired: drop the handle so a later scheduleCheck can't cancel a
            // task that already did its job.
            self?.pendingCheck = nil
            await self?.checkAndSnapshotIfDue()
        }
    }

    // MARK: - Decision (pure, so the shape can be reviewed without a device)

    struct SnapshotFile {
        let url: URL
        let date: Date
        let bytes: Int64
    }

    /// Snapshots in `dir`, newest first. A file counts as a snapshot only if
    /// its name is recorded in the snapshot manifest (written when the
    /// service itself creates the package) AND the file still exists — the
    /// filename prefix alone is forgeable and is never trusted on the
    /// normal path.
    ///
    /// [P3-10] A missing or unreadable manifest used to mean zero
    /// recognised snapshots: old snapshot files silently stopped being
    /// listed AND pruned, so they piled up forever with no way for the
    /// user to see or delete them. That case now falls back to the
    /// `snapshot-` filename prefix (snapshot packages are `.minisbak`
    /// files renamed with that prefix at creation time, so the scan finds
    /// exactly the files this service made), and anything found is
    /// re-registered into a rebuilt manifest — back on the trusted ledger
    /// path from here on. A manifest that EXISTS but is empty still means
    /// "no snapshots": an explicit empty ledger is not a lost one.
    static func listSnapshots(in dir: URL) -> [SnapshotFile] {
        let fm = FileManager.default
        let names: Set<String>
        if let ledger = manifestNamesIfPresent(in: dir) {
            names = Set(ledger)
        } else {
            let recovered = snapshotNamesByPrefix(in: dir)
            if !recovered.isEmpty {
                writeManifest(recovered, in: dir)
            }
            names = Set(recovered)
        }
        guard !names.isEmpty else { return [] }
        var out: [SnapshotFile] = []
        for name in names {
            let url = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let date = attrs?[.modificationDate] as? Date
                ?? attrs?[.creationDate] as? Date ?? .distantPast
            let bytes = attrs?[.size] as? Int64 ?? 0
            out.append(SnapshotFile(url: url, date: date, bytes: bytes))
        }
        return out.sorted { $0.date > $1.date }
    }

    // MARK: - Snapshot ledger

    private static func manifestURL(in dir: URL) -> URL {
        dir.appendingPathComponent(manifestFileName)
    }

    private static func manifestNames(in dir: URL) -> [String] {
        guard let data = try? Data(contentsOf: manifestURL(in: dir)),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return names
    }

    /// [P3-10] The ledger, or nil when it is missing / unreadable / corrupt —
    /// deliberately distinct from "present but empty", which is a valid
    /// state meaning no snapshots are tracked. Only the nil case takes the
    /// filename-prefix fallback in `listSnapshots`.
    private static func manifestNamesIfPresent(in dir: URL) -> [String]? {
        let url = manifestURL(in: dir)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        return names
    }

    /// [P3-10] Filename-prefix fallback, used ONLY when the manifest is
    /// gone: snapshot packages are `.minisbak` files renamed with the
    /// `snapshot-` prefix at creation time, so this scan finds exactly the
    /// files this service made. (A hand-made backup deliberately renamed
    /// to `snapshot-….minisbak` would also match — acceptable: the user
    /// chose that name, retention only ever deletes per policy, and the
    /// alternative is invisible, undeletable piles.)
    private static func snapshotNamesByPrefix(in dir: URL) -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return urls.map(\.lastPathComponent)
            .filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(".minisbak") }
    }

    private static func writeManifest(_ names: [String], in dir: URL) {
        guard let data = try? JSONEncoder().encode(names.sorted()) else { return }
        try? data.write(to: manifestURL(in: dir), options: .atomic)
    }

    /// Record a freshly created snapshot. Called exactly once per package,
    /// after the move into `dir` succeeded.
    static func registerSnapshot(named name: String, in dir: URL) {
        var names = Set(manifestNames(in: dir))
        names.insert(name)
        writeManifest(Array(names), in: dir)
    }

    /// Drop ledger entries for packages retention deleted (or that are gone
    /// for any other reason), so the manifest never references dead files.
    static func unregisterSnapshots(named names: Set<String>, in dir: URL) {
        let remaining = Set(manifestNames(in: dir)).subtracting(names)
        writeManifest(Array(remaining), in: dir)
    }

    /// How old the newest snapshot may get before another is due, scaled
    /// by how big the last one was.
    static func minimumInterval(forSnapshotBytes bytes: Int64) -> TimeInterval {
        let mb: Int64 = 1024 * 1024
        switch bytes {
        case ..<(200 * mb): return 24 * 3600
        case ..<(1024 * mb): return 48 * 3600
        default: return 72 * 3600
        }
    }

    static func isDue(now: Date, snapshots: [SnapshotFile]) -> Bool {
        guard let newest = snapshots.first else { return true }
        return now.timeIntervalSince(newest.date)
            >= minimumInterval(forSnapshotBytes: newest.bytes)
    }

    /// Retention: the newest 7 snapshots stay. Beyond that batch, one
    /// weekly keeper (the newest remaining snapshot at least 7 days old)
    /// and one monthly keeper (the newest remaining at least 30 days
    /// old) survive; every other snapshot is deleted. The keepers are
    /// picked from OUTSIDE the batch — if the batch itself already
    /// reaches back 7 days, the weekly slot still goes to the next one
    /// out, so the long tail doesn't thin out. At most 9 packages ever
    /// accumulate.
    static func retentionDeletions(_ snapshots: [SnapshotFile], now: Date) -> [URL] {
        var keep = Set<URL>()
        for s in snapshots.prefix(7) { keep.insert(s.url) }
        let day: TimeInterval = 24 * 3600
        if let weekly = snapshots.first(where: {
            !keep.contains($0.url) && now.timeIntervalSince($0.date) >= 7 * day
        }) {
            keep.insert(weekly.url)
        }
        if let monthly = snapshots.first(where: {
            !keep.contains($0.url) && now.timeIntervalSince($0.date) >= 30 * day
        }) {
            keep.insert(monthly.url)
        }
        return snapshots.filter { !keep.contains($0.url) }.map(\.url)
    }

    // MARK: - Taking a snapshot

    private func checkAndSnapshotIfDue() async {
        guard !isSnapshotting else { return }
        let dir = BackupDelivery.backupsDirectory
        let existing = Self.listSnapshots(in: dir)
        guard Self.isDue(now: Date(), snapshots: existing) else {
            logger.info("[Backup] snapshot still fresh — skipping check")
            return
        }
        // A user-started backup owns the machinery; the export lock would
        // refuse a second run anyway, but bowing out here keeps the
        // history free of a failed record for a non-event.
        guard !BackupRunController.shared.isRunning else {
            logger.info("[Backup] snapshot due but a backup is already running — skipping")
            return
        }
        isSnapshotting = true
        defer { isSnapshotting = false }
        // P2-1: the export runs in its own task (not inside the scheduling
        // task, see P2-2) and is registered with the run controller, so the
        // settings page shows the snapshot in flight and a user tap during
        // it can't start a second export that only collides with the export
        // lock and leaves a bogus "manual backup failed" history entry.
        let export = Task { [weak self] in
            _ = await self?.takeSnapshot(in: dir)
        }
        snapshotTask = export
        defer { snapshotTask = nil }
        guard BackupRunController.shared.started(task: export) else {
            // Lost the race to a manual run that started after the isRunning
            // check above; started() already cancelled `export`, which never
            // opened a history record.
            logger.info("[Backup] snapshot skipped — a backup started first")
            return
        }
        await export.value
    }

    private func takeSnapshot(in dir: URL) async {
        let categories = Set(BackupCategory.backupable)
        let options = BackupExporter.Options(
            categories: categories,
            maxFileBytes: nil,
            includeCredentials: false,
            passphrase: nil,
            allowResume: false)
        let runId = BackupHistory.shared.begin(
            backupId: "", categories: categories.map(\.rawValue).sorted(),
            encrypted: false)
        BackupHistory.shared.log(runId, AppLocalized("Automatic snapshot"))
        // P2-1: point the controller at this run's real history record, and
        // clear the running state on EVERY exit path. Token-guarded (same
        // pattern as the manual flow): a refused start reaching this defer
        // must not tear down the run that legitimately owns the controller.
        BackupRunController.shared.attach(recordId: runId)
        let token = BackupRunController.shared.currentToken
        defer { BackupRunController.shared.finished(token: token) }
        do {
            let summary = try await BackupBackgroundAssertion.run("BackupSnapshot") {
                try await BackupExporter().export(options: options) { _ in
                } progressDetailed: { _, _ in }
            }
            let stable = try BackupDelivery.moveToVisibleStorage(summary.packageURL)
            let snapURL = dir.appendingPathComponent(Self.filePrefix + stable.lastPathComponent)
            try? FileManager.default.removeItem(at: snapURL)
            try FileManager.default.moveItem(at: stable, to: snapURL)
            Self.registerSnapshot(named: snapURL.lastPathComponent, in: dir)
            BackupHistory.shared.finish(
                runId, totalBytes: summary.totalBytes,
                skippedFiles: summary.skippedFiles,
                packageName: snapURL.lastPathComponent, destinations: [],
                skippedEntries: summary.skippedPaths.map { skipped -> BackupHistory.SkippedEntry in
                    BackupHistory.SkippedEntry(path: skipped.path, size: skipped.size, sessionTitle: nil)
                })
            logger.info("[Backup] snapshot written: \(snapURL.lastPathComponent) (\(summary.totalBytes) bytes)")
            pruneSnapshots(in: dir)
        } catch let busy as BackupActivityLock.Busy {
            // Lost a race with a manual run that started after the check
            // above. Not a failure — leave no history record behind.
            BackupHistory.shared.remove(runId)
            logger.info("[Backup] snapshot skipped: \(busy.errorDescription ?? "busy")")
        } catch is CancellationError {
            BackupHistory.shared.remove(runId)
            logger.info("[Backup] snapshot cancelled")
        } catch {
            // [P3-11] The user never started this run — a "failed" history
            // entry for an automatic snapshot they didn't ask for reads as
            // something THEY did wrong. Same shape as the busy / cancelled
            // branches above: leave no history record behind, keep it in
            // the log.
            BackupHistory.shared.remove(runId)
            logger.error("[Backup] snapshot failed: \(error.localizedDescription)")
        }
    }

    private func pruneSnapshots(in dir: URL) {
        let snapshots = Self.listSnapshots(in: dir)
        var deleted = Set<String>()
        for url in Self.retentionDeletions(snapshots, now: Date()) {
            do {
                try FileManager.default.removeItem(at: url)
                deleted.insert(url.lastPathComponent)
                logger.info("[Backup] snapshot pruned: \(url.lastPathComponent)")
            } catch {
                logger.error("[Backup] snapshot prune failed: \(url.lastPathComponent) — \(error.localizedDescription)")
            }
        }
        if !deleted.isEmpty {
            Self.unregisterSnapshots(named: deleted, in: dir)
        }
    }
}
