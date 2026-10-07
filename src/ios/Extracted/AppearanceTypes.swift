// Extracted from OpenMinis Shared/AppearanceStudio.swift (GPL-3.0) — engine types only, View structs removed.
import PhotosUI
import SwiftUI
import UIKit
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Semantic appearance system

enum AppearanceScope: String, CaseIterable, Identifiable {
    case global, home, chat, settings, browser, files, terminal, bottomBar

    var id: String { rawValue }
    var title: String {
        switch self {
        case .global: return "全部页面"
        case .home: return "首页"
        case .bottomBar: return "底部栏"
        case .chat: return "聊天"
        case .settings: return "设置"
        case .browser: return "浏览器"
        case .files: return "文件"
        case .terminal: return "终端"
        }
    }
}

enum AppearanceVariant: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
    var title: String { self == .light ? "浅色" : "深色" }
}

enum AppearanceColorRole: String, CaseIterable, Identifiable {
    case canvas, surface, raised, mutedSurface
    case primaryText, secondaryText
    case accent, userBubble, assistantBubble, input, border
    case searchField, toolCard
    case success, warning, destructive

    var id: String { rawValue }
    var title: String {
        switch self {
        case .canvas: return "页面背景"
        case .surface: return "卡片"
        case .raised: return "浮层"
        case .mutedSurface: return "浅底"
        case .primaryText: return "主文字"
        case .secondaryText: return "次文字"
        case .accent: return "强调色"
        case .userBubble: return "我的气泡"
        case .assistantBubble: return "AI 气泡"
        case .input: return "输入框"
        case .border: return "边线"
        case .searchField: return "搜索栏"
        case .toolCard: return "工具卡"
        case .success: return "成功"
        case .warning: return "警告"
        case .destructive: return "危险"
        }
    }

    /// Where this role actually paints — shown under each 色盘 row so the
    /// mapping is unambiguous ("调色的时候对应的地方准确一点").
    var hint: String {
        switch self {
        case .canvas: return "每页底衬，卡片间隙和空区透出"
        case .surface: return "卡片背景：设置卡片、会话列表、浮层卡片"
        case .raised: return "浮层：弹窗、菜单、悬浮面板"
        case .mutedSurface: return "浅底小组件：输入框图标等"
        case .primaryText: return "主文字：标题、正文"
        case .secondaryText: return "次文字：说明、时间戳"
        case .accent: return "强调色：按钮、选中、开关"
        case .userBubble: return "你的聊天气泡"
        case .assistantBubble: return "AI 聊天气泡"
        case .input: return "聊天输入框"
        case .border: return "分隔线、卡片描边"
        case .searchField: return "首页顶部搜索栏"
        case .toolCard: return "聊天工具卡：终端、浏览器、工具调用"
        case .success: return "成功状态（绿）"
        case .warning: return "警告状态（黄）"
        case .destructive: return "危险操作（红）"
        }
    }
}

@MainActor
final class AppearanceStudio: ObservableObject {
    static let shared = AppearanceStudio()

    private enum Keys {
        static let colors = "appearanceStudio.colors.v1"
        static let userAvatar = "appearanceStudio.userAvatar.v1"
        static let surfaceOpacity = "appearanceStudio.surfaceOpacity"
        static let bubbleOpacity = "appearanceStudio.bubbleOpacity"
        static let wallpaperShade = "appearanceStudio.wallpaperShade"
        static let icons = "appearanceStudio.icons.v1"
    }

    /// Custom values only. Missing values inherit from the built-in palette;
    /// page values inherit from global before falling back to built-in.
    @Published private var customColors: [String: String]
    /// Snapshot for UIKit / off-main reads. Written on persist.
    nonisolated(unsafe) static var colorSnapshot: [String: String] = [:]
    @Published private(set) var wallpaperRevision = 0
    @Published private(set) var iconRevision = 0
    @Published private(set) var userAvatar: String
    @Published private var customIcons: [String: String]
    @Published var surfaceOpacity: Double {
        didSet { UserDefaults.standard.set(surfaceOpacity, forKey: Keys.surfaceOpacity) }
    }
    /// [T-bubble-opacity-slider] Bubble-only transparency, separate from the
    /// global surfaceOpacity so dialling bubbles down doesn't wash out cards,
    /// tool capsules and the input bar. User + assistant bubbles both read it.
    @Published var bubbleOpacity: Double {
        didSet { UserDefaults.standard.set(bubbleOpacity, forKey: Keys.bubbleOpacity) }
    }
    @Published var wallpaperShade: Double {
        didSet { UserDefaults.standard.set(wallpaperShade, forKey: Keys.wallpaperShade) }
    }
    @Published var themePackRevision = 0

    private var wallpaperCache: [AppearanceScope: UIImage] = [:]
    /// [T-wallpaper-clear][09-10 醒醒] Scopes whose own wallpaper was CLEARED
    /// with "清除当前背景" — they do NOT fall back to the global image, so the
    /// page returns to its plain initial canvas colour. Removing the global
    /// image clears the block list too (a global clear resets everything).
    private var wallpaperClearedFallback: Set<AppearanceScope> = []
    private static let wallpaperClearedKey = "appearanceStudio.wallpaperClearedFallback"
    var cachedThemePack: AppearanceThemePack = .default
    var themePackLoaded = false
    let themePackLock = NSLock()

    private init() {
        if let data = UserDefaults.standard.data(forKey: Keys.colors),
           let value = try? JSONDecoder().decode([String: String].self, from: data) {
            customColors = value
        } else {
            customColors = [:]
        }
        userAvatar = UserDefaults.standard.string(forKey: Keys.userAvatar) ?? ""
        // [PIC-6] Custom icons used to live in UserDefaults as one JSON blob
        // of base64 data URIs (23 slots × ~1MB of PNG = a multi-MB plist
        // the system rewrites on every sync). They now live as PNG files
        // under the appearance directory; the in-memory dictionary is kept
        // as the read cache and `customIcon(for:)`'s data-URI contract is
        // unchanged.
        Self.migrateCustomIconsFromUserDefaults()
        customIcons = Self.loadCustomIconsFromDisk()
        let storedOpacity = UserDefaults.standard.object(forKey: Keys.surfaceOpacity) as? Double
        let storedShade = UserDefaults.standard.object(forKey: Keys.wallpaperShade) as? Double
        surfaceOpacity = storedOpacity ?? 0.88
        let storedBubbleOpacity = UserDefaults.standard.object(forKey: Keys.bubbleOpacity) as? Double
        bubbleOpacity = storedBubbleOpacity ?? 1.0
        wallpaperShade = storedShade ?? 0.08
        loadWallpaperCleared()
        cachedThemePack = loadStoredPackUnlocked()
        themePackLoaded = true
        Self.colorSnapshot = customColors
        configureUIKitSurfaces()
    }

    fileprivate static let lightDefaults = AppearancePaletteBook.light
    fileprivate static let darkDefaults = AppearancePaletteBook.dark

    private func key(_ role: AppearanceColorRole, scope: AppearanceScope,
                     variant: AppearanceVariant) -> String {
        "\(scope.rawValue).\(variant.rawValue).\(role.rawValue)"
    }

    func hex(_ role: AppearanceColorRole, scope: AppearanceScope = .global,
             variant: AppearanceVariant) -> String {
        if let value = customColors[key(role, scope: scope, variant: variant)] { return value }
        if scope != .global,
           let value = customColors[key(role, scope: .global, variant: variant)] { return value }
        return (variant == .light ? Self.lightDefaults : Self.darkDefaults)[role] ?? "808080"
    }

    func color(_ role: AppearanceColorRole, scope: AppearanceScope = .global,
               variant: AppearanceVariant? = nil) -> Color {
        let resolved = variant ?? activeVariant
        return Color(hex: hex(role, scope: scope, variant: resolved))
    }

    func uiColor(_ role: AppearanceColorRole, scope: AppearanceScope = .global,
                 variant: AppearanceVariant? = nil) -> UIColor {
        UIColor(hex: hex(role, scope: scope, variant: variant ?? activeVariant))
    }

    var activeVariant: AppearanceVariant {
        let mode = UserDefaults.standard.integer(forKey: "appearanceMode")
        if mode == 1 { return .light }
        if mode == 2 { return .dark }
        return UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
    }

    func setColor(_ color: Color, role: AppearanceColorRole,
                  scope: AppearanceScope, variant: AppearanceVariant) {
        customColors[key(role, scope: scope, variant: variant)] = UIColor(color).hexRGB
        persistColors()
        configureUIKitSurfaces()
    }

    func colorBinding(_ role: AppearanceColorRole, scope: AppearanceScope,
                      variant: AppearanceVariant) -> Binding<Color> {
        Binding(
            get: { self.color(role, scope: scope, variant: variant) },
            set: { self.setColor($0, role: role, scope: scope, variant: variant) }
        )
    }

    func hasOverride(_ role: AppearanceColorRole, scope: AppearanceScope,
                     variant: AppearanceVariant) -> Bool {
        customColors[key(role, scope: scope, variant: variant)] != nil
    }

    func clearOverride(_ role: AppearanceColorRole, scope: AppearanceScope,
                       variant: AppearanceVariant) {
        customColors.removeValue(forKey: key(role, scope: scope, variant: variant))
        persistColors()
    }

    func applyPreset(_ preset: AppearancePreset) {
        let palettes = preset.colors
        for variant in AppearanceVariant.allCases {
            let values = variant == .light ? palettes.light : palettes.dark
            for (role, hex) in values {
                customColors[key(role, scope: .global, variant: variant)] = hex
            }
        }
        persistColors()
        configureUIKitSurfaces()
    }

    func resetColors() {
        customColors.removeAll()
        surfaceOpacity = 0.88
        bubbleOpacity = 1.0
        wallpaperShade = 0.08
        persistColors()
        configureUIKitSurfaces()
    }

    private func persistColors() {
        if let data = try? JSONEncoder().encode(customColors) {
            UserDefaults.standard.set(data, forKey: Keys.colors)
        }
        Self.colorSnapshot = customColors
        objectWillChange.send()
    }

    /// Safe for UIKit callbacks. Resolves chat-scoped roles without hopping the actor.
    nonisolated static func uiColorSnapshot(_ role: AppearanceColorRole,
                                            scope: AppearanceScope = .chat) -> UIColor {
        let variant: AppearanceVariant = {
            let mode = UserDefaults.standard.integer(forKey: "appearanceMode")
            if mode == 1 { return .light }
            if mode == 2 { return .dark }
            return UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
        }()
        let snap = colorSnapshot
        let scoped = "\(scope.rawValue).\(variant.rawValue).\(role.rawValue)"
        let global = "\(AppearanceScope.global.rawValue).\(variant.rawValue).\(role.rawValue)"
        let hex = snap[scoped] ?? snap[global]
            ?? (variant == .light ? AppearancePaletteBook.light : AppearancePaletteBook.dark)[role]
            ?? "808080"
        return UIColor(hex: hex)
    }

    // MARK: Wallpaper

    var appearanceDirectory: URL { Self.appearanceDirectoryURL }

    /// Static twin of `appearanceDirectory`: init-time helpers that run
    /// before all stored properties are initialized (the PIC-6 icon
    /// migration/load) resolve the same directory without touching `self`.
    /// `nonisolated`: the body is a pure path computation plus an
    /// idempotent directory creation, and off-main callers (the backup
    /// system) need the path without an actor hop.
    private nonisolated static var appearanceDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appendingPathComponent("AppearanceStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// [PIC-2] The directory the backup system archives wholesale for the
    /// Appearance category: every wallpaper, category / card image,
    /// custom icon and saved-theme pack lives under it.
    nonisolated static var appearanceAssetsDirectory: URL { appearanceDirectoryURL }

    private func wallpaperURL(_ scope: AppearanceScope) -> URL {
        appearanceDirectory.appendingPathComponent("wallpaper-\(scope.rawValue).jpg")
    }

    func hasWallpaper(_ scope: AppearanceScope) -> Bool {
        if FileManager.default.fileExists(atPath: wallpaperURL(scope).path) { return true }
        // [batch7 用户-P2-9] 底部栏永不继承全局图：没专属图就是纯透明，
        // 否则全局图会被压成一条"邮票"小图（见 ContentView.homeBottomBarBackground
        // "默认完全透明，只有放了壁纸才出图"）。
        guard scope != .global, scope != .bottomBar,
              !wallpaperClearedFallback.contains(scope) else { return false }
        return FileManager.default.fileExists(atPath: wallpaperURL(.global).path)
    }

    func hasOwnWallpaper(_ scope: AppearanceScope) -> Bool {
        FileManager.default.fileExists(atPath: wallpaperURL(scope).path)
    }

    func wallpaper(for scope: AppearanceScope) -> UIImage? {
        if let cached = wallpaperCache[scope] { return cached }
        let own = wallpaperURL(scope)
        // [T-wallpaper-clear] A cleared page never inherits the global image.
        // [batch7 用户-P2-9] 底部栏同样永不继承：无专属图时返回 nil（纯透明），
        // 不拿全局图来凑。
        let fallbackURL = (scope == .global || scope == .bottomBar
                           || wallpaperClearedFallback.contains(scope))
            ? nil : wallpaperURL(.global)
        let url = FileManager.default.fileExists(atPath: own.path)
            ? own
            : (fallbackURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
        guard let url, let image = UIImage(contentsOfFile: url.path) else { return nil }
        wallpaperCache[scope] = image
        return image
    }

    func setWallpaper(_ image: UIImage, for scope: AppearanceScope, dark: Bool = false) {
        guard let data = Self.backgroundJPEG(image, dark: dark) else { return }
        try? data.write(to: wallpaperURL(scope), options: .atomic)
        // [T-wallpaper-clear] Choosing a new image re-enables global
        // fallback for this scope (the clear only sticks until overridden).
        wallpaperClearedFallback.remove(scope)
        persistWallpaperCleared()
        wallpaperCache.removeAll()
        wallpaperRevision += 1
    }

    func removeWallpaper(_ scope: AppearanceScope) {
        try? FileManager.default.removeItem(at: wallpaperURL(scope))
        // [T-wallpaper-clear] Removing the GLOBAL image also resets every
        // cleared-fallback flag (nothing left to inherit anyway).
        if scope == .global { wallpaperClearedFallback.removeAll() }
        persistWallpaperCleared()
        wallpaperCache.removeAll()
        wallpaperRevision += 1
    }

    /// [T-wallpaper-clear] "清除当前背景" — drop this page's wallpaper AND
    /// cut the global inheritance so the page returns to its initial plain
    /// canvas. Distinct from `removeWallpaper` ("改用继承的背景"), which only
    /// drops the page's own image and lets the global one take over.
    func clearWallpaper(_ scope: AppearanceScope) {
        try? FileManager.default.removeItem(at: wallpaperURL(scope))
        if scope != .global { wallpaperClearedFallback.insert(scope) }
        persistWallpaperCleared()
        wallpaperCache.removeAll()
        wallpaperRevision += 1
    }

    /// [batch7 用户-P2-11] 恢复对齐：清除标记为准。恢复是 merge 语义（包里
    /// 没提的文件原位保留），但清除标记恢复回来后、标记对应的本机壁纸文件
    /// 若还在，"清除"就被悄悄撤销、标记变死标记。所以：包里没带某 scope
    /// 壁纸文件、清除标记里却有它时，把本机残留的该文件删掉；包里带了的
    /// scope 不动（显式内容优先）。
    func reconcileClearedWallpapersAfterRestore(packagedScopes: Set<AppearanceScope>) {
        var removed = false
        for scope in wallpaperClearedFallback where scope != .global {
            guard !packagedScopes.contains(scope) else { continue }
            let url = wallpaperURL(scope)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                removed = true
            }
        }
        if removed {
            wallpaperCache.removeAll()
            wallpaperRevision += 1
        }
    }

    private func persistWallpaperCleared() {
        let raw = wallpaperClearedFallback.map(\.rawValue)
        UserDefaults.standard.set(raw, forKey: Self.wallpaperClearedKey)
    }

    private func loadWallpaperCleared() {
        let raw = UserDefaults.standard.stringArray(forKey: Self.wallpaperClearedKey) ?? []
        wallpaperClearedFallback = Set(raw.compactMap(AppearanceScope.init(rawValue:)))
    }

    private static func backgroundJPEG(_ image: UIImage, dark: Bool = false) -> Data? {
        guard let cg = image.cgImage else { return nil }
        let maxEdge: CGFloat = 2200
        let source = CGSize(width: cg.width, height: cg.height)
        let scale = min(1, maxEdge / max(source.width, source.height))
        let size = CGSize(width: max(1, source.width * scale),
                          height: max(1, source.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            // [PIC-8] Matte follows the color scheme: a transparent PNG set
            // in dark mode used to be flattened onto the light canvas color,
            // leaving a pale fringe around dark content.
            let book = dark ? darkDefaults : lightDefaults
            UIColor(hex: book[.canvas] ?? (dark ? "141210" : "FFF8F4")).setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.86)
    }

    // MARK: Paired avatars

    func setUserAvatar(_ image: UIImage) {
        if case .success(let value) = SoulIconImage.encode(image) {
            userAvatar = value
            UserDefaults.standard.set(value, forKey: Keys.userAvatar)
        }
    }

    func removeUserAvatar() {
        userAvatar = ""
        UserDefaults.standard.removeObject(forKey: Keys.userAvatar)
    }

    func setAssistantAvatar(_ image: UIImage) throws {
        guard case .success(let value) = SoulIconImage.encode(image) else { return }
        var soul = SoulStore.load() ?? SoulFile(metadata: .default, body: "")
        soul.metadata.icon = value
        try SoulStore.save(soul)
    }

    func removeAssistantAvatar() throws {
        var soul = SoulStore.load() ?? SoulFile(metadata: .default, body: "")
        soul.metadata.icon = ""
        try SoulStore.save(soul)
    }

    // MARK: Replaceable icons

    func customIcon(for id: String) -> String? {
        customIcons[id]
    }

    func setIcon(_ image: UIImage, for id: String) {
        if case .success(let value) = SoulIconImage.encode(image) {
            // [PIC-6] File first, memory second: the PNG file is the source
            // of truth; the dictionary is only the read cache.
            try? FileManager.default.createDirectory(at: customIconsDirectory,
                                                     withIntermediateDirectories: true)
            if let png = SoulIconImage.pngData(from: value) {
                try? png.write(to: customIconURL(for: id), options: .atomic)
            }
            customIcons[id] = value
            persistIcons()
        }
    }

    func removeIcon(for id: String) {
        try? FileManager.default.removeItem(at: customIconURL(for: id))
        customIcons.removeValue(forKey: id)
        persistIcons()
    }

    private func persistIcons() {
        // [PIC-6] The dictionary is now only the in-memory read cache; the
        // files are the source of truth (setIcon/removeIcon write them).
        iconRevision += 1
        objectWillChange.send()
    }

    // MARK: - [PIC-6] Custom icons on disk

    private var customIconsDirectory: URL { Self.customIconsDirectoryURL }

    private static var customIconsDirectoryURL: URL {
        appearanceDirectoryURL.appendingPathComponent("icons", isDirectory: true)
    }

    private func customIconURL(for id: String) -> URL {
        Self.customIconFileURL(for: id)
    }

    private static func customIconFileURL(for id: String) -> URL {
        customIconsDirectoryURL.appendingPathComponent("\(id).png")
    }

    private static let customIconsMigratedKey = "appearanceStudio.customIconsMigrated.v1"

    /// One-time migration: UserDefaults JSON blob → one PNG file per slot.
    /// Runs once; the UserDefaults key is removed afterwards.
    /// Static because init calls it before all stored properties are
    /// initialized; it only touches UserDefaults and the icons directory.
    ///
    /// [batch7 用户-P2-12] 原子化：全部文件写完才删旧键、打已迁移标记。
    /// 中途任何一张写失败（目录建不出来、编码失败、落盘抛错）都不删键、
    /// 不打标记，下次启动重跑——不再是"defer 无条件清掉 + try? 静默吞错"。
    private static func migrateCustomIconsFromUserDefaults() {
        guard !UserDefaults.standard.bool(forKey: Self.customIconsMigratedKey) else { return }
        guard let data = UserDefaults.standard.data(forKey: Keys.icons) else {
            // 从来没有旧 blob：无事可做，直接标记完成。
            UserDefaults.standard.set(true, forKey: Self.customIconsMigratedKey)
            return
        }
        // 旧 blob 存在但解不开：不删、不标记，留着证据等以后处理，
        // 不像以前那样 defer 一把清掉。
        guard let value = try? JSONDecoder().decode([String: String].self, from: data),
              !value.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: customIconsDirectoryURL,
                                                    withIntermediateDirectories: true)
        } catch {
            return // 目录都建不出来：下次启动重试。
        }
        var failed = false
        for (id, uri) in value {
            guard let png = SoulIconImage.pngData(from: uri) else {
                failed = true
                continue
            }
            do {
                try png.write(to: customIconFileURL(for: id), options: .atomic)
            } catch {
                failed = true
            }
        }
        // 有一张没写完就不算完：旧键和标记都留着，下次启动重跑。
        guard !failed else { return }
        UserDefaults.standard.removeObject(forKey: Keys.icons)
        UserDefaults.standard.set(true, forKey: Self.customIconsMigratedKey)
    }

    private static func loadCustomIconsFromDisk() -> [String: String] {
        var loaded: [String: String] = [:]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: customIconsDirectoryURL,
            includingPropertiesForKeys: nil) else { return loaded }
        for url in files where url.pathExtension.lowercased() == "png" {
            let id = url.deletingPathExtension().lastPathComponent
            guard !id.isEmpty, let data = try? Data(contentsOf: url) else { continue }
            loaded[id] = "data:image/png;base64," + data.base64EncodedString()
        }
        return loaded
    }

    // MARK: UIKit-backed surfaces

    func configureUIKitSurfaces() {
        UITableView.appearance().backgroundColor = .clear
        UICollectionView.appearance().backgroundColor = .clear
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.backgroundColor = uiColor(.raised).withAlphaComponent(surfaceOpacity)
        nav.shadowColor = uiColor(.border).withAlphaComponent(0.65)
        nav.titleTextAttributes = [.foregroundColor: uiColor(.primaryText)]
        nav.largeTitleTextAttributes = [.foregroundColor: uiColor(.primaryText)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }
}

struct AppearancePalette {
    let light: [AppearanceColorRole: String]
    let dark: [AppearanceColorRole: String]
}

enum AppearancePaletteBook {
    static let light: [AppearanceColorRole: String] = [
        .canvas: "FFF8F4", .surface: "FFFDFC", .raised: "FFFFFF",
        .mutedSurface: "F8ECE8", .primaryText: "3E312B", .secondaryText: "8D786F",
        .accent: "D4778B", .userBubble: "F6DDE3", .assistantBubble: "FFFDFC",
        .input: "FFFBF8", .border: "EADAD3",
        .searchField: "FFFDFC", .toolCard: "F8ECE8",
        .success: "6E987A",
        .warning: "C9956A", .destructive: "C75D5D"
    ]
    static let dark: [AppearanceColorRole: String] = [
        .canvas: "1B1716", .surface: "25201E", .raised: "302925",
        .mutedSurface: "332824", .primaryText: "F5ECE7", .secondaryText: "BCAAA1",
        .accent: "E09AAA", .userBubble: "573C43", .assistantBubble: "25201E",
        .input: "2B2522", .border: "493C37",
        .searchField: "25201E", .toolCard: "332824",
        .success: "8EB69A",
        .warning: "D4B07A", .destructive: "E18484"
    ]
}

enum AppearancePreset: String, CaseIterable, Identifiable {
    case warmPaper, cleanAir, nightCocoa
    var id: String { rawValue }
    var title: String {
        switch self {
        case .warmPaper: return "暖纸"
        case .cleanAir: return "清气"
        case .nightCocoa: return "夜可可"
        }
    }
    var colors: AppearancePalette {
        switch self {
        case .warmPaper:
            return AppearancePalette(light: AppearancePaletteBook.light, dark: AppearancePaletteBook.dark)
        case .cleanAir:
            return AppearancePalette(
                light: [.canvas:"F6F8FA",.surface:"FFFFFF",.raised:"FFFFFF",.mutedSurface:"EDF2F5",.primaryText:"26323A",.secondaryText:"6F7E87",.accent:"6F93A8",.userBubble:"DDEAF0",.assistantBubble:"FFFFFF",.input:"FFFFFF",.border:"DCE5E9",.searchField:"FFFFFF",.toolCard:"EDF2F5",.success:"638F76",.warning:"C9A36A",.destructive:"BC6262"],
                dark: [.canvas:"151A1D",.surface:"20272B",.raised:"273035",.mutedSurface:"2B353A",.primaryText:"EDF3F5",.secondaryText:"AAB8BE",.accent:"8CB2C5",.userBubble:"334B57",.assistantBubble:"20272B",.input:"252D31",.border:"3B484E",.searchField:"20272B",.toolCard:"2B353A",.success:"82AF91",.warning:"D4B07A",.destructive:"DA8181"])
        case .nightCocoa:
            return AppearancePalette(
                light: [.canvas:"FBF6EF",.surface:"FFFDF8",.raised:"FFFFFF",.mutedSurface:"F2E7DA",.primaryText:"44362E",.secondaryText:"8D7868",.accent:"A77965",.userBubble:"EAD8CE",.assistantBubble:"FFFDF8",.input:"FFFBF5",.border:"E5D7C9",.searchField:"FFFDF8",.toolCard:"F2E7DA",.success:"728E70",.warning:"C9A36A",.destructive:"B86565"],
                dark: [.canvas:"171311",.surface:"241E1A",.raised:"2E2621",.mutedSurface:"362B25",.primaryText:"F2E9E1",.secondaryText:"B9A79B",.accent:"C99B84",.userBubble:"513B31",.assistantBubble:"241E1A",.input:"2A231F",.border:"493B33",.searchField:"241E1A",.toolCard:"362B25",.success:"91AE8B",.warning:"D4B07A",.destructive:"D17A7A"])
        }
    }
}

extension Color {
    init(hex: String) {
        self.init(UIColor(hex: hex))
    }
}

extension UIColor {
    convenience init(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&value)
        let r, g, b, a: CGFloat
        switch raw.count {
        case 8:
            r = CGFloat((value >> 24) & 0xff) / 255
            g = CGFloat((value >> 16) & 0xff) / 255
            b = CGFloat((value >> 8) & 0xff) / 255
            a = CGFloat(value & 0xff) / 255
        default:
            r = CGFloat((value >> 16) & 0xff) / 255
            g = CGFloat((value >> 8) & 0xff) / 255
            b = CGFloat(value & 0xff) / 255
            a = 1
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    var hexRGB: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let resolved = resolvedColor(with: UITraitCollection.current)
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "808080" }
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: - Theme access and backgrounds

@MainActor
enum MinisTheme {
    static func color(_ role: AppearanceColorRole,
                      scope: AppearanceScope = .global) -> Color {
        AppearanceStudio.shared.color(role, scope: scope)
    }
    static var canvas: Color { color(.canvas) }
    static var surface: Color { color(.surface).opacity(AppearanceStudio.shared.surfaceOpacity) }
    static var raised: Color { color(.raised).opacity(AppearanceStudio.shared.surfaceOpacity) }
    static var mutedSurface: Color { color(.mutedSurface).opacity(AppearanceStudio.shared.surfaceOpacity) }
    static var primaryText: Color { color(.primaryText) }
    static var secondaryText: Color { color(.secondaryText) }
    static var accent: Color { color(.accent) }
    static var border: Color { color(.border) }
    // [T-tokenize-all-colors] Semantic trio for settings pages, mirrors
    // ChatColors so the whole app speaks the same token vocabulary.
    static var success: Color { color(.success) }
    static var warning: Color { color(.warning) }
    static var destructive: Color { color(.destructive) }
}

enum QuietIconSlot: String, CaseIterable, Identifiable {
    case decorate, appearance, skills, soul, memory, mcp, env, terminal, rootfs, browser
    case storage, shared, mounts, icloud, backup, permissions, lock
    case logs, about, privacy, feedback
    /// [merge step18a] Settings → Agent Runtime 的「桥·对外连接」行。
    case bridgeRelay
    /// [s2-search] Settings 的「联网搜索」行（第 18 条）。
    case webSearch
    /// [T-user-manual 09-11] Settings → About section's 使用手册 row.
    case manual

    var id: String { rawValue }
    var title: String {
        switch self {
        case .decorate: return "装扮"
        case .appearance: return "外观"
        case .skills: return "技能"
        case .soul: return "Soul"
        case .memory: return "记忆"
        case .mcp: return "MCP"
        case .env: return "环境变量"
        case .storage: return "存储"
        case .shared: return "共享文件夹"
        case .mounts: return "外部文件夹"
        case .icloud: return "iCloud 同步"
        case .backup: return "备份与恢复"
        case .permissions: return "权限"
        case .lock: return "锁定"
        case .logs: return "日志"
        case .about: return "关于"
        case .privacy: return "隐私政策"
        case .feedback: return "反馈"
        case .manual: return "手册"
        case .terminal: return "终端"
        case .rootfs: return "Rootfs 管理"
        case .browser: return "浏览器"
        case .bridgeRelay: return "桥·对外连接"
        case .webSearch: return "联网搜索"
        }
    }
    var systemName: String {
        switch self {
        case .decorate: return "paintpalette"
        case .appearance: return "paintbrush"
        case .skills: return "puzzlepiece.extension"
        case .soul: return "sparkles"
        case .memory: return "brain.head.profile"
        case .mcp: return "square.stack.3d.up"
        case .env: return "terminal"
        case .storage: return "archivebox"
        case .shared: return "folder"
        case .mounts: return "externaldrive"
        case .icloud: return "icloud"
        case .backup: return "arrow.triangle.2.circlepath"
        case .permissions: return "lock.shield"
        case .lock: return "lock"
        case .logs: return "doc.text"
        case .about: return "info"
        case .privacy: return "hand.raised"
        case .feedback: return "bubble.left.and.bubble.right"
        case .manual: return "book.closed"
        case .terminal: return "terminal"
        case .rootfs: return "externaldrive"
        case .browser: return "globe"
        case .bridgeRelay: return "antenna.radiowaves.left.and.right"
        case .webSearch: return "magnifyingglass"
        }
    }
}

// MARK: - Backup ([PIC-2])

extension AppearanceStudio {
    /// Every UserDefaults key holding appearance state. The image FILES
    /// are archived as a tree (see `appearanceAssetsDirectory`); these
    /// keys are the half that lives in defaults — custom colours, the
    /// user avatar, opacities, the wallpaper-cleared list, the
    /// theme-library list and the current theme pack. Single source of
    /// truth for both directions, and the restore side's whitelist: a
    /// package may only ever write THESE keys, never arbitrary defaults.
    static var backupDefaultsKeys: [String] {
        [Keys.colors, Keys.userAvatar, Keys.surfaceOpacity, Keys.bubbleOpacity,
         Keys.wallpaperShade, wallpaperClearedKey,
         AppearanceSavedTheme.libraryKey, AppearanceThemePack.currentKey]
    }

    /// Snapshot the keys above into the package's wire shape. Absent keys
    /// stay absent, so restoring an old or sparse package never invents
    /// values the source device didn't have.
    func collectBackupDefaults() -> [String: BackupDefaultsValue] {
        let defaults = UserDefaults.standard
        var out: [String: BackupDefaultsValue] = [:]
        for key in Self.backupDefaultsKeys {
            guard let raw = defaults.object(forKey: key) else { continue }
            if let data = raw as? Data {
                out[key] = BackupDefaultsValue(kind: "data", data: data.base64EncodedString())
            } else if let string = raw as? String {
                out[key] = BackupDefaultsValue(kind: "string", string: string)
            } else if let strings = raw as? [String] {
                out[key] = BackupDefaultsValue(kind: "strings", strings: strings)
            } else if let number = raw as? NSNumber {
                out[key] = BackupDefaultsValue(kind: "double", double: number.doubleValue)
            }
        }
        return out
    }

    /// Write a restored package's values back into UserDefaults (only the
    /// whitelisted keys; unknown kinds are skipped, not fatal), then
    /// reload the live instance so the restored look takes effect without
    /// a relaunch.
    func applyBackupDefaults(_ values: [String: BackupDefaultsValue]) {
        let defaults = UserDefaults.standard
        for key in Self.backupDefaultsKeys {
            guard let value = values[key] else { continue }
            switch value.kind {
            case "data":
                if let b64 = value.data, let data = Data(base64Encoded: b64) {
                    defaults.set(data, forKey: key)
                }
            case "string":
                if let string = value.string { defaults.set(string, forKey: key) }
            case "strings":
                if let strings = value.strings { defaults.set(strings, forKey: key) }
            case "double":
                if let double = value.double { defaults.set(double, forKey: key) }
            default:
                break
            }
        }
        reloadAfterRestore()
    }

    /// Re-read every piece of appearance state from disk / defaults after
    /// a restore rewrote it underneath the live instance: colours, avatar,
    /// opacities, cleared-wallpaper list, custom icons (files), current
    /// theme pack, and the cached wallpapers.
    func reloadAfterRestore() {
        if let data = UserDefaults.standard.data(forKey: Keys.colors),
           let value = try? JSONDecoder().decode([String: String].self, from: data) {
            customColors = value
        } else {
            customColors = [:]
        }
        Self.colorSnapshot = customColors
        userAvatar = UserDefaults.standard.string(forKey: Keys.userAvatar) ?? ""
        surfaceOpacity = UserDefaults.standard.object(forKey: Keys.surfaceOpacity) as? Double ?? 0.88
        bubbleOpacity = UserDefaults.standard.object(forKey: Keys.bubbleOpacity) as? Double ?? 1.0
        wallpaperShade = UserDefaults.standard.object(forKey: Keys.wallpaperShade) as? Double ?? 0.08
        loadWallpaperCleared()
        customIcons = Self.loadCustomIconsFromDisk()
        themePackLock.lock()
        cachedThemePack = loadStoredPackUnlocked()
        themePackLoaded = true
        themePackLock.unlock()
        themePackRevision += 1
        wallpaperCache.removeAll()
        wallpaperRevision += 1
        iconRevision += 1
        configureUIKitSurfaces()
        objectWillChange.send()
    }
}
