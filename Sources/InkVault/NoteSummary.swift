import Foundation

/// One line of a note listing.
public struct NoteSummary: Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var tags: [String]
    public var notebook: String?
    public var deleted: Bool
    public var pages: Int
    public var strokes: Int
    /// Wall time of the newest readable revision.
    public var modified: Date?
    /// Set when some revisions could not be read (the numbers are then a
    /// best effort) or the note could not be reconstructed at all.
    public var problem: String?

    /// Why a query matched no single note.
    public enum LookupError: Error, Hashable, Sendable {
        case notFound(String)
        case ambiguous(String, [UUID])
    }

    /// Picks one note by full id, id prefix (4 or more characters) or exact
    /// title (case-insensitive).
    public static func find(_ query: String, in notes: [NoteSummary]) throws -> NoteSummary {
        let q = query.lowercased()
        var hits = notes.filter { $0.id.uuidString.lowercased() == q }
        if hits.isEmpty, q.count >= 4 {
            hits = notes.filter { $0.id.uuidString.lowercased().hasPrefix(q) }
        }
        if hits.isEmpty { hits = notes.filter { $0.title.lowercased() == q } }
        guard let first = hits.first else { throw LookupError.notFound(query) }
        guard hits.count == 1 else { throw LookupError.ambiguous(query, hits.map(\.id)) }
        return first
    }
}

extension Vault {
    /// Summarises one note from whatever revisions can be read.
    public func summary(of noteId: UUID) throws -> NoteSummary {
        let loaded = try loadNote(noteId)
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

    /// The revisions `compact` would delete, without deleting them.
    public func compactionPlan(noteId: UUID, retention: TimeInterval = CompactionPlanner.defaultRetention,
                               now: Date = Date()) throws -> [RevisionName] {
        let loaded = try loadNote(noteId)
        var wall: [RevisionName: Date] = [:]
        for r in loaded.revisions { wall[r.name] = r.wall }
        return CompactionPlanner.deletable(names: loaded.revisions.map(\.name), wall: wall,
                                           snapshots: loaded.revisions.compactMap(SnapshotCoverage.init),
                                           retention: retention, now: now)
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
