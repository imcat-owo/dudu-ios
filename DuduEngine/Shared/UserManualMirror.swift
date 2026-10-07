import Foundation

// MARK: - User-manual mirror for the agent
//
// [T-manual-agent-visibility 09-12] 醒醒 3：「使用手册是给 ai 看的不是给醒醒看的。
// 如果 ai 可以看见那就没问题。」Applying manual renders from Bundle.main — but
// the agent's file tools ONLY see /var/minis/** (the shell rootfs has no view of
// the app bundle), so the in-bundle manual was invisible to the agent.
//
// Fix: mirror the bundled user-manual.md into the SHARED app-group dir at launch
// (host side: MinisAppGroupRoot/shared/user-manual.md ⇔ iSH side:
// /var/minis/shared/user-manual.md). The mirror is refreshed on every launch,
// so a bundle update re-publishes itself; an agent edit to the mirrored file
// survives until the next launch re-syncs (documented in the system prompt
// pointer so the agent knows the bundle copy is authoritative).

enum UserManualMirror {
    private static let fileName = "user-manual.md"

    /// Host URL the agent sees as /var/minis/shared/user-manual.md.
    static var mirroredURL: URL {
        AIChatViewModel.minisSharedPersistentDir.appendingPathComponent(fileName)
    }

    /// Linux path advertised to the agent.
    static let linuxPath = "/var/minis/shared/user-manual.md"

    /// Copy the bundled manual over the mirror when their contents differ.
    /// Cheap: both files are tens of KB; compare via data equality, skip the
    /// write when identical (keeps mtime stable so agent caches don't churn).
    static func syncFromBundle() {
        guard let bundleURL = Bundle.main.url(forResource: "user-manual", withExtension: "md"),
              let bundleData = try? Data(contentsOf: bundleURL) else {
            AppLogger(category: "ManualMirror").warning("manual mirror: bundle manual missing")
            return
        }
        let fm = FileManager.default
        let dest = mirroredURL
        do {
            try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if let existing = try? Data(contentsOf: dest), existing == bundleData { return }
            try bundleData.write(to: dest, options: .atomic)
            AppLogger(category: "ManualMirror").info("manual mirror synced (\(bundleData.count) bytes → \(dest.path))")
        } catch {
            AppLogger(category: "ManualMirror").warning("manual mirror write failed: \(error.localizedDescription)")
        }
    }
}
