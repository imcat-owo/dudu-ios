import Foundation

/// Single source of truth for every configurable setting in the app.
///
/// Add a new setting in three steps:
///   1. Pick a dot-path id (`appearance.theme`, `browser.uaProfile`, …).
///   2. Construct a `ConfigField` (or `ConfigCollection` for dynamic
///      children) and register it in `ConfigRegistry+Builtins.swift`.
///   3. Done — the offload bridge, confirmation sheet, audit log,
///      revert flow, and `--help` output all derive from this registry.
///
/// Threading: the registry is `@MainActor` because every reader/writer
/// closure may touch UI-bound state. Registration happens once at app
/// launch; mutation after that is rare (only for collections whose
/// child set changes at runtime — those work via `childIds()` not
/// re-registration).
@MainActor
final class ConfigRegistry {
    static let shared = ConfigRegistry()

    private var fields: [String: ConfigField] = [:]
    private var collections: [String: ConfigCollection] = [:]
    private var didRegisterBuiltins = false

    /// Idempotent. Called from `MinisApp.onAppear`. Splitting initial
    /// load from the singleton init avoids touching managers (whose
    /// own init may have side effects) before the app is ready.
    func registerBuiltinsIfNeeded() {
        guard !didRegisterBuiltins else { return }
        didRegisterBuiltins = true
        Self.registerBuiltins(into: self)
    }

    func register(_ field: ConfigField) {
        fields[field.path] = field
    }

    func register(_ collection: ConfigCollection) {
        collections[collection.basePath] = collection
    }

    /// Look up a field by path. Handles both flat fields and collection
    /// children (`<base>.<id>.<sub>`). Returns nil for unknown paths.
    func resolveField(path: String) -> ConfigField? {
        if let f = fields[path] { return f }
        // Collection child lookup. The child id is matched against the
        // collection's known ids rather than derived by splitting on
        // dots: ids may themselves contain dots (a model entry id is
        // "<instance>/<model id>", and model ids like "gpt-4.1" carry
        // dots), so splitting `models.<uuid>/gpt-4.1.displayName` after
        // the second dot mangles the id and the lookup always missed.
        // The longest matching id wins so an id that is a prefix of
        // another still resolves to the right child.
        guard let dot = path.firstIndex(of: ".") else { return nil }
        let base = String(path[..<dot])
        guard let coll = collections[base] else { return nil }
        let remainder = String(path[path.index(after: dot)...])
        let prefix = "\(base)."
        let childId = coll.childIds()
            .filter { remainder == $0 || remainder.hasPrefix("\($0).") }
            .max(by: { $0.count < $1.count })
        guard let childId else { return nil }
        let childFields = coll.fields(for: childId)
        if remainder == childId {
            // Bare child read (`get models.<id>`): no single field owns
            // this path, so synthesize a read-only aggregate of every
            // child field, mirroring the snapshot the remove path takes.
            // Fields that refuse to read (hidden secrets) are skipped.
            return ReadOnlyField(
                path: path,
                displayName: coll.displayName,
                description: "All fields of \(base) entry \(childId).",
                valueSchema: .json,
                reader: {
                    var obj: [String: ConfigValue] = [:]
                    for f in childFields where f.access != .hidden {
                        guard let v = try? f.read() else { continue }
                        let leaf = f.path.hasPrefix(prefix + childId + ".")
                            ? String(f.path.dropFirst(prefix.count + childId.count + 1))
                            : f.path
                        obj[leaf] = v
                    }
                    return .object(obj)
                }
            )
        }
        return childFields.first { $0.path == path }
    }

    func collection(basePath: String) -> ConfigCollection? {
        collections[basePath]
    }

    /// All registered top-level field paths (excluding hidden), used by
    /// `minis-config list-all` and the `--help` topic enumerator.
    func allVisibleFieldPaths() -> [String] {
        fields.values
            .filter { $0.access != .hidden }
            .map { $0.path }
            .sorted()
    }

    /// Topic names = unique first segments of every visible path /
    /// collection base path. Order: alphabetical.
    func topics() -> [String] {
        var set = Set<String>()
        for f in fields.values where f.access != .hidden {
            if let head = f.path.split(separator: ".").first {
                set.insert(String(head))
            }
        }
        for c in collections.values {
            set.insert(c.basePath)
        }
        return set.sorted()
    }

    /// All visible fields whose path equals `<topic>` (the bare topic
    /// name — e.g. an aggregate `providers` read-only summary) or starts
    /// with `<topic>.`. When `topic` matches a registered collection, a
    /// representative child's fields (using the first child id) are also
    /// included so `topic-help <collection>` surfaces the per-child
    /// schema instead of an empty list. Used by the per-topic `--help`
    /// output.
    func fields(forTopic topic: String) -> [ConfigField] {
        var out: [ConfigField] = fields.values.filter {
            $0.access != .hidden
            && ($0.path == topic || $0.path.hasPrefix("\(topic)."))
        }
        if let coll = collections[topic],
           let firstChildId = coll.childIds().first {
            out.append(contentsOf: coll.fields(for: firstChildId)
                .filter { $0.access != .hidden })
        }
        return out.sorted { $0.path < $1.path }
    }
}
