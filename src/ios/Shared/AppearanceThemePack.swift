import Foundation
import SwiftUI
import UIKit

/// Shape + thinking chrome that a theme pack can swap.
/// Colors stay in AppearanceStudio; this file owns radii, bubble style,
/// thinking card image, pack identity.
struct AppearanceThemePack: Equatable, Codable, Identifiable {
    var id: String
    var name: String
    var userBubbleRadius: Double
    var assistantBubbleRadius: Double
    var thinkingRadius: Double
    var thinkingFillHex: String
    var thinkingStrokeHex: String
    var thinkingAccentHex: String
    var userBubbleStyle: String
    var assistantBubbleStyle: String
    var thinkingCardJPEGBase64: String?
    var thinkingCardImageOpacity: Double
    var listRowFillHex: String?
    var listIconShape: String
    var categoryIcons: [String: String]
    var categoryColors: [String: String]
    var categoryImages: [String: String]
    var inputBarRadius: Double
    var inputBarStyle: String
    var inputBarJPEGBase64: String?
    var inputBarImageOpacity: Double
    var thinkingTitleSize: Double
    var thinkingBodySize: Double
    var fontFamily: String
    var wallpaperShade: Double?
    var surfaceOpacity: Double?
    var colorsLight: [String: String]
    var colorsDark: [String: String]
    var wallpaperJPEGBase64: String?

    static let currentKey = "appearanceStudio.themePack.v1"
    static let schemaVersion = 5
    static let categoryKeys = [
        "code", "writing", "research", "analysis", "creative", "chat", "math",
        "translation", "health", "finance", "travel", "education", "design",
        "productivity", "support", "other",
    ]

    static let `default` = AppearanceThemePack(
        id: "warm-paper",
        name: "暖纸",
        userBubbleRadius: 18,
        assistantBubbleRadius: 16,
        thinkingRadius: 12,
        thinkingFillHex: "D4778B",
        thinkingStrokeHex: "D4778B",
        thinkingAccentHex: "D4778B",
        userBubbleStyle: AppearanceBubbleStyle.rounded.rawValue,
        assistantBubbleStyle: AppearanceBubbleStyle.rounded.rawValue,
        thinkingCardJPEGBase64: nil,
        thinkingCardImageOpacity: 0.28,
        listRowFillHex: nil,
        listIconShape: AppearanceListIconShape.circle.rawValue,
        categoryIcons: [:],
        categoryColors: [:],
        categoryImages: [:],
        inputBarRadius: 20,
        inputBarStyle: AppearanceBubbleStyle.rounded.rawValue,
        inputBarJPEGBase64: nil,
        inputBarImageOpacity: 0.28,
        thinkingTitleSize: 13,
        thinkingBodySize: 13,
        fontFamily: AppearanceFontFamily.system.rawValue,
        wallpaperShade: 0.08,
        surfaceOpacity: 0.88,
        colorsLight: [:],
        colorsDark: [:],
        wallpaperJPEGBase64: nil
    )

    var userStyle: AppearanceBubbleStyle { AppearanceBubbleStyle.parse(userBubbleStyle) }
    var assistantStyle: AppearanceBubbleStyle { AppearanceBubbleStyle.parse(assistantBubbleStyle) }

    func radius(_ kind: AppearanceShapeKind) -> CGFloat {
        switch kind {
        case .userBubble: return CGFloat(clampRadius(userBubbleRadius))
        case .assistantBubble: return CGFloat(clampRadius(assistantBubbleRadius))
        case .thinking: return CGFloat(clampRadius(thinkingRadius))
        }
    }

    func thinkingFill(opacity: Double) -> Color {
        Color(hex: thinkingFillHex).opacity(opacity)
    }

    var thinkingStroke: Color { Color(hex: thinkingStrokeHex).opacity(0.15) }
    var thinkingAccent: Color { Color(hex: thinkingAccentHex) }

    func asJSONObject() -> [String: Any] {
        var obj: [String: Any] = [
            "schema": Self.schemaVersion,
            "id": id,
            "name": name,
            "userBubbleRadius": userBubbleRadius,
            "assistantBubbleRadius": assistantBubbleRadius,
            "thinkingRadius": thinkingRadius,
            "thinkingFillHex": thinkingFillHex,
            "thinkingStrokeHex": thinkingStrokeHex,
            "thinkingAccentHex": thinkingAccentHex,
            "userBubbleStyle": userStyle.rawValue,
            "assistantBubbleStyle": assistantStyle.rawValue,
            "thinkingCardImageOpacity": thinkingCardImageOpacity,
            "listIconShape": AppearanceListIconShape.parse(listIconShape).rawValue,
            "categoryIcons": categoryIcons,
            "categoryColors": categoryColors,
            "categoryImages": categoryImages,
            "inputBarRadius": inputBarRadius,
            "inputBarStyle": AppearanceBubbleStyle.parse(inputBarStyle).rawValue,
            "inputBarImageOpacity": inputBarImageOpacity,
            "thinkingTitleSize": thinkingTitleSize,
            "thinkingBodySize": thinkingBodySize,
            "fontFamily": AppearanceFontFamily.parse(fontFamily).rawValue,
            "colorsLight": colorsLight,
            "colorsDark": colorsDark,
        ]
        if let listRowFillHex { obj["listRowFillHex"] = listRowFillHex }
        if let wallpaperShade { obj["wallpaperShade"] = wallpaperShade }
        if let surfaceOpacity { obj["surfaceOpacity"] = surfaceOpacity }
        if let wallpaperJPEGBase64 { obj["wallpaperJPEGBase64"] = wallpaperJPEGBase64 }
        if let thinkingCardJPEGBase64 { obj["thinkingCardJPEGBase64"] = thinkingCardJPEGBase64 }
        if let inputBarJPEGBase64 { obj["inputBarJPEGBase64"] = inputBarJPEGBase64 }
        return obj
    }

    /// Keys that mark JSON as an Appearance theme pack (partial / legacy OK).
    private static let themePackSignalKeys: Set<String> = [
        "schema",
        "userBubbleRadius", "assistantBubbleRadius", "thinkingRadius",
        "thinkingFillHex", "thinkingStrokeHex", "thinkingAccentHex",
        "userBubbleStyle", "assistantBubbleStyle",
        "thinkingCardJPEGBase64", "thinkingCardImageOpacity",
        "listRowFillHex", "listIconShape",
        "categoryIcons", "categoryColors", "categoryImages",
        "inputBarRadius", "inputBarStyle", "inputBarJPEGBase64", "inputBarImageOpacity",
        "thinkingTitleSize", "thinkingBodySize", "fontFamily",
        "wallpaperShade", "surfaceOpacity",
        "colorsLight", "colorsDark", "wallpaperJPEGBase64",
    ]

    /// True when `raw` carries at least one known theme-pack field.
    /// Missing fields are filled from `.default` during decode (migrate / upgrade path).
    static func looksLikeThemePack(_ raw: [String: Any]) -> Bool {
        raw.keys.contains { themePackSignalKeys.contains($0) }
    }

    static func decode(_ raw: [String: Any]) throws -> AppearanceThemePack {
        // Old / partial packs: fill missing keys from `.default` and treat as schema 5.
        // Reject only JSON that does not look like a theme pack at all.
        guard looksLikeThemePack(raw) else {
            throw AppearanceThemePackError.notAThemePack
        }
        func str(_ k: String, fallback: String) -> String {
            (raw[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? (raw[k] as! String) : fallback
        }
        func num(_ k: String, fallback: Double) -> Double {
            if let d = raw[k] as? Double { return d }
            if let i = raw[k] as? Int { return Double(i) }
            if let s = raw[k] as? String, let d = Double(s) { return d }
            return fallback
        }
        func map(_ k: String) -> [String: String] {
            if let typed = raw[k] as? [String: String] { return typed }
            guard let anyMap = raw[k] as? [String: Any] else { return [:] }
            var out: [String: String] = [:]
            for (key, val) in anyMap {
                if let s = val as? String { out[key] = s }
            }
            return out
        }
        let base = AppearanceThemePack.default
        var pack = AppearanceThemePack(
            id: str("id", fallback: base.id),
            name: str("name", fallback: base.name),
            userBubbleRadius: clampRadius(num("userBubbleRadius", fallback: base.userBubbleRadius)),
            assistantBubbleRadius: clampRadius(num("assistantBubbleRadius", fallback: base.assistantBubbleRadius)),
            thinkingRadius: clampRadius(num("thinkingRadius", fallback: base.thinkingRadius)),
            thinkingFillHex: normalizeHex(str("thinkingFillHex", fallback: base.thinkingFillHex)),
            thinkingStrokeHex: normalizeHex(str("thinkingStrokeHex", fallback: base.thinkingStrokeHex)),
            thinkingAccentHex: normalizeHex(str("thinkingAccentHex", fallback: base.thinkingAccentHex)),
            userBubbleStyle: AppearanceBubbleStyle.parse(str("userBubbleStyle", fallback: base.userBubbleStyle)).rawValue,
            assistantBubbleStyle: AppearanceBubbleStyle.parse(str("assistantBubbleStyle", fallback: base.assistantBubbleStyle)).rawValue,
            thinkingCardJPEGBase64: raw["thinkingCardJPEGBase64"] as? String,
            thinkingCardImageOpacity: min(1, max(0.05, num("thinkingCardImageOpacity", fallback: base.thinkingCardImageOpacity))),
            listRowFillHex: (raw["listRowFillHex"] as? String).map(normalizeHex),
            listIconShape: AppearanceListIconShape.parse(str("listIconShape", fallback: base.listIconShape)).rawValue,
            categoryIcons: filterCategoryMap(map("categoryIcons"), symbols: true),
            categoryColors: filterCategoryMap(map("categoryColors"), symbols: false),
            categoryImages: filterCategoryMap(map("categoryImages"), symbols: true),
            inputBarRadius: clampRadius(num("inputBarRadius", fallback: base.inputBarRadius)),
            inputBarStyle: AppearanceBubbleStyle.parse(str("inputBarStyle", fallback: base.inputBarStyle)).rawValue,
            inputBarJPEGBase64: raw["inputBarJPEGBase64"] as? String,
            inputBarImageOpacity: min(1, max(0.05, num("inputBarImageOpacity", fallback: base.inputBarImageOpacity))),
            thinkingTitleSize: min(22, max(10, num("thinkingTitleSize", fallback: base.thinkingTitleSize))),
            thinkingBodySize: min(22, max(10, num("thinkingBodySize", fallback: base.thinkingBodySize))),
            fontFamily: AppearanceFontFamily.parse(str("fontFamily", fallback: base.fontFamily)).rawValue,
            wallpaperShade: raw["wallpaperShade"] == nil ? nil : min(0.65, max(0, num("wallpaperShade", fallback: 0.08))),
            surfaceOpacity: raw["surfaceOpacity"] == nil ? nil : min(1, max(0.35, num("surfaceOpacity", fallback: 0.88))),
            colorsLight: normalizeHexMap(map("colorsLight")),
            colorsDark: normalizeHexMap(map("colorsDark")),
            wallpaperJPEGBase64: raw["wallpaperJPEGBase64"] as? String
        )
        if pack.id.isEmpty { pack.id = base.id }
        if pack.name.isEmpty { pack.name = pack.id }
        return pack
    }
}

enum AppearanceThemePackError: LocalizedError {
    case notAThemePack

    var errorDescription: String? {
        switch self {
        case .notAThemePack:
            return "Not a theme pack."
        }
    }
}

enum AppearanceShapeKind {
    case userBubble, assistantBubble, thinking
}

enum AppearanceListIconShape: String, CaseIterable, Identifiable {
    case circle, squircle, rounded
    var id: String { rawValue }
    var title: String {
        switch self {
        case .circle: return "圆"
        case .squircle: return "方圆"
        case .rounded: return "圆角方"
        }
    }
    static func parse(_ raw: String) -> AppearanceListIconShape {
        AppearanceListIconShape(rawValue: raw) ?? .circle
    }
}

fileprivate func filterCategoryMap(_ map: [String: String], symbols: Bool) -> [String: String] {
    let allowed = Set(AppearanceThemePack.categoryKeys)
    var out: [String: String] = [:]
    for (k, v) in map {
        guard allowed.contains(k) else { continue }
        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        out[k] = symbols ? trimmed : normalizeHex(trimmed)
    }
    return out
}

enum AppearanceFontFamily: String, CaseIterable, Identifiable {
    case system, rounded, serif, mono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "系统"
        case .rounded: return "圆体"
        case .serif: return "衬线"
        case .mono: return "等宽"
        }
    }
    var design: Font.Design {
        switch self {
        case .system: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
    var uiDesign: UIFontDescriptor.SystemDesign {
        switch self {
        case .system: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
    static func parse(_ raw: String) -> AppearanceFontFamily {
        AppearanceFontFamily(rawValue: raw) ?? .system
    }

    func uiFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(uiDesign) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: design)
    }

    static func resolved() -> AppearanceFontFamily {
        guard let data = UserDefaults.standard.data(forKey: AppearanceThemePack.currentKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["fontFamily"] as? String else {
            return .system
        }
        return parse(raw)
    }
}

enum AppearanceBubbleStyle: String, CaseIterable, Identifiable {
    case rounded, squircle, pill, tail, sharp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rounded: return "圆角"
        case .squircle: return "连续圆角"
        case .pill: return "胶囊"
        case .tail: return "小尾巴"
        case .sharp: return "方一点"
        }
    }
    static func parse(_ raw: String) -> AppearanceBubbleStyle {
        AppearanceBubbleStyle(rawValue: raw) ?? .rounded
    }
}

fileprivate func clampRadius(_ value: Double) -> Double {
    min(32, max(4, value))
}

fileprivate func normalizeHex(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
    if trimmed.count == 6 || trimmed.count == 8 { return trimmed }
    return "808080"
}

fileprivate func normalizeHexMap(_ map: [String: String]) -> [String: String] {
    var out: [String: String] = [:]
    let allowed = Set(AppearanceColorRole.allCases.map(\.rawValue))
    for (k, v) in map {
        guard allowed.contains(k) else { continue }
        out[k] = normalizeHex(v)
    }
    return out
}

/// Chat bubble / thinking card clip. Tail sits on the outer side
/// (user = trailing, assistant = leading).

extension AppearanceStudio {
    private static let packKey = AppearanceThemePack.currentKey

    func loadStoredPack() -> AppearanceThemePack {
        currentThemePack()
    }

    func currentThemePack() -> AppearanceThemePack {
        themePackLock.lock()
        defer { themePackLock.unlock() }
        if !themePackLoaded {
            cachedThemePack = loadStoredPackUnlocked()
            themePackLoaded = true
        }
        return cachedThemePack
    }

    func loadStoredPackUnlocked() -> AppearanceThemePack {
        guard let data = UserDefaults.standard.data(forKey: Self.packKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pack = try? AppearanceThemePack.decode(obj) else {
            return .default
        }
        // Persist upgraded schema 5 when stored JSON had missing/old schema.
        // Direct UserDefaults set — avoid persistPack (would re-enter themePackLock).
        let storedSchema: Int? = {
            guard let raw = obj["schema"] else { return nil }
            if let i = raw as? Int { return i }
            if let d = raw as? Double { return Int(d) }
            if let s = raw as? String {
                return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }()
        if storedSchema != AppearanceThemePack.schemaVersion,
           let upgraded = try? JSONSerialization.data(withJSONObject: pack.asJSONObject()) {
            UserDefaults.standard.set(upgraded, forKey: Self.packKey)
        }
        return pack
    }

    func persistPack(_ pack: AppearanceThemePack) {
        guard let data = try? JSONSerialization.data(withJSONObject: pack.asJSONObject()) else { return }
        UserDefaults.standard.set(data, forKey: Self.packKey)
        themePackLock.lock()
        cachedThemePack = pack
        themePackLoaded = true
        themePackLock.unlock()
        themePackRevision += 1
        objectWillChange.send()
    }

    func applyThemePack(_ pack: AppearanceThemePack, wallpaper: UIImage? = nil) {
        var stored = pack
        stored.wallpaperJPEGBase64 = nil
        stored.thinkingCardJPEGBase64 = nil
        stored.inputBarJPEGBase64 = nil
        stored.categoryImages = [:]
        persistPack(stored)
        if !pack.colorsLight.isEmpty || !pack.colorsDark.isEmpty {
            applyPackColors(light: pack.colorsLight, dark: pack.colorsDark)
        }
        if let opacity = pack.surfaceOpacity { surfaceOpacity = opacity }
        if let shade = pack.wallpaperShade { wallpaperShade = shade }
        if let wallpaper {
            setWallpaper(wallpaper, for: .global)
        } else if let b64 = pack.wallpaperJPEGBase64,
                  let data = Data(base64Encoded: b64),
                  let image = UIImage(data: data) {
            setWallpaper(image, for: .global)
        }
        if let b64 = pack.thinkingCardJPEGBase64,
           let data = Data(base64Encoded: b64),
           let image = UIImage(data: data) {
            setThinkingCardImage(image)
        }
        if let b64 = pack.inputBarJPEGBase64,
           let data = Data(base64Encoded: b64),
           let image = UIImage(data: data) {
            setInputBarImage(image)
        }
        applyCategoryImages(pack.categoryImages)
        configureUIKitSurfaces()
    }

    func exportThemePack(includeWallpaper: Bool) -> AppearanceThemePack {
        var pack = loadStoredPack()
        pack.colorsLight = exportColors(variant: .light)
        pack.colorsDark = exportColors(variant: .dark)
        pack.surfaceOpacity = surfaceOpacity
        pack.wallpaperShade = wallpaperShade
        let accentHex = hex(.accent, scope: .chat, variant: activeVariant)
        pack.thinkingAccentHex = accentHex
        pack.thinkingFillHex = accentHex
        pack.thinkingStrokeHex = accentHex
        if includeWallpaper, let image = wallpaper(for: .global),
           let data = image.jpegData(compressionQuality: 0.82) {
            pack.wallpaperJPEGBase64 = data.base64EncodedString()
        } else {
            pack.wallpaperJPEGBase64 = nil
        }
        if includeWallpaper, let image = thinkingCardImage(),
           let data = image.jpegData(compressionQuality: 0.82) {
            pack.thinkingCardJPEGBase64 = data.base64EncodedString()
        }
        if includeWallpaper, let image = inputBarImage(),
           let data = image.jpegData(compressionQuality: 0.82) {
            pack.inputBarJPEGBase64 = data.base64EncodedString()
        }
        if includeWallpaper {
            var images: [String: String] = [:]
            for key in AppearanceThemePack.categoryKeys {
                if let image = categoryImage(for: key),
                   let data = image.jpegData(compressionQuality: 0.86) {
                    images[key] = data.base64EncodedString()
                }
            }
            pack.categoryImages = images
        }
        return pack
    }

    func resetThemePack() {
        UserDefaults.standard.removeObject(forKey: Self.packKey)
        try? FileManager.default.removeItem(at: thinkingCardURL())
        try? FileManager.default.removeItem(at: inputBarImageURL())
        wipeCategoryImageFiles()
        themePackLock.lock()
        cachedThemePack = .default
        themePackLoaded = true
        themePackLock.unlock()
        themePackRevision += 1
        resetColors()
        objectWillChange.send()
    }

    func setBubbleStyle(_ style: AppearanceBubbleStyle, user: Bool) {
        var pack = currentThemePack()
        if user { pack.userBubbleStyle = style.rawValue }
        else { pack.assistantBubbleStyle = style.rawValue }
        persistPack(pack)
    }

    func setListIconShape(_ shape: AppearanceListIconShape) {
        var pack = currentThemePack()
        pack.listIconShape = shape.rawValue
        persistPack(pack)
    }

    func setInputBarRadius(_ value: Double) {
        var pack = currentThemePack()
        pack.inputBarRadius = min(32, max(4, value))
        persistPack(pack)
    }

    func setInputBarStyle(_ style: AppearanceBubbleStyle) {
        var pack = currentThemePack()
        pack.inputBarStyle = style.rawValue
        persistPack(pack)
    }

    func setFontFamily(_ family: AppearanceFontFamily) {
        var pack = currentThemePack()
        pack.fontFamily = family.rawValue
        persistPack(pack)
    }

    func setThinkingFont(title: Double? = nil, body: Double? = nil) {
        var pack = currentThemePack()
        if let title { pack.thinkingTitleSize = min(22, max(10, title)) }
        if let body { pack.thinkingBodySize = min(22, max(10, body)) }
        persistPack(pack)
    }

    func setCategorySymbol(_ symbol: String, for key: String) {
        guard AppearanceThemePack.categoryKeys.contains(key) else { return }
        var pack = currentThemePack()
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            pack.categoryIcons.removeValue(forKey: key)
        } else {
            pack.categoryIcons[key] = trimmed
        }
        persistPack(pack)
    }

    func setCategoryColor(_ color: Color, for key: String) {
        guard AppearanceThemePack.categoryKeys.contains(key) else { return }
        var pack = currentThemePack()
        pack.categoryColors[key] = UIColor(color).hexRGB
        persistPack(pack)
    }

    func clearCategoryChrome(for key: String) {
        guard AppearanceThemePack.categoryKeys.contains(key) else { return }
        var pack = currentThemePack()
        pack.categoryIcons.removeValue(forKey: key)
        pack.categoryColors.removeValue(forKey: key)
        persistPack(pack)
    }

    private func categoryImageURL(_ key: String) -> URL {
        appearanceDirectory.appendingPathComponent("category-\(key).jpg")
    }

    func categoryImage(for key: String) -> UIImage? {
        // [PIC-1] Memory-cached read; the key already embeds size+mtime,
        // so replacing the file invalidates without an explicit clear —
        // the explicit clear in setCategoryImage covers the same-tick
        // re-read before the filesystem settles.
        let path = categoryImageURL(key).path
        if let hit = ThumbnailCache.shared.cachedThumbnail(for: path) { return hit }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        ThumbnailCache.shared.store(image, for: path)
        return image
    }

    func setCategoryImage(_ image: UIImage, for key: String) {
        guard AppearanceThemePack.categoryKeys.contains(key) else { return }
        let maxEdge: CGFloat = 256
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height, 1))
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        if let data = rendered.jpegData(compressionQuality: 0.86) {
            try? data.write(to: categoryImageURL(key), options: .atomic)
        }
        var pack = currentThemePack()
        pack.categoryImages[key] = "file"
        persistPack(pack)
    }

    func removeCategoryImage(for key: String) {
        try? FileManager.default.removeItem(at: categoryImageURL(key))
        var pack = currentThemePack()
        pack.categoryImages.removeValue(forKey: key)
        persistPack(pack)
    }

    private func wipeCategoryImageFiles() {
        for key in AppearanceThemePack.categoryKeys {
            try? FileManager.default.removeItem(at: categoryImageURL(key))
        }
    }

    private func applyCategoryImages(_ map: [String: String]) {
        var kept: [String: String] = [:]
        for key in AppearanceThemePack.categoryKeys {
            guard let value = map[key], !value.isEmpty else {
                try? FileManager.default.removeItem(at: categoryImageURL(key))
                continue
            }
            if value == "file" {
                if FileManager.default.fileExists(atPath: categoryImageURL(key).path) {
                    kept[key] = "file"
                }
                continue
            }
            guard let data = Data(base64Encoded: value), let image = UIImage(data: data) else {
                continue
            }
            writeCategoryImageFile(image, for: key)
            kept[key] = "file"
        }
        var pack = currentThemePack()
        pack.categoryImages = kept
        persistPack(pack)
    }

    private func writeCategoryImageFile(_ image: UIImage, for key: String) {
        let maxEdge: CGFloat = 256
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height, 1))
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        if let data = rendered.jpegData(compressionQuality: 0.86) {
            try? data.write(to: categoryImageURL(key), options: .atomic)
            ThumbnailCache.shared.removeThumbnail(for: categoryImageURL(key).path)
        }
    }

    private func thinkingCardURL() -> URL {
        appearanceDirectory.appendingPathComponent("thinking-card.jpg")
    }

    func thinkingCardImage() -> UIImage? {
        // [PIC-1] Same cached-read pattern as categoryImage above.
        let path = thinkingCardURL().path
        if let hit = ThumbnailCache.shared.cachedThumbnail(for: path) { return hit }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        ThumbnailCache.shared.store(image, for: path)
        return image
    }

    func hasThinkingCardImage() -> Bool {
        FileManager.default.fileExists(atPath: thinkingCardURL().path)
    }

    func setThinkingCardImage(_ image: UIImage) {
        let maxEdge: CGFloat = 1400
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height, 1))
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        if let data = rendered.jpegData(compressionQuality: 0.82) {
            try? data.write(to: thinkingCardURL(), options: .atomic)
            ThumbnailCache.shared.removeThumbnail(for: thinkingCardURL().path)
        }
        var pack = currentThemePack()
        pack.thinkingCardJPEGBase64 = nil
        persistPack(pack)
    }

    func removeThinkingCardImage() {
        try? FileManager.default.removeItem(at: thinkingCardURL())
        ThumbnailCache.shared.removeThumbnail(for: thinkingCardURL().path)
        var pack = currentThemePack()
        pack.thinkingCardJPEGBase64 = nil
        persistPack(pack)
    }

    func setThinkingCardImageOpacity(_ value: Double) {
        var pack = currentThemePack()
        pack.thinkingCardImageOpacity = min(1, max(0.05, value))
        persistPack(pack)
    }

    private func inputBarImageURL() -> URL {
        appearanceDirectory.appendingPathComponent("input-bar.jpg")
    }

    func inputBarImage() -> UIImage? {
        // [PIC-1] Same cached-read pattern as categoryImage above.
        let path = inputBarImageURL().path
        if let hit = ThumbnailCache.shared.cachedThumbnail(for: path) { return hit }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        ThumbnailCache.shared.store(image, for: path)
        return image
    }

    func hasInputBarImage() -> Bool {
        FileManager.default.fileExists(atPath: inputBarImageURL().path)
    }

    func setInputBarImage(_ image: UIImage) {
        let maxEdge: CGFloat = 1400
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height, 1))
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        if let data = rendered.jpegData(compressionQuality: 0.82) {
            try? data.write(to: inputBarImageURL(), options: .atomic)
            ThumbnailCache.shared.removeThumbnail(for: inputBarImageURL().path)
        }
        var pack = currentThemePack()
        pack.inputBarJPEGBase64 = nil
        persistPack(pack)
    }

    func removeInputBarImage() {
        try? FileManager.default.removeItem(at: inputBarImageURL())
        ThumbnailCache.shared.removeThumbnail(for: inputBarImageURL().path)
        var pack = currentThemePack()
        pack.inputBarJPEGBase64 = nil
        persistPack(pack)
    }

    func setInputBarImageOpacity(_ value: Double) {
        var pack = currentThemePack()
        pack.inputBarImageOpacity = min(1, max(0.05, value))
        persistPack(pack)
    }

    fileprivate func applyPackColors(light: [String: String], dark: [String: String]) {
        func paint(_ map: [String: String], variant: AppearanceVariant) {
            for (raw, hex) in map {
                guard let role = AppearanceColorRole(rawValue: raw) else { continue }
                setColor(Color(hex: hex), role: role, scope: .global, variant: variant)
            }
        }
        paint(light, variant: .light)
        paint(dark, variant: .dark)
    }

    fileprivate func exportColors(variant: AppearanceVariant) -> [String: String] {
        var out: [String: String] = [:]
        for role in AppearanceColorRole.allCases {
            out[role.rawValue] = hex(role, scope: .global, variant: variant)
        }
        return out
    }
}

@MainActor
enum MinisThemeShape {
    static var pack: AppearanceThemePack { AppearanceStudio.shared.loadStoredPack() }
    static var userBubbleRadius: CGFloat { pack.radius(.userBubble) }
    static var assistantBubbleRadius: CGFloat { pack.radius(.assistantBubble) }
    static var thinkingRadius: CGFloat { pack.radius(.thinking) }
    static var thinkingFill: Color { AppearanceStudio.shared.color(.accent, scope: .chat).opacity(0.06) }
    static var thinkingStroke: Color { AppearanceStudio.shared.color(.accent, scope: .chat).opacity(0.15) }
    static var thinkingAccent: Color { AppearanceStudio.shared.color(.accent, scope: .chat) }
    static var userStyle: AppearanceBubbleStyle { pack.userStyle }
    static var assistantStyle: AppearanceBubbleStyle { pack.assistantStyle }
    static var thinkingCardOpacity: Double { pack.thinkingCardImageOpacity }
    static var inputBarStyle: AppearanceBubbleStyle { AppearanceBubbleStyle.parse(pack.inputBarStyle) }
    static var inputBarImageOpacity: Double { pack.inputBarImageOpacity }
    static var fontFamily: AppearanceFontFamily { AppearanceFontFamily.parse(pack.fontFamily) }

    static var thinkingTitleSize: CGFloat {
        CGFloat(min(22, max(10, pack.thinkingTitleSize)))
    }
    static var thinkingBodySize: CGFloat {
        CGFloat(min(22, max(10, pack.thinkingBodySize)))
    }
    static var inputBarRadius: CGFloat {
        CGFloat(min(32, max(4, pack.inputBarRadius)))
    }
}

@MainActor
enum MinisThemeList {
    static var pack: AppearanceThemePack { AppearanceStudio.shared.loadStoredPack() }

    static var title: Color { AppearanceStudio.shared.color(.primaryText, scope: .home) }
    static var subtitle: Color { AppearanceStudio.shared.color(.secondaryText, scope: .home) }
    static var meta: Color { AppearanceStudio.shared.color(.secondaryText, scope: .home).opacity(0.72) }
    static var accent: Color { AppearanceStudio.shared.color(.accent, scope: .home) }
    static var rowFill: Color {
        if let hex = pack.listRowFillHex {
            return Color(hex: hex).opacity(AppearanceStudio.shared.surfaceOpacity)
        }
        return AppearanceStudio.shared.color(.surface, scope: .home)
            .opacity(AppearanceStudio.shared.surfaceOpacity)
    }
    static var iconShape: AppearanceListIconShape {
        AppearanceListIconShape.parse(pack.listIconShape)
    }

    static func categoryIcon(for category: String?) -> (systemName: String, color: Color) {
        let fallback = sessionCategoryIconBuiltin(for: category)
        let key = category ?? "other"
        let name = pack.categoryIcons[key] ?? fallback.systemName
        if let hex = pack.categoryColors[key] {
            return (name, Color(hex: hex))
        }
        return (name, fallback.color)
    }
}
