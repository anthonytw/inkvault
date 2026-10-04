import Foundation

/// Ops for the edits a note browser makes (everything except ink).
public enum NoteOps {
    /// The ops that create a note: one empty page plus all metadata fields.
    ///
    /// Tags are trimmed and de-duplicated, and an empty notebook is nil.
    public static func newNote(title: String, paper: Paper = .ruled, pageSize: PageSize = .letter,
                               notebook: String? = nil, tags: [String] = [],
                               pageId: UUID = UUID()) -> [Op] {
        [.addPage(Page(id: pageId, order: PageOrder.between(nil, nil))),
         .setMeta(.title(title)),
         .setMeta(.tags(normalizedTags(tags))),
         .setMeta(.notebook(normalizedNotebook(notebook))),
         .setMeta(.paper(paper)),
         .setMeta(.pageSize(pageSize))]
    }

    /// Trims each tag, drops empty ones and exact duplicates, keeps order.
    public static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
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
