import Foundation

/// Up-conversion of `settings.age` between `$schemaVersion`s (format.md §13.4,
/// docs/settings-sync.md §6): an ordered list of migrations `vN → vN+1`, run on
/// read, on the in-memory copy. Each moves a slot's `$meta` with it unchanged,
/// so every device that migrates the same file gets the same result. A file of
/// a later version than this one is left as it is.
public enum SharedSettingsMigrations {
    /// The `$schemaVersion` this version writes.
    public static let current = 1

    /// One step of a migration.
    public enum Step: Sendable {
        /// The key `from` becomes `to`, at the top level and in every block.
        case rename(from: String, to: String)
        /// The value of `key` is replaced by `map(value)` (nil: left as it is).
        case remap(key: String, map: @Sendable (JSONValue) -> JSONValue?)
        /// The key `key` becomes several keys, each value derived from the old
        /// one (nil: that key is not written); `key` itself goes.
        case split(key: String, into: [(key: String, map: @Sendable (JSONValue) -> JSONValue?)])
    }

    /// The migration from `version` to `version + 1`.
    public struct Migration: Sendable {
        public var version: Int
        public var steps: [Step]

        public init(from version: Int, _ steps: [Step]) { self.version = version; self.steps = steps }
    }

    /// Every migration, in order. Version 1 has none yet: the first change of a
    /// key's name or meaning adds `Migration(from: 1, …)`, bumps `current`, and
    /// commits a fixture `Tests/SempereTests/Fixtures/settings/v1.json` test of it.
    public static let all: [Migration] = []

    /// `settings` migrated to `current` with `all` (or `migrations`, tests).
    /// A file at or beyond the target version is returned unchanged.
    public static func migrated(_ settings: SharedSettings, using migrations: [Migration] = all,
                                to target: Int = current) -> SharedSettings {
        guard settings.schemaVersion < target else { return settings }
        var s = settings
        for m in migrations.sorted(by: { $0.version < $1.version })
        where m.version >= s.schemaVersion && m.version < target {
            for step in m.steps { apply(step, to: &s) }
            s.schemaVersion = m.version + 1
        }
        s.schemaVersion = target
        return s
    }

    static func apply(_ step: Step, to s: inout SharedSettings) {
        switch step {
        case .rename(let from, let to):
            for key in s.slots.keys where key.key == from {
                guard let slot = s.slots.removeValue(forKey: key) else { continue }
                let dest = SettingSlotKey(to, block: key.block)
                if let there = s.slots[dest], !SettingSlot.precedes(there, slot) { continue }
                s.slots[dest] = slot
            }
        case .remap(let key, let map):
            for k in s.slots.keys where k.key == key {
                guard let v = s.slots[k]?.value, let new = map(v) else { continue }
                s.slots[k]?.value = new
            }
        case .split(let key, let into):
            for k in s.slots.keys where k.key == key {
                guard let slot = s.slots.removeValue(forKey: k) else { continue }
                for target in into {
                    let dest = SettingSlotKey(target.key, block: k.block)
                    let value: JSONValue?
                    if let v = slot.value {
                        guard let mapped = target.map(v) else { continue }
                        value = mapped
                    } else {
                        value = nil   // a reset stays a reset
                    }
                    let moved = SettingSlot(value: value, meta: slot.meta)
                    if let there = s.slots[dest], !SettingSlot.precedes(there, moved) { continue }
                    s.slots[dest] = moved
                }
            }
        }
    }
}
