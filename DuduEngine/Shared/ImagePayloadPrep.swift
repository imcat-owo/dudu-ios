import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Unified image preparation for anything that enters a model's context.
///
/// [GAP-REVIEW IMG-1/2/3/4] Before this type existed, every image entry
/// point (fresh send, queued send, history reload, each provider's wire
/// conversion) prepared payloads its own way — or not at all:
///
///   * HEIC/PNG bytes went out labelled `image/jpeg` because the mime was
///     derived from the file extension or a "did the byte count change"
///     guess instead of the bytes themselves (IMG-1).
///   * The per-image 5 MB budget was a warning, not a cap — oversize
///     payloads were "sent anyway", and once persisted to history they
///     re-failed the request on every subsequent turn, permanently
///     poisoning the session (IMG-2).
///   * The queued-send path had no byte budget at all, and history reload
///     passed stored bytes through untouched (IMG-4 / IMG-2a).
///   * Gemini/Antigravity exits had no payload safeguards, and
///     Anthropic/Gemini/Antigravity had no vision-capability gate —
///     images went to text-only models raw (IMG-3).
///
/// The rule now, applied at every entry point via this one type:
///
///   1. The mime label is ALWAYS derived from the payload's magic bytes
///      (sniffing), never from a filename or a stored string.
///   2. A payload passes through untouched ONLY when its sniffed format
///      is in the caller's accepted set, its long edge is within
///      `contextMaxLongEdge`, and it fits the byte budget. This preserves
///      transparent PNGs and animated GIFs whenever they fit (they would
///      lose alpha/animation in a JPEG re-encode).
///   3. Anything else is re-encoded to JPEG at or under the caps (label
///      `image/jpeg` then genuinely describes the bytes). Animated or
///      transparent images that DON'T fit are flattened to their first
///      frame — a deliberate trade: a flattened image beats a rejected
///      request.
///   4. If the payload cannot be made compliant (undecodable, or still
///      over budget at the bottom of the quality ladder) the result is
///      `nil` and the CALLER degrades that image to a text placeholder.
///      Non-compliant bytes never leave the process.
enum ImagePayloadPrep {

    /// Long-edge cap for images entering model context. 1536 matches the
    /// scale mainstream vision APIs use internally (Anthropic's standard
    /// tier resizes to ≤1568px anyway), keeps small UI text legible, and
    /// bounds per-image tokens.
    static let contextMaxLongEdge: CGFloat = 1536

    /// Per-image byte budget (base64 inflates ~4/3×, so 5 MB of bytes is
    /// ~6.7 MB on the wire — comfortably inside every provider's limit).
    static let contextMaxBytes: Int = 5 * 1024 * 1024

    /// Formats Anthropic / OpenAI accept for image input.
    static let standardPassthroughFormats: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp",
    ]

    /// Gemini additionally accepts HEIC/HEIF natively.
    static let geminiPassthroughFormats: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp",
        "image/heic", "image/heif",
    ]

    // MARK: - Format sniffing

    /// Detect the real image format from magic bytes. Returns nil when the
    /// leading bytes match no known image signature.
    static func sniffMimeType(_ data: Data) -> String? {
        guard data.count >= 3 else { return nil }
        let b = [UInt8](data.prefix(16))
        // JPEG: FF D8 FF
        if b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return "image/jpeg" }
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if data.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47,
           b[4] == 0x0D, b[5] == 0x0A, b[6] == 0x1A, b[7] == 0x0A { return "image/png" }
        // GIF: "GIF8"
        if data.count >= 4, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return "image/gif" }
        // WebP: "RIFF" .... "WEBP"
        if data.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        // ISO-BMFF (HEIC/HEIF/AVIF): "ftyp" box + brand
        if data.count >= 12, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let brand = String(bytes: b[8..<12], encoding: .ascii) ?? ""
            switch brand {
            case "heic", "heix", "hevc", "heim", "heis", "hevm", "hevs":
                return "image/heic"
            case "mif1", "msf1", "heif":
                return "image/heif"
            case "avif", "avis":
                return "image/avif"
            default:
                return nil
            }
        }
        // TIFF: 49 49 2A 00 / 4D 4D 00 2A
        if data.count >= 4,
           (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0x00)
            || (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0x00 && b[3] == 0x2A) { return "image/tiff" }
        // BMP: "BM"
        if data.count >= 2, b[0] == 0x42, b[1] == 0x4D { return "image/bmp" }
        return nil
    }

    // MARK: - Header inspection (no full decode)

    /// Pixel dimensions from the image header via ImageIO properties.
    static func pixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? NSNumber,
              let h = props[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        return CGSize(width: w.doubleValue, height: h.doubleValue)
    }

    /// Number of frames (1 for still images; >1 for animated GIF/WebP).
    static func frameCount(_ data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    // MARK: - The unified preparation

    /// Prepare one image payload for model context under the rules in the
    /// type docstring. Returns the (possibly original) bytes plus the mime
    /// that truthfully describes them, or nil when the image cannot be
    /// made compliant — the caller MUST degrade to a text placeholder on
    /// nil rather than send the raw bytes.
    static func preparedForContext(
        _ data: Data,
        maxBytes: Int = contextMaxBytes,
        maxLongEdge: CGFloat = contextMaxLongEdge,
        passthroughFormats: Set<String> = standardPassthroughFormats
    ) -> (data: Data, mimeType: String)? {
        guard !data.isEmpty else { return nil }
        if let sniffed = sniffMimeType(data),
           passthroughFormats.contains(sniffed),
           data.count <= maxBytes,
           let size = pixelSize(data),
           max(size.width, size.height) <= maxLongEdge {
            return (data, sniffed)
        }
        guard let jpeg = reencodedJPEG(data, maxBytes: maxBytes, maxLongEdge: maxLongEdge) else {
            return nil
        }
        return (jpeg, "image/jpeg")
    }

    // MARK: - Per-provider long-edge caps

    /// [IMG-5] Anthropic's long-edge cap depends on the model's vision
    /// tier: standard-tier models are served at ≤1568px (and long
    /// many-image conversations can hard-fail above it), while the
    /// high-resolution tier — Opus / Sonnet 4.5 and later, and the
    /// 5-series — accepts up to 2576px. Model ids arrive in several
    /// shapes ("claude-opus-4-5", "claude-sonnet-4.5-20250929",
    /// dated/suffixed variants), so the tier test scans for the family +
    /// version tokens instead of exact-matching names. Anything
    /// unrecognized gets the STANDARD cap: sending smaller than allowed
    /// costs a little detail, sending larger risks a rejected request.
    static func anthropicLongEdgeCap(forModelId modelId: String) -> CGFloat {
        let id = modelId.lowercased()
        // Family + major version ≥ 5 ("opus-5", "sonnet-5", "opus-6"…).
        for family in ["opus-", "sonnet-"] {
            var searchRange = id.startIndex..<id.endIndex
            while let hit = id.range(of: family, range: searchRange) {
                let rest = id[hit.upperBound...]
                if let first = rest.first, let major = first.wholeNumberValue {
                    if major >= 5 { return 2576 }
                    if major == 4 {
                        // 4.x: high-resolution starts at 4.5 — the minor
                        // version follows a '-' or '.' separator.
                        let afterMajor = rest.dropFirst()
                        if afterMajor.first == "-" || afterMajor.first == "." {
                            let minor = afterMajor.dropFirst()
                            if let m = minor.first?.wholeNumberValue, m >= 5 { return 2576 }
                        }
                    }
                }
                searchRange = hit.upperBound..<id.endIndex
            }
        }
        return 1568
    }

    // MARK: - Tool-result image gate

    /// Why a tool-produced image (read_image file, browser screenshot) was
    /// refused at the shared gate. Each case carries enough detail for the
    /// caller to tell the model — and the user reading the transcript —
    /// exactly what was wrong, instead of a bare "could not read image".
    enum ToolImageRejection: Error, Equatable {
        /// Magic bytes match no known image format, the header is
        /// unreadable, or the payload cannot be decoded at all (truncated
        /// or corrupt file).
        case notAnImage
        /// A real image format that is on neither the whitelist nor the
        /// transcodable list. (Defensive: today's sniffer only returns
        /// formats that are on one of the two lists.)
        case unsupportedFormat(String)
        /// File size over the gate's byte ceiling (`.rejectOversize` only).
        case fileTooLarge(bytes: Int, limit: Int)
        /// Pixel count over the decode-safety ceiling (`.rejectOversize`).
        case tooManyPixels(width: Int, height: Int, limit: Int)

        /// One-line explanation suitable for a tool result.
        var reason: String {
            switch self {
            case .notAnImage:
                return "the file is not a recognizable image, or it is corrupted/truncated"
            case .unsupportedFormat(let format):
                return "image format \(format) is not supported here"
            case .fileTooLarge(let bytes, let limit):
                let mb = Double(bytes) / 1_048_576
                let limitMB = limit / 1_048_576
                return String(format: "the file is %.1f MB, over the %d MB limit", mb, limitMB)
            case .tooManyPixels(let w, let h, let limit):
                let mp = Double(w) * Double(h) / 1_000_000
                return String(format: "the image is %dx%d (%.0f MP), over the %d MP limit", w, h, mp, limit / 1_000_000)
            }
        }
    }

    /// What the gate returns on success: context-ready bytes (always JPEG
    /// today — see `gatedToolImage`), the truthful mime for them, and the
    /// source's pixel size / sniffed format for the caller's metadata.
    struct GatedToolImage {
        let data: Data
        let mimeType: String
        let pixelSize: CGSize
        let sourceFormat: String
    }

    /// How `gatedToolImage` treats byte/pixel ceilings.
    enum OversizePolicy {
        /// Hard gate: over-ceiling payloads are refused (read_image reads
        /// arbitrary files — this is the decode-bomb guard).
        case rejectOversize
        /// Soft gate: over-ceiling payloads are converged by the re-encode
        /// instead of refused (browser screenshots are produced by the app
        /// itself; refusing would lose the model's view of the page).
        case downscaleOversize
    }

    /// Formats accepted at the tool-image gate as-is (subject to the
    /// universal re-encode below).
    static let toolImageWhitelist: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp", "image/bmp",
    ]

    /// Formats not sent to providers directly but decodable by ImageIO, so
    /// the gate transcodes them to JPEG instead of refusing.
    static let toolImageTranscodable: Set<String> = [
        "image/heic", "image/heif", "image/avif", "image/tiff",
    ]

    /// Byte ceiling at the tool-image gate (Kelivo's WorkspaceImage uses
    /// the same 20 MB class of limit).
    static let toolImageMaxBytes = 20 * 1024 * 1024

    /// Pixel-count ceiling at the tool-image gate: decoding a pathological
    /// image (e.g. a 20000×8000 PNG) can exhaust memory before any resize
    /// gets a chance to run, so the count is checked from the header,
    /// before any decode.
    static let toolImageMaxPixels = 40_000_000

    /// The one gate every tool-produced image passes through before it is
    /// attached to a tool result (read_image and browser screenshots share
    /// it). Rules, in order:
    ///
    ///   1. Format is sniffed from magic bytes — never from the filename.
    ///      Unknown bytes are refused as `.notAnImage`.
    ///   2. Under `.rejectOversize`, payloads over `toolImageMaxBytes` or
    ///      `toolImageMaxPixels` (from the header, pre-decode) are refused
    ///      with the specific reason.
    ///   3. Everything that passes is re-encoded through the unified prep
    ///      (JPEG, EXIF orientation baked in by the ImageIO thumbnail
    ///      transform, long edge ≤ `contextMaxLongEdge`, ≤ `contextMaxBytes`).
    ///      Whitelisted formats and transcodable formats alike take this
    ///      path — a pass-through would skip the orientation bake. Animated
    ///      images are flattened to their first frame, same trade as the
    ///      context prep. A payload the re-encode cannot handle is refused
    ///      as `.notAnImage`.
    static func gatedToolImage(
        _ data: Data,
        oversize: OversizePolicy = .rejectOversize
    ) -> Result<GatedToolImage, ToolImageRejection> {
        guard let sniffed = sniffMimeType(data) else {
            return .failure(.notAnImage)
        }
        guard toolImageWhitelist.contains(sniffed) || toolImageTranscodable.contains(sniffed) else {
            return .failure(.unsupportedFormat(sniffed))
        }
        if oversize == .rejectOversize, data.count > toolImageMaxBytes {
            return .failure(.fileTooLarge(bytes: data.count, limit: toolImageMaxBytes))
        }
        guard let size = pixelSize(data) else {
            return .failure(.notAnImage)
        }
        if oversize == .rejectOversize,
           size.width * size.height > CGFloat(toolImageMaxPixels) {
            return .failure(.tooManyPixels(
                width: Int(size.width), height: Int(size.height), limit: toolImageMaxPixels
            ))
        }
        // Empty passthrough set: nothing goes out un-re-encoded, so the
        // EXIF orientation bake and the context caps always apply.
        guard let prepared = preparedForContext(
            data,
            maxBytes: contextMaxBytes,
            maxLongEdge: contextMaxLongEdge,
            passthroughFormats: []
        ) else {
            return .failure(.notAnImage)
        }
        return .success(GatedToolImage(
            data: prepared.data,
            mimeType: prepared.mimeType,
            pixelSize: size,
            sourceFormat: sniffed
        ))
    }

    /// Re-encode to JPEG, walking a (long edge × quality) ladder until the
    /// output fits `maxBytes`. Returns nil when even the smallest useful
    /// rung stays over budget or the source cannot be decoded at all.
    private static func reencodedJPEG(_ data: Data, maxBytes: Int, maxLongEdge: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var edges: [CGFloat] = [maxLongEdge]
        for e: CGFloat in [1536, 1280, 1024, 800, 640, 480] where e < maxLongEdge {
            edges.append(e)
        }
        let qualities: [CGFloat] = [0.82, 0.74, 0.66, 0.58, 0.50]
        for edge in edges {
            guard let image = thumbnailImage(source, maxPixel: edge) else { continue }
            for q in qualities {
                guard let encoded = jpegData(image, quality: q) else { continue }
                if encoded.count <= maxBytes { return encoded }
            }
        }
        return nil
    }

    /// Downscaled image via ImageIO thumbnails (low-memory, EXIF-aware).
    /// Falls back to a manual CGContext scale when thumbnail creation is
    /// unavailable for the source format.
    private static func thumbnailImage(_ source: CGImageSource, maxPixel: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return thumb
        }
        guard let full = CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) else { return nil }
        let w = CGFloat(full.width), h = CGFloat(full.height)
        let longest = max(w, h)
        guard longest > maxPixel else { return full }
        let scale = maxPixel / longest
        let tw = max(1, Int((w * scale).rounded()))
        let th = max(1, Int((h * scale).rounded()))
        guard let ctx = CGContext(
            data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return full }
        // Flatten transparency onto white (JPEG has no alpha channel).
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: tw, height: th))
        ctx.interpolationQuality = .high
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage() ?? full
    }

    private static func jpegData(_ image: CGImage, quality: CGFloat) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            dest, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

// MARK: - Message-level image transforms

extension AgentMessage {

    /// [IMG-3] Vision-capability gate, applied at the top of each
    /// provider's message conversion (the assembly layer): when the model
    /// being addressed cannot accept image input, `.imageData` parts are
    /// replaced with the SAME text placeholder the OpenAI path has always
    /// used (`VisionGroupResolver.attachmentPlaceholder` — it points the
    /// model at `read_image` when a Vision Group is configured), and tool
    /// results keep their text content with the image dropped. Before this
    /// gate, Anthropic/Gemini/Antigravity sent the images raw and let the
    /// provider 400 (or silently mishandle) them.
    static func gatedForVisionCapability(
        _ messages: [AgentMessage],
        supportsImageInput: Bool
    ) -> [AgentMessage] {
        guard !supportsImageInput else { return messages }
        var changed = false
        let mapped = messages.map { msg -> AgentMessage in
            var copy = msg
            copy.parts = msg.parts.map { part in
                switch part {
                case .imageData(_, _, let linuxPath):
                    changed = true
                    return .text(VisionGroupResolver.attachmentPlaceholder(linuxPath: linuxPath))
                case .toolResult(let id, let name, let content, let isError,
                                 let imageData, _, let pageURL, let imageLinuxPath)
                    where imageData != nil:
                    changed = true
                    return .toolResult(
                        id: id, name: name, content: content, isError: isError,
                        imageData: nil, imageMimeType: nil,
                        pageURL: pageURL, imageLinuxPath: imageLinuxPath
                    )
                default:
                    return part
                }
            }
            return copy
        }
        return changed ? mapped : messages
    }

    /// True when any part carries image bytes (user attachment or tool result).
    static func containsImagePayload(_ messages: [AgentMessage]) -> Bool {
        for msg in messages {
            for part in msg.parts {
                switch part {
                case .imageData:
                    return true
                case .toolResult(_, _, _, _, let imageData, _, _, _) where imageData != nil:
                    return true
                default:
                    continue
                }
            }
        }
        return false
    }

    /// [IMG-2b] Strip every image payload, replacing attachments with a
    /// text placeholder that keeps the on-disk path (so the model can
    /// re-fetch via `read_image`) and dropping tool-result images while
    /// keeping their text output. Used by the one-shot self-heal retry:
    /// when a provider rejects a request over an image and the whole group
    /// would otherwise burn through its members re-sending the same bytes.
    static func replacingImagesWithPlaceholders(_ messages: [AgentMessage]) -> [AgentMessage] {
        messages.map { msg in
            var copy = msg
            copy.parts = msg.parts.map { part in
                switch part {
                case .imageData(_, _, let linuxPath):
                    if let path = linuxPath, !path.isEmpty {
                        return .text("[image omitted: the provider rejected the image payload. "
                            + "The original file is at \(path) — use read_image to view it.]")
                    }
                    return .text("[image omitted: the provider rejected the image payload.]")
                case .toolResult(let id, let name, let content, let isError,
                                 let imageData, _, let pageURL, let imageLinuxPath)
                    where imageData != nil:
                    return .toolResult(
                        id: id, name: name, content: content, isError: isError,
                        imageData: nil, imageMimeType: nil,
                        pageURL: pageURL, imageLinuxPath: imageLinuxPath
                    )
                default:
                    return part
                }
            }
            return copy
        }
    }
}
