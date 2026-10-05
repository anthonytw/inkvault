import Foundation

/// One line of a note listing.
public struct NoteSummary: Hashable, Sendable {
    /// The note id (its directory name).
    public var id: UUID
    /// The current title; empty when never set.
    public var title: String
    /// The current tags.
    public var tags: [String]
    /// The notebook, if any.
    public var notebook: String?
    /// True when the note's newest state is deleted.
    public var deleted: Bool
    /// Number of pages.
    public var pages: Int
    /// Number of strokes over all pages.
    public var strokes: Int
    /// Wall time of the newest readable revision.
    public var modified: Date?
    /// Set when some revisions could not be read (the numbers are then a
    /// best effort) or the note could not be reconstructed at all.
    public var problem: String?
    /// Number of pages with recognised handwriting text.
    public var recognizedPages: Int = 0

    public init(id: UUID, title: String, tags: [String], notebook: String?, deleted: Bool, pages: Int,
                strokes: Int, modified: Date?, problem: String?) {
        self.id = id; self.title = title; self.tags = tags; self.notebook = notebook; self.deleted = deleted
        self.pages = pages; self.strokes = strokes; self.modified = modified; self.problem = problem
    }

    /// Why a query matched no single note.
    public enum LookupError: Error, Hashable, Sendable {
        case notFound(String)
        case ambiguous(String, [UUID])
    }

    /// Picks one note by full id, id prefix (4 or more characters) or exact
    /// title (case-insensitive).
    public static func find(_ query: String, in notes: [NoteSummary]) throws -> NoteSummary {
        if let id = try matchID(query, among: notes.map(\.id)),
           let hit = notes.first(where: { $0.id == id }) { return hit }
        let q = query.lowercased()
        let hits = notes.filter { $0.title.lowercased() == q }
        guard let first = hits.first else { throw LookupError.notFound(query) }
        guard hits.count == 1 else { throw LookupError.ambiguous(query, hits.map(\.id)) }
        return first
    }

    /// Matches a full id or an id prefix of 4 or more characters; nil if the
    /// query is not an id of any of `ids`. Does not read any note.
    ///
    /// - Throws: `LookupError.ambiguous` when a prefix matches several.
    public static func matchID(_ query: String, among ids: [UUID]) throws -> UUID? {
        let q = query.lowercased()
        if let exact = ids.first(where: { $0.uuidString.lowercased() == q }) { return exact }
        guard q.count >= 4, q.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        let hits = ids.filter { $0.uuidString.lowercased().hasPrefix(q) }
        if hits.count > 1 { throw LookupError.ambiguous(query, hits) }
        return hits.first
    }
}

extension LoadedNote {
    /// The same rows as `Vault.history(noteId:)`, from what was already
    /// loaded: readable revisions with their wall time and app, unreadable
    /// ones with their error, oldest first.
    public var history: [HistoryEntry] {
        let ok = revisions.map { HistoryEntry(name: $0.name, wall: $0.wall, app: $0.app, error: nil) }
        let bad = failures.map { HistoryEntry(name: $0.key, wall: nil, app: nil, error: $0.value) }
        return (ok + bad).sorted { $0.name < $1.name }
    }

    /// Revisions `compact` would delete from this note.
    ///
    /// - Parameter assumingSnapshot: plan as if a snapshot of everything
    ///   were written now: it covers every revision, so every older snapshot
    ///   is subsumed and every delta past retention is covered.
    public func compactionPlan(retention: TimeInterval = CompactionPlanner.defaultRetention, now: Date = Date(),
                               assumingSnapshot: Bool = false) -> [RevisionName] {
        var wall: [RevisionName: Date] = [:]
        for r in revisions { wall[r.name] = r.wall }
        var snapshots = revisions.compactMap(SnapshotCoverage.init)
        if assumingSnapshot {
            var included = Included()
            for r in revisions {
                switch r.body {
                case .delta: included.insert(device: r.device, seq: r.seq)
                case .snapshot(let inc, _): included = included.union(inc)
                }
            }
            // The greatest possible name, so it wins every tie.
            let name = RevisionName(hlc: HLC(millis: HLC.maxMillis, counter: HLC.maxCounter) ?? .zero,
                                    device: .zero, seq: 1, kind: .snapshot)
            snapshots.append(SnapshotCoverage(name: name, included: included, wall: now))
        }
        let existing = Set(revisions.map(\.name))
        return CompactionPlanner.deletable(names: revisions.map(\.name), wall: wall, snapshots: snapshots,
                                           retention: retention, now: now).filter(existing.contains)
    }

    /// True when `compact` could not make progress without a snapshot: the
    /// note has deltas past retention that no snapshot covers (which includes
    /// a note without any snapshot, once something is old enough).
    public func needsSnapshotBeforeCompaction(retention: TimeInterval = CompactionPlanner.defaultRetention,
                                              now: Date = Date()) -> Bool {
        let snaps = revisions.compactMap(SnapshotCoverage.init)
        return revisions.contains { r in
            r.kind == .delta && now.timeIntervalSince(r.wall) > retention
                && !snaps.contains { $0.included.covers(device: r.device, seq: r.seq) }
        }
    }
}

extension Vault {
    /// Summarises one note from whatever revisions can be read.
    public func summary(of noteId: UUID) throws -> NoteSummary {
        summary(of: noteId, loaded: try loadNote(noteId))
    }

    /// Summarises a note already loaded with `loadNote`.
    public func summary(of noteId: UUID, loaded: LoadedNote) -> NoteSummary {
        var s = NoteSummary(id: noteId, title: "", tags: [], notebook: nil, deleted: false, pages: 0, strokes: 0,
                            modified: loaded.revisions.map(\.wall).max(), problem: nil)
        if !loaded.failures.isEmpty {
            s.problem = "\(loaded.failures.count) unreadable revision(s)"
        }
        do {
            let state = try NoteReducer.reconstruct(loaded.revisions)
            s.title = state.meta.title
            s.tags = state.meta.tags
            s.notebook = state.meta.notebook
            s.deleted = state.deleted
            s.pages = state.pages.count
            s.strokes = state.pages.reduce(0) { $0 + $1.strokes.count }
            s.recognizedPages = state.pages.filter { !($0.recognition?.text.isEmpty ?? true) }.count
        } catch {
            s.problem = "cannot reconstruct: \(error)"
        }
        return s
    }

    /// Summaries of every note, sorted by title then id.
    public func summaries() throws -> [NoteSummary] {
        try noteIDs().map { try summary(of: $0) }
            .sorted { ($0.title.lowercased(), $0.id.uuidString) < ($1.title.lowercased(), $1.id.uuidString) }
    }

    /// Resolves a full id, an id prefix of 4 or more characters, or an exact
    /// title to a note id. Ids are matched against the directory names
    /// without decrypting anything; only a title lookup reads the notes.
    public func resolveNote(_ query: String) throws -> UUID {
        if let id = try NoteSummary.matchID(query, among: try noteIDs()) { return id }
        return try NoteSummary.find(query, in: try summaries()).id
    }

    /// The revisions `compact` would delete, without deleting them.
    public func compactionPlan(noteId: UUID, retention: TimeInterval = CompactionPlanner.defaultRetention,
                               now: Date = Date(), assumingSnapshot: Bool = false) throws -> [RevisionName] {
        try loadNote(noteId).compactionPlan(retention: retention, now: now, assumingSnapshot: assumingSnapshot)
    }

    /// See `LoadedNote.needsSnapshotBeforeCompaction`.
    public func needsSnapshotBeforeCompaction(noteId: UUID, retention: TimeInterval = CompactionPlanner.defaultRetention,
                                              now: Date = Date()) throws -> Bool {
        try loadNote(noteId).needsSnapshotBeforeCompaction(retention: retention, now: now)
    }
}

/// File names for exports.
public enum ExportName {
    /// `<sanitised title>-<first 8 hex of the id>`, safe on every filesystem:
    /// path separators, control and reserved characters become `-`, runs
    /// collapse, length is capped, an empty title becomes `untitled`.
    public static func stem(title: String, noteId: UUID) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var out = ""
        for scalar in title.unicodeScalars {
            if bad.contains(scalar) || scalar == " " { out += "-" } else { out.unicodeScalars.append(scalar) }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if out.count > 60 { out = String(out.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-.")) }
        if out.isEmpty { out = "untitled" }
        let short = noteId.uuidString.lowercased().prefix(8)
        return "\(out)-\(short)"
    }
}
