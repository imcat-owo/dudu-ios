import Foundation

/// Reads and writes PendingShare data to the App Group shared container.
/// Compiled into both the main app target and the Share Extension target.
enum SharedContainerStore {
    static let appGroupID = "group.com.openminis.clone"

    /// A sideloaded clone may be signed without the App Group capability.
    /// Fall back to this app's own Application Support directory instead of crashing.
    static var containerURL: URL {
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            return group
        }
        logAppGroupFallbackOnce()
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("OpenMinisClone", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// The per-process fallback above prevents a crash, but the main app
    /// and the Share Extension then write to DIFFERENT stores and can
    /// never see each other's pending shares — sharing is dead with no
    /// other symptom. Log it loudly (once per process; this file is
    /// compiled into both targets and NSLog is the common denominator)
    /// so the failure is at least diagnosable.
    private static var didLogAppGroupFallback = false
    private static func logAppGroupFallbackOnce() {
        guard !didLogAppGroupFallback else { return }
        didLogAppGroupFallback = true
        NSLog("[Share] ERROR: App Group container '\(appGroupID)' is unavailable (capability missing from this build's signature?) — falling back to per-process storage; the main app and the Share Extension will NOT see each other's pending shares.")
    }

    private static let pendingShareKey = "pendingShare"

    static var sharedDefaults: UserDefaults? {
        guard FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) != nil else {
            logAppGroupFallbackOnce()
            return .standard
        }
        return UserDefaults(suiteName: appGroupID)
    }

    /// Directory in the shared container for transferring attachment files.
    static var sharedFileDirectory: URL? {
        containerURL.appendingPathComponent("ShareExtension", isDirectory: true)
    }

    // MARK: - Write (called by Share Extension)

    static func savePendingShare(_ share: PendingShare) {
        guard let defaults = sharedDefaults else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(share) {
            defaults.set(data, forKey: pendingShareKey)
            defaults.synchronize()
        }
    }

    // MARK: - Read & Consume (called by main app)

    static func loadPendingShare() -> PendingShare? {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: pendingShareKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingShare.self, from: data)
    }

    static func clearPendingShare() {
        sharedDefaults?.removeObject(forKey: pendingShareKey)
        sharedDefaults?.synchronize()
    }

    /// Remove all files from the shared transfer directory.
    static func cleanSharedFiles() {
        guard let dir = sharedFileDirectory else { return }
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
    }
}
