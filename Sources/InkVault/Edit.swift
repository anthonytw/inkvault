import Foundation

/// Ops for the edits a note browser makes (everything except ink).
public enum NoteOps {
    /// The ops that create a note: one empty page, all metadata fields, and
    /// one `addTag` per tag (format.md §5.4.1).
    ///
    /// Tags are trimmed and de-duplicated, and an empty notebook is nil.
    public static func newNote(title: String, paper: Paper = .ruled, pageSize: PageSize = .letter,
                               notebook: String? = nil, tags: [String] = [],
                               pageId: UUID = UUID()) -> [Op] {
        [.addPage(Page(id: pageId, order: PageOrder.between(nil, nil))),
         .setMeta(.title(title)),
         .setMeta(.notebook(normalizedNotebook(notebook))),
         .setMeta(.paper(paper)),
         .setMeta(.pageSize(pageSize))]
            + normalizedTags(tags).map(Op.addTag)
    }

    /// The op that adds `tag` to a note in `state`, or nil when the tag is
    /// empty or the note already has it in any spelling (format.md §5.4.1).
    public static func addTag(_ tag: String, to state: NoteState) -> Op? {
        let tag = normalizedTag(tag)
        guard !tag.isEmpty, !state.meta.tags.contains(where: { tagKey($0) == tagKey(tag) }) else { return nil }
        return .addTag(tag)
    }

    /// The op that removes `tag` (any spelling) from a note in `state`: every
    /// live instance of its key is observed. Nil when the note does not have it.
    public static func removeTag(_ tag: String, from state: NoteState) -> Op? {
        let observed = state.tagSet?.instances(of: tag) ?? []
        guard !observed.isEmpty else { return nil }
        return .removeTag(normalizedTag(tag), observed: observed)
    }

    /// The ops that make a note in `state` carry exactly `tags` (normalised,
    /// first spelling per key wins): `removeTag` for keys it should lose or
    /// whose spelling differs, then `addTag` for keys it lacks, in `tags` order.
    public static func setTags(_ tags: [String], on state: NoteState) -> [Op] {
        let want = normalizedTags(tags)
        let have = state.meta.tags
        let wantSpelling = Dictionary(want.map { (tagKey($0), $0) }, uniquingKeysWith: { a, _ in a })
        let haveSpelling = Dictionary(have.map { (tagKey($0), $0) }, uniquingKeysWith: { a, _ in a })
        var ops: [Op] = []
        for tag in have where wantSpelling[tagKey(tag)] != tag {
            if let op = removeTag(tag, from: state) { ops.append(op) }
        }
        for tag in want where haveSpelling[tagKey(tag)] != tag { ops.append(.addTag(tag)) }
        return ops
    }

    /// The tag as stored: trimmed, inner runs of whitespace collapsed to one space.
    public static func normalizedTag(_ tag: String) -> String {
        tag.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The case-insensitive key tags are matched by: "Math" and "math" are one tag.
    public static func tagKey(_ tag: String) -> String {
        normalizedTag(tag).lowercased()
    }

    /// Normalises each tag (`normalizedTag`), drops empty ones and duplicates
    /// that differ only in case (the first spelling wins), keeps order.
    public static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map(normalizedTag).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// The trimmed notebook name, nil when empty.
    public static func normalizedNotebook(_ name: String?) -> String? {
        let t = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }
}

extension Vault {
    /// Writes one delta of `ops` for a note as this device: the device id and
    /// clock come from the state file at `deviceState` (created on first use;
    /// saved before the revision is written, so the clock only ever moves
    /// forward). The clock first observes every readable revision of the
    /// note, so these ops win last-writer-wins races against what is already
    /// there. Creates the note when it has no revisions yet.
    ///
    /// - Throws: `VaultError.locked` / `.noIdentities` when the vault cannot
    ///   read, `.revision` for an unreadable snapshot, `VaultError.io` for the
    ///   state file.
    @discardableResult
    public func apply(_ ops: [Op], to noteId: UUID, deviceState: URL, app: String,
                      wall: Date = Date()) throws -> Revision {
        guard canRead else { throw isLocked ? VaultError.locked : VaultError.noIdentities }
        let loaded = try loadNote(noteId)
        var state = try DeviceState.loadOrCreate(at: deviceState)
        var clock = state.clock
        for r in loaded.revisions { clock.observe(r.hlc, wall: wall) }
        let hlc = clock.tick(wall: wall)
        let seq = loaded.failures.isEmpty
            ? Vault.nextSeq(from: loaded.revisions, device: state.device)
            : try nextSeq(noteId: noteId, device: state.device)
        state.clock = clock
        try state.save(to: deviceState)
        let revision = Revision(noteId: noteId, device: state.device, seq: seq, hlc: hlc, wall: wall, app: app,
                                body: .delta(ops: ops))
        try write(revision)
        return revision
    }
}
