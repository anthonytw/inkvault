import Foundation
import Sempere

/// A note "Recognize All Notes" read, and when.
struct RecognizedEntry: Codable, Hashable, Sendable {
    var id: UUID
    var at: Date
    /// Pages the note had.
    var pages: Int
    /// Pages whose recognition the run wrote.
    var pagesRecognized: Int

    /// The row detail of "Recently Recognized" ("Read 2 of 5 pages").
    var recognizedNote: RecognizedNote {
        RecognizedNote(id: id, title: "", pages: pages, pagesRecognized: pagesRecognized)
    }
}

/// The notes "Recognize All Notes" read in the last seven days, newest first,
/// one entry per note (the sidebar's "Recently Recognized"). Pure, tested.
struct RecognitionHistory: Codable, Equatable, Sendable {
    /// How long a note stays listed.
    static let window: TimeInterval = 7 * 86_400
    /// Most notes remembered (a hostile or damaged file cannot make the list grow without bound).
    static let maxEntries = 10_000

    private(set) var entries: [RecognizedEntry] = []

    /// Adds the notes of a run (read at `date`), replacing older entries of the same notes.
    mutating func record(_ notes: [RecognizedNote], at date: Date) {
        guard !notes.isEmpty else { return }
        let ids = Set(notes.map(\.id))
        let added = notes.reversed().map {
            RecognizedEntry(id: $0.id, at: date, pages: max(0, $0.pages), pagesRecognized: max(0, $0.pagesRecognized))
        }
        var seen: Set<UUID> = []
        entries = (added + entries.filter { !ids.contains($0.id) }).filter { seen.insert($0.id).inserted }
        prune(now: date)
    }

    /// Drops entries older than `window` (or from the future by more than a
    /// day: a clock that was wrong) and beyond `maxEntries`.
    mutating func prune(now: Date) {
        let oldest = now.addingTimeInterval(-Self.window), newest = now.addingTimeInterval(86_400)
        var seen: Set<UUID> = []
        entries = entries.filter { $0.at >= oldest && $0.at <= newest && seen.insert($0.id).inserted }
        entries.sort { $0.at > $1.at }
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
    }

    /// The entries still within the window at `now`.
    func recent(now: Date) -> [RecognizedEntry] {
        var copy = self
        copy.prune(now: now)
        return copy.entries
    }

    /// The entry of note `id`, if it is recent.
    func entry(for id: UUID, now: Date) -> RecognizedEntry? {
        recent(now: now).first { $0.id == id }
    }

    var isEmpty: Bool { entries.isEmpty }
}

/// Queries searched recently, newest first (the search field's suggestions).
/// Pure, tested.
struct RecentSearches: Codable, Equatable, Sendable {
    static let limit = 10
    /// Longest query remembered.
    static let maxLength = 200

    private(set) var queries: [String] = []

    /// Puts `query` (trimmed) first; one copy per query, ignoring case.
    mutating func record(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q.count <= Self.maxLength else { return }
        queries.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        queries.insert(q, at: 0)
        if queries.count > Self.limit { queries.removeLast(queries.count - Self.limit) }
    }

    mutating func remove(_ query: String) { queries.removeAll { $0 == query } }

    mutating func clear() { queries = [] }

    /// The list as read from a file: trimmed, bounded, without duplicates.
    func sanitized() -> RecentSearches {
        var clean = RecentSearches()
        for q in queries.prefix(Self.limit * 4).reversed() { clean.record(q) }
        return clean
    }
}

/// What this device remembers of a vault between launches: the notes
/// recognised recently and the recent searches. Sealed with a key derived
/// from the vault secret (`LocalCacheKey`, purpose `activity`), in the app's
/// Application Support folder, never in the vault: searches can name what
/// notes hold, so they are as private as the notes. A vault whose secret
/// changes starts afresh.
struct RecentActivity: Codable, Equatable, Sendable {
    var recognized = RecognitionHistory()
    var searches = RecentSearches()

    /// `SMPA` then version 1.
    static let magic: [UInt8] = [0x53, 0x4D, 0x50, 0x41, 0x01]
    static let fileName = "activity"
    /// The largest file read.
    static let maxFileBytes = 4 << 20

    /// The file of `vault` under `root` (the folder is named by the key).
    static func location(root: URL, key: LocalCacheKey) -> URL {
        root.appendingPathComponent(key.name, isDirectory: true).appendingPathComponent(fileName)
    }

    /// What `root` holds for `vault`; empty when nothing (or nothing usable) is stored.
    static func load(root: URL, vault: Vault, now: Date = Date()) -> RecentActivity {
        guard let key = try? LocalCacheKey(vault: vault, purpose: "activity", magic: magic) else { return RecentActivity() }
        let url = location(root: root, key: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let sealed = try? BoundedRead.contents(of: url, maxBytes: maxFileBytes),
              let plain = try? key.open(sealed, fileName: fileName),
              var activity = try? JSONDecoder().decode(RecentActivity.self, from: plain) else { return RecentActivity() }
        activity.recognized.prune(now: now)
        activity.searches = activity.searches.sanitized()
        return activity
    }

    /// Stores `self` for `vault` under `root` (errors are ignored: it is a convenience).
    func save(root: URL, vault: Vault) {
        guard let key = try? LocalCacheKey(vault: vault, purpose: "activity", magic: Self.magic),
              let plain = try? JSONEncoder().encode(self),
              let sealed = try? key.seal(plain, fileName: Self.fileName) else { return }
        let url = Self.location(root: root, key: key)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? sealed.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
