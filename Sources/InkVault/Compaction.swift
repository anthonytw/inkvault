import Foundation

/// Decides which revision files may be deleted (format.md §5.3).
public enum CompactionPlanner {
    /// Default retention window: 30 days by `wall`.
    public static let defaultRetention: TimeInterval = 30 * 24 * 60 * 60

    /// Revisions that may be deleted given the newest snapshot:
    ///
    /// - a delta when `newestSnapshot.included` covers it and its `wall` is
    ///   older than `retention`;
    /// - an older snapshot when it sorts before `newestSnapshot`, the newest
    ///   snapshot's writer saw it (its `(device, seq)` is in `included`), and
    ///   its `wall` is older than `retention`.
    ///
    /// Names without a `wall` entry are kept. The newest snapshot is never
    /// returned. Result is sorted by `(hlc, device, seq)`.
    public static func deletable(names: [RevisionName], wall: [RevisionName: Date], newestSnapshot: Revision,
                                 retention: TimeInterval = defaultRetention, now: Date) -> [RevisionName] {
        guard case .snapshot(let included, _) = newestSnapshot.body else { return [] }
        let newest = newestSnapshot.name
        var out = Set<RevisionName>()
        for name in names where name != newest {
            guard let w = wall[name], now.timeIntervalSince(w) > retention,
                  included.covers(device: name.device, seq: name.seq) else { continue }
            switch name.kind {
            case .delta: out.insert(name)
            case .snapshot: if name < newest { out.insert(name) }
            }
        }
        return out.sorted()
    }
}
