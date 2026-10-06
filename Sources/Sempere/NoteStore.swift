import Age
import Foundation

/// One row of a note's history, for a UI.
public struct HistoryEntry: Hashable, Sendable {
    /// The revision file name.
    public var name: RevisionName
    /// The revision's `wall` time; nil when the file could not be read.
    public var wall: Date?
    /// The revision's `app` field; nil when the file could not be read.
    public var app: String?
    /// Why the file could not be read, if it could not.
    public var error: RevisionReadError?
}

/// Revisions of one note loaded leniently: what could be read, and why the
/// rest could not.
public struct LoadedNote: Hashable, Sendable {
    /// Readable, verified revisions, sorted by `(hlc, device, seq)`.
    public var revisions: [Revision]
    /// Every listed revision that failed to read.
    public var failures: [RevisionName: RevisionReadError]
}

// MARK: - Note store (format.md §5)

extension Vault {
    /// Note ids: the lowercase-UUID directories under `notes/`, sorted.
    /// Anything else there is ignored.
    ///
    /// - Throws: `VaultError.io` if `notes/` exists but cannot be listed.
    public func noteIDs() throws -> [UUID] {
        try noteDirectoryNames().compactMap(UUID.init(uuidString:))
    }

    /// Revision file names of a note, sorted by `(hlc, device, seq)`.
    /// Unknown files and directories are ignored; a note without a
    /// directory has none.
    ///
    /// - Throws: `VaultError.io` if the note directory cannot be listed.
    public func revisionNames(of noteId: UUID) throws -> [RevisionName] {
        try revisionFileNames(in: noteURL(noteId)).compactMap(RevisionName.init).sorted()
    }

    func noteURL(_ noteId: UUID) -> URL {
        notesURL.appendingPathComponent(noteId.uuidString.lowercased())
    }

    /// Reads one revision: age-decrypts it, checks magic, version and tag,
    /// gunzips and decodes it, and checks that the content names this note
    /// and file.
    ///
    /// - Throws: `VaultError.locked` or `.noIdentities` when the vault cannot
    ///   read at all; otherwise `RevisionReadError`, one case per failing stage.
    public func readRevision(noteId: UUID, name: RevisionName) throws -> Revision {
        try requireMigrated()
        let secret = try requireReadable()
        let note = noteId.uuidString.lowercased()
        let data: Data
        do {
            data = try FileIO.read(noteURL(noteId).appendingPathComponent(name.filename), maxBytes: BoundedRead.maxRevisionBytes)
        } catch {
            throw RevisionReadError.unreadable("\(error)")
        }
        return try decodeRevisionFile(data, note: note, name: name, secret: secret)
    }

    func decodeRevisionFile(_ data: Data, note: String, name: RevisionName, secret: VaultSecret) throws -> Revision {
        let plain: Data
        do { plain = try AgeFile.decrypt(data, with: identities) } catch {
            throw RevisionReadError.undecryptable("\(error)")
        }
        let unframed: BodyFraming.Unframed
        do {
            unframed = try Self.unframe(plain, note: note, filename: name.filename, secret: secret,
                                        previous: previousSecret)
        } catch BodyFramingError.tagMismatch {
            if let journalProblem, pendingRewrap {
                throw RevisionReadError.tagMismatchJournalUnreadable(
                    "a pending rewrap journal could not be read: \(journalProblem)")
            }
            throw RevisionReadError.tagMismatch
        } catch {
            throw RevisionReadError.corruptBody("\(error)")
        }
        let json: Data
        do { json = try Gzip.decompress(unframed.gzip) } catch {
            throw RevisionReadError.corruptBody("\(error)")
        }
        let rev: Revision
        do { rev = try InkJSON.decoder().decode(Revision.self, from: json) } catch {
            throw RevisionReadError.undecodable("\(error)")
        }
        guard rev.noteId.uuidString.lowercased() == note, rev.name == name else {
            throw RevisionReadError.undecodable("content is \(rev.noteId.uuidString.lowercased())/\(rev.name.filename)")
        }
        return rev
    }

    /// Verifies under the current secret, or, while a secret-rotating rewrap
    /// is unfinished, under the previous one.
    static func unframe(_ plain: Data, note: String, filename: String, secret: VaultSecret,
                        previous: VaultSecret?) throws -> BodyFraming.Unframed {
        do {
            return try BodyFraming.unframe(plain, noteId: note, filename: filename, secret: secret)
        } catch BodyFramingError.tagMismatch where previous != nil {
            return try BodyFraming.unframe(plain, noteId: note, filename: filename, secret: previous)
        }
    }

    /// Writes a revision: JSON, gzip, frame and tag, age-encrypt to the
    /// current recipients, then an atomic create of
    /// `notes/<noteId>/<name>`.
    ///
    /// - Throws: `VaultError.locked`, `.alreadyExists` if the file exists
    ///   (files under `notes/` are write-once), `.seqInUse` if another file of
    ///   this note already has the same `(device, seq)`, `.seqOutOfRange` for
    ///   a `seq` readers would reject.
    public func write(_ revision: Revision) throws {
        try requireMigrated()
        let secret = try requireSecret()
        guard (1...RevisionName.maxSeq).contains(revision.seq) else { throw VaultError.seqOutOfRange(revision.seq) }
        let dir = noteURL(revision.noteId)
        let name = revision.name
        let file = dir.appendingPathComponent(name.filename)
        guard !FileIO.exists(file) else { throw VaultError.alreadyExists(file.path) }
        if try revisionNames(of: revision.noteId).contains(where: { $0.device == name.device && $0.seq == name.seq }) {
            throw VaultError.seqInUse(device: name.device.rawValue, seq: name.seq)
        }
        let json = try InkJSON.encoder().encode(revision)
        let body = try BodyFraming.frame(json: json, noteId: revision.noteId.uuidString.lowercased(),
                                         filename: name.filename, secret: secret)
        let encrypted = try Self.encrypt(body, to: ageRecipients())
        try FileIO.createDirectory(dir)
        try FileIO.writeAtomically(encrypted, to: file, replacing: false)
    }

    /// The next `seq` for `device` in this note (format.md §5): one more than
    /// the largest seen in a file name or covered by any snapshot's
    /// `included`, so a device whose old revisions were compacted away never
    /// reuses a covered seq. Decrypts every snapshot of the note; callers that
    /// already hold all revisions should use `nextSeq(from:device:)`.
    ///
    /// - Throws: `VaultError.revision` when a snapshot cannot be read (its
    ///   coverage is unknown, so no safe seq can be chosen), `.locked` /
    ///   `.noIdentities` when snapshots exist but the vault cannot read.
    public func nextSeq(noteId: UUID, device: DeviceID) throws -> Int {
        let names = try revisionNames(of: noteId)
        var top = names.filter { $0.device == device }.map(\.seq).max() ?? 0
        for n in names where n.kind == .snapshot {
            let r: Revision
            do { r = try readRevision(noteId: noteId, name: n) } catch let e as RevisionReadError {
                throw VaultError.revision(name: n.filename, e)
            }
            top = max(top, Self.nextSeq(from: [r], device: device) - 1)
        }
        return top + 1
    }

    /// The next `seq` for `device` given **all** revisions of a note, without
    /// touching disk: one more than the largest `seq` of `device` among them
    /// or covered by any snapshot's `included`.
    public static func nextSeq(from revisions: [Revision], device: DeviceID) -> Int {
        var top = 0
        for r in revisions {
            if r.device == device { top = max(top, r.seq) }
            if case .snapshot(let included, _) = r.body, let e = included.entries[device] {
                top = max(top, e.upTo, e.extra.max() ?? 0)
            }
        }
        return top + 1
    }

    /// Reads every revision of a note, collecting failures instead of
    /// throwing on them.
    public func loadNote(_ noteId: UUID) throws -> LoadedNote {
        try requireMigrated()
        _ = try requireReadable()
        var revs: [Revision] = []
        var failures: [RevisionName: RevisionReadError] = [:]
        for n in try revisionNames(of: noteId) {
            do { revs.append(try readRevision(noteId: noteId, name: n)) } catch let e as RevisionReadError {
                failures[n] = e
            }
        }
        return LoadedNote(revisions: revs, failures: failures)
    }

    /// Reconstructs a note from all its revisions (`NoteReducer`).
    ///
    /// - Throws: `VaultError.revision` for the first unreadable revision
    ///   (failures are reported, never silently dropped; use `loadNote` to
    ///   reconstruct from what is readable), or `NoteLogError`.
    public func reconstruct(noteId: UUID) throws -> NoteState {
        try NoteReducer.reconstruct(strictRevisions(noteId))
    }

    /// `reconstruct(noteId:)` for a note already loaded with `loadNote`, so
    /// it is not decrypted twice. Same strictness: any failure throws.
    public func reconstruct(_ loaded: LoadedNote) throws -> NoteState {
        try NoteReducer.reconstruct(Self.strictRevisions(of: loaded))
    }

    func strictRevisions(_ noteId: UUID) throws -> [Revision] {
        try Self.strictRevisions(of: try loadNote(noteId))
    }

    static func strictRevisions(of loaded: LoadedNote) throws -> [Revision] {
        if let (name, err) = loaded.failures.min(by: { $0.key < $1.key }) {
            throw VaultError.revision(name: name.filename, err)
        }
        return loaded.revisions
    }

    /// Writes a snapshot of every revision of the note (`SnapshotBuilder`),
    /// with the next free `seq` for `device`, and returns it.
    @discardableResult
    public func snapshot(noteId: UUID, device: DeviceID, clock: inout HybridClock, wall: Date,
                         app: String) throws -> Revision {
        try snapshot(loaded: try loadNote(noteId), device: device, clock: &clock, wall: wall, app: app)
    }

    /// `snapshot(noteId:...)` for a note already loaded with `loadNote`.
    @discardableResult
    public func snapshot(loaded: LoadedNote, device: DeviceID, clock: inout HybridClock, wall: Date,
                         app: String) throws -> Revision {
        let revs = try Self.strictRevisions(of: loaded)
        let seq = Self.nextSeq(from: revs, device: device)
        let snap = try SnapshotBuilder.makeSnapshot(from: revs, device: device, seq: seq, clock: &clock,
                                                    wall: wall, app: app)
        try write(snap)
        return snap
    }

    /// Deletes what `CompactionPlanner` allows (format.md §5.3) and nothing
    /// else. Unreadable files are never deleted and never count as coverage.
    ///
    /// - Returns: the deleted names.
    @discardableResult
    public func compact(noteId: UUID, retention: TimeInterval = CompactionPlanner.defaultRetention,
                        now: Date = Date()) throws -> [RevisionName] {
        try compact(noteId: noteId, loaded: try loadNote(noteId), retention: retention, now: now)
    }

    /// `compact(noteId:...)` for a note already loaded with `loadNote`. The
    /// plan is made from `loaded`, so it must reflect what is on disk.
    @discardableResult
    public func compact(noteId: UUID, loaded: LoadedNote, retention: TimeInterval = CompactionPlanner.defaultRetention,
                        now: Date = Date()) throws -> [RevisionName] {
        try requireMigrated()
        let doomed = loaded.compactionPlan(retention: retention, now: now)
        let dir = noteURL(noteId)
        for n in doomed { try FileIO.remove(dir.appendingPathComponent(n.filename)) }
        return doomed
    }

    /// Every revision of a note with its wall time, oldest first by
    /// `(hlc, device, seq)`. Unreadable revisions are listed with their error.
    public func history(noteId: UUID) throws -> [HistoryEntry] {
        try requireMigrated()
        _ = try requireReadable()
        return try revisionNames(of: noteId).map { n in
            do {
                let r = try readRevision(noteId: noteId, name: n)
                return HistoryEntry(name: n, wall: r.wall, app: r.app, error: nil)
            } catch let e as RevisionReadError {
                return HistoryEntry(name: n, wall: nil, app: nil, error: e)
            }
        }
    }
}
