import Foundation

/// Notebook names as display paths (`format.md` §5.4): a notebook is a free
/// string, `/` separates levels of a display hierarchy, and leading,
/// trailing and empty segments (after trimming whitespace) are ignored, so
/// `" A//B / "` shows as `A` › `B`.
public enum NotebookPath {
    /// The display segments of a notebook name; empty when it names no
    /// notebook at all (nil, blank, or only separators).
    public static func components(_ name: String?) -> [String] {
        guard let name else { return [] }
        return name.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The canonical form of a notebook name (segments joined by `/`), nil
    /// when it names no notebook. Two names with the same canonical form are
    /// the same notebook for display and filtering.
    public static func canonical(_ name: String?) -> String? {
        let parts = components(name)
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// True when `name` is the notebook `path` or lies anywhere below it.
    /// Compares whole segments: `A/Bc` is not inside `A/B`.
    public static func name(_ name: String?, isWithin path: String) -> Bool {
        let parts = components(name)
        let prefix = components(path)
        return !prefix.isEmpty && parts.count >= prefix.count && Array(parts.prefix(prefix.count)) == prefix
    }

    /// The new name of `name` when the notebook `old` (and everything below
    /// it) is renamed or moved to `new`: the `old` prefix is replaced by
    /// `new`. An empty `new` drops the prefix, so notes directly in `old`
    /// leave every notebook and sub-notebooks move to the top level.
    /// Returns `name` unchanged when it is not within `old`.
    public static func renamed(_ name: String?, from old: String, to new: String?) -> String? {
        guard Self.name(name, isWithin: old) else { return name }
        let rest = components(name).dropFirst(components(old).count)
        return canonical((components(new) + rest).joined(separator: "/"))
    }
}

/// One notebook in the sidebar's hierarchy.
public struct NotebookNode: Hashable, Sendable, Identifiable {
    /// The last segment, for display.
    public var name: String
    /// The canonical path (`NotebookPath.canonical`), which is also the id.
    public var path: String
    /// Sub-notebooks, sorted by name.
    public var children: [NotebookNode]

    public var id: String { path }

    /// `children`, or nil for a leaf (what `OutlineGroup` expects).
    public var childrenOrNil: [NotebookNode]? { children.isEmpty ? nil : children }

    public init(name: String, path: String, children: [NotebookNode] = []) {
        self.name = name; self.path = path; self.children = children
    }

    /// The forest of notebooks named by `names` (nil and blank names are
    /// skipped). Intermediate levels exist even when no note sits directly in
    /// them: `A/B/C` alone yields `A` › `B` › `C`. Siblings sort with
    /// `localizedStandardCompare`.
    public static func tree(_ names: [String?]) -> [NotebookNode] {
        build(Set(names.map(NotebookPath.components).filter { !$0.isEmpty }), depth: 0, prefix: [])
    }

    private static func build(_ paths: Set<[String]>, depth: Int, prefix: [String]) -> [NotebookNode] {
        let below = paths.filter { $0.count > depth && Array($0.prefix(depth)) == prefix }
        let names = Set(below.map { $0[depth] })
        return names.sorted(by: NotebookNode.ascending).map { name in
            let path = prefix + [name]
            return NotebookNode(name: name, path: path.joined(separator: "/"),
                                children: build(below, depth: depth + 1, prefix: path))
        }
    }

    /// Every path in a forest, depth first, parents before children.
    public static func flatten(_ nodes: [NotebookNode]) -> [String] {
        nodes.flatMap { [$0.path] + flatten($0.children) }
    }

    static func ascending(_ a: String, _ b: String) -> Bool {
        let c = a.localizedStandardCompare(b)
        return c == .orderedSame ? a < b : c == .orderedAscending
    }
}
