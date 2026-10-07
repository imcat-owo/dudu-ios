// Bundle language override
// Extracted from OpenMinis MinisApp.swift (GPL-3.0).
// Pure Foundation + ObjC runtime: in-app language switch without restart. Non-UI.
import Foundation


/// Overrides `Bundle.main.localizedString(forKey:value:table:)` so that
/// `String(localized:)` and UIKit strings respect the in-app language setting
/// without requiring an app restart.
extension Bundle {
    private static var overrideBundleKey: UInt8 = 0

    /// The language-specific `.lproj` bundle currently in use, or `nil` for system default.
    var languageBundle: Bundle? {
        get { objc_getAssociatedObject(self, &Self.overrideBundleKey) as? Bundle }
        set { objc_setAssociatedObject(self, &Self.overrideBundleKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Call once at launch to swizzle `localizedString(forKey:value:table:)`.
    static func enableLanguageOverride() {
        let original = class_getInstanceMethod(Bundle.self, #selector(localizedString(forKey:value:table:)))!
        let swizzled = class_getInstanceMethod(Bundle.self, #selector(overrideLocalizedString(forKey:value:table:)))!
        method_exchangeImplementations(original, swizzled)
    }

    @objc private func overrideLocalizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if self == Bundle.main, let bundle = languageBundle {
            return bundle.overrideLocalizedString(forKey: key, value: value, table: tableName)
        }
        return overrideLocalizedString(forKey: key, value: value, table: tableName) // calls original (swizzled)
    }

    /// Sets the override language. Pass `nil` or `""` to revert to system language.
    static func setLanguage(_ code: String?) {
        guard let code, !code.isEmpty,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            Bundle.main.languageBundle = nil
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            return
        }
        Bundle.main.languageBundle = bundle
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
    }
}

