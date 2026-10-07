import Foundation

// MARK: - Image text-result cache (IMG-9 / [s2-ocr])
//
// Two-layer cache for image→text results, keyed by the SHA-256 of the ORIGINAL
// image bytes (so the same picture re-read from a different path still hits).
// Layer 1 is an in-memory LRU (48 entries — the same bound Kelivo's OCR cache
// uses); layer 2 is JSON files under Caches/MinisImageTextCache (system-
// purgeable, the right semantics for a cache), mirroring TTSDiskCache's
// shape and bounds logic.
//
// What gets cached is the TIER OUTCOME, not just OCR text: a "localOCR"
// entry holds on-device Vision transcription, a "visionGroup" entry holds
// the describing model's text. Either way a repeat read of the same image
// costs nothing — no local work and, more importantly, no model quota.
enum ImageTextCache {

    /// Which tier of the [s2-ocr] ladder produced the cached text.
    enum Source: String, Codable {
        case localOCR
        case visionGroup
    }

    struct Entry: Codable {
        let text: String
        let source: Source
        /// The describing model's display name; set only for visionGroup entries.
        let modelName: String?
        /// Unix timestamp, for future TTL / debugging use.
        let storedAt: TimeInterval
    }

    // MARK: - Memory layer (LRU, 48)

    private static let memoryLimit = 48

    /// NSCache is thread-safe; countLimit gives us the LRU-ish bound.
    /// NSCache evicts "least recently used" first under pressure, which is
    /// close enough to Kelivo's explicit LRU for a 48-entry cache.
    private static let memory: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = memoryLimit
        return c
    }()

    private final class Box {
        let entry: Entry
        init(_ entry: Entry) { self.entry = entry }
    }

    // MARK: - Disk layer

    private static let maxEntries = 500
    private static let maxBytes = 10 * 1024 * 1024  // text is small; 10 MB is generous

    private static let queue = DispatchQueue(label: "minis.ocr.textcache")

    private static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MinisImageTextCache", isDirectory: true)
    }

    private static func fileURL(for key: String) -> URL {
        // Keys are sha256 hex built by the caller; sanitize anyway so a key
        // can never escape the cache directory.
        let safe = key.filter { $0.isLetter || $0.isNumber }
        return directory.appendingPathComponent(safe.isEmpty ? "empty" : safe, isDirectory: false)
    }

    // MARK: - Public API

    static func get(key: String) -> Entry? {
        if let box = memory.object(forKey: key as NSString) {
            return box.entry
        }
        return queue.sync {
            let url = fileURL(for: key)
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  !entry.text.isEmpty else { return nil }
            // Touch mtime so LRU eviction reflects replay value; backfill memory.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            memory.setObject(Box(entry), forKey: key as NSString)
            return entry
        }
    }

    static func store(key: String, entry: Entry) {
        guard !entry.text.isEmpty else { return }
        memory.setObject(Box(entry), forKey: key as NSString)
        queue.sync {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(entry),
                  data.count <= maxBytes else { return }
            try? data.write(to: fileURL(for: key), options: .atomic)
            pruneLocked()
        }
    }

    static func clearAll() {
        memory.removeAllObjects()
        queue.sync {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Internals (call on `queue`)

    private static func entriesLocked() -> [(url: URL, size: Int, mtime: Date)] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return files.compactMap { url in
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = v?.fileSize else { return nil }
            return (url, size, v?.contentModificationDate ?? .distantPast)
        }
    }

    private static func pruneLocked() {
        var entries = entriesLocked().sorted { $0.mtime < $1.mtime }  // oldest first
        var total = entries.reduce(0) { $0 + $1.size }
        while (total > maxBytes || entries.count > maxEntries), let victim = entries.first {
            entries.removeFirst()
            total -= victim.size
            try? FileManager.default.removeItem(at: victim.url)
        }
    }
}
