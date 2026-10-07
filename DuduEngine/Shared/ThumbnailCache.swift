import UIKit

/// Thread-safe thumbnail cache with async loading and downsampling.
/// Used by tool capsule previews and browser screenshots to avoid
/// synchronous UIImage(contentsOfFile:) on the main thread during scrolling.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "ThumbnailCache.load", qos: .userInitiated, attributes: .concurrent)
    /// Tracks in-flight loads to avoid duplicate work for the same path.
    private var inFlight = Set<String>()
    /// Completions waiting on an in-flight load, keyed by cache key. Every
    /// waiter is called with the load's result when it finishes — however
    /// long the decode takes.
    private var waiters: [String: [(UIImage?) -> Void]] = [:]
    /// [PIC-1] path → live cache keys, so `removeThumbnail(for:)` can drop
    /// every maxSize variant of one file when it is replaced or deleted.
    private var pathIndex: [String: Set<String>] = [:]
    private let lock = NSLock()

    private init() {
        cache.countLimit = 100
        cache.totalCostLimit = 50 * 1024 * 1024 // ~50MB

        // Auto-clear on memory warning
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.removeAll()
        }

        // Clear when app enters background — free memory for other apps
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.removeAll()
        }
    }

    // MARK: - Sync (cache-only)

    /// Returns the cached thumbnail if available, nil otherwise.
    func cachedThumbnail(for path: String, maxSize: CGFloat = 400) -> UIImage? {
        let key = cacheKey(path: path, maxSize: maxSize)
        return cache.object(forKey: key as NSString)
    }

    // MARK: - Async Load

    /// Load a thumbnail asynchronously.  Returns immediately with a cached
    /// image if available; otherwise loads + downsamples on a background
    /// queue and calls `completion` on the main thread.
    func loadThumbnail(
        for path: String,
        maxSize: CGFloat = 400,
        completion: @escaping (UIImage?) -> Void
    ) {
        let key = cacheKey(path: path, maxSize: maxSize)

        // Check cache first
        if let cached = cache.object(forKey: key as NSString) {
            completion(cached)
            return
        }

        // Check if already loading — register as a waiter instead of polling:
        // the in-flight load calls every waiter with its result on completion.
        lock.lock()
        if inFlight.contains(key) {
            waiters[key, default: []].append(completion)
            lock.unlock()
            return
        }
        inFlight.insert(key)
        lock.unlock()

        // Load on background queue
        queue.async { [weak self] in
            guard let self else { return }
            let image = Self.loadAndDownsample(path: path, maxSize: maxSize)

            if let image {
                self.store(image, for: path, maxSize: maxSize)
            }

            self.lock.lock()
            self.inFlight.remove(key)
            let pending = self.waiters.removeValue(forKey: key) ?? []
            self.lock.unlock()

            DispatchQueue.main.async {
                completion(image)
                for waiter in pending { waiter(image) }
            }
        }
    }

    // MARK: - SwiftUI async

    /// Async version for use with SwiftUI's .task modifier.
    @MainActor
    func thumbnail(for path: String, maxSize: CGFloat = 400) async -> UIImage? {
        let key = cacheKey(path: path, maxSize: maxSize)

        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        return await withCheckedContinuation { continuation in
            loadThumbnail(for: path, maxSize: maxSize) { image in
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - Direct (for UIImage at URL)

    /// [PIC-4] Decode `data` to at most `maxEdge` on the long side WITHOUT
    /// decoding the full image first: read the pixel size from the file
    /// header, and only when it exceeds the cap, ask ImageIO for a
    /// thumbnail (which downsamples during decode). Used by the image
    /// pickers (wallpaper / avatar / cards): the old path ran
    /// `UIImage(data:)` on the full file, so a 48 MP photo expanded to
    /// ~200 MB of bitmap before the apply step scaled it back down.
    /// Animated sources flatten to the first frame — correct here, since
    /// every picker target is a still image.
    static func downsampledImage(from data: Data, maxEdge: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
           max(w, h) <= maxEdge {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    /// Load a thumbnail from a file URL.
    func loadThumbnail(
        for url: URL,
        maxSize: CGFloat = 400,
        completion: @escaping (UIImage?) -> Void
    ) {
        loadThumbnail(for: url.path, maxSize: maxSize, completion: completion)
    }

    /// Sync cached lookup by URL.
    func cachedThumbnail(for url: URL, maxSize: CGFloat = 400) -> UIImage? {
        cachedThumbnail(for: url.path, maxSize: maxSize)
    }

    // MARK: - Eviction

    func removeAll() {
        lock.lock()
        pathIndex.removeAll()
        lock.unlock()
        cache.removeAllObjects()
    }

    /// [PIC-1] Synchronously store a decoded image (e.g. a settings
    /// surface that already decoded the file on its own path).
    func store(_ image: UIImage, for path: String, maxSize: CGFloat = 400) {
        let key = cacheKey(path: path, maxSize: maxSize)
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
        lock.lock()
        pathIndex[path, default: []].insert(key)
        lock.unlock()
    }

    /// [PIC-1] Drop every cached variant of `path` — call when the file is
    /// replaced or deleted so the old image is never served again.
    func removeThumbnail(for path: String) {
        lock.lock()
        let keys = pathIndex.removeValue(forKey: path) ?? []
        lock.unlock()
        for key in keys { cache.removeObject(forKey: key as NSString) }
    }

    // MARK: - Private

    private func cacheKey(path: String, maxSize: CGFloat) -> String {
        // Include the file's size + modification time so overwriting the file
        // at the same path produces a different key — a path-only key would
        // keep serving the old image until eviction/memory-warning/background.
        // A missing file stamps as 0:0, which simply never matches a real load.
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "thumb:\(Int(maxSize)):\(path):\(size):\(mtime)"
    }

    /// Load image from disk and downsample to maxSize using ImageIO.
    /// This avoids decoding the full image into memory.
    private static func loadAndDownsample(path: String, maxSize: CGFloat) -> UIImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            // Fallback: try loading full image (for formats ImageIO doesn't thumbnail)
            guard let data = try? Data(contentsOf: url),
                  let img = UIImage(data: data) else { return nil }
            return img
        }

        return UIImage(cgImage: cgImage)
    }
}
