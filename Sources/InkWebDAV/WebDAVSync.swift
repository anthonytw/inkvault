import Foundation
import InkVault

/// Knobs for one sync run.
public struct WebDAVSyncOptions: Sendable {
    /// Plan only: no request that changes the server, no local write.
    public var dryRun = false
    /// Names this device in `vault.conflict-<device>-<time>.json`.
    public var deviceLabel = "device"
    /// The clock for conflict file names and compaction checks.
    public var now = Date()
    /// Remote files larger than this are reported and skipped.
    public var maxFileBytes = 256 << 20

    public init(dryRun: Bool = false, deviceLabel: String = "device", now: Date = Date(), maxFileBytes: Int = 256 << 20) {
        self.dryRun = dryRun; self.deviceLabel = deviceLabel; self.now = now; self.maxFileBytes = maxFileBytes
    }
}

/// Mirrors a vault directory to a WebDAV collection and back; the server
/// only stores files (docs/io.md, "WebDAV sync").
///
/// - Revision files under `notes/` are write-once: a file missing on one side
///   is copied there, an existing one is never overwritten on either side.
/// - `vault.json` and `rewrap-journal.json` are compared against the state of
///   the last sync; when both sides changed, both copies are kept and the
///   conflict is reported.
/// - Deletions only follow compaction: a file that one side removed since the
///   last sync is removed on the other side only if `CompactionPlanner`
///   (over the revisions this side holds) says it is deletable; otherwise it
///   is restored.
///
/// A run keeps going after a per-file failure and lists it in `errors`.
public final class WebDAVSync {
    static let manifestName = "vault.json"
    static let journalName = "rewrap-journal.json"
    static let ageMagic = Data("age-encryption.org/v1\n".utf8)

    private let root: URL
    private let vault: Vault?
    private let client: WebDAVClient
    private let stateURL: URL
    private let options: WebDAVSyncOptions
    private var state = SyncState()
    private var report: SyncReport
    private var madeCollections = Set<[String]>()

    /// - Parameters:
    ///   - directory: the local vault; it may be missing or empty for a first pull.
    ///   - vault: the vault opened with identities, so deletions can be checked
    ///     against the compaction rules; nil or locked means no deletion is propagated.
    ///   - stateURL: the sync-state file (outside `notes/`); see `defaultStateURL`.
    public init(directory: URL, vault: Vault?, client: WebDAVClient, stateURL: URL,
                options: WebDAVSyncOptions = WebDAVSyncOptions()) {
        self.root = directory
        self.vault = (vault?.canRead == true) ? vault : nil
        self.client = client
        self.stateURL = stateURL
        self.options = options
        self.report = SyncReport(dryRun: options.dryRun)
    }

    /// `$XDG_STATE_HOME/inkvault/sync/<id>.json`, one per (remote, vault) pair.
    public static func defaultStateURL(remote: URL, vault: URL,
                                       environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        SyncState.defaultURL(remote: remote, vault: vault, environment: environment)
    }

    /// Runs one sync.
    ///
    /// - Throws: `WebDAVError.vaultMismatch` before touching anything when the
    ///   two sides are different vaults; `.http`/`.transport` when the server's
    ///   root cannot be listed. Anything per file lands in the report.
    public func run() throws -> SyncReport {
        do {
            if let s = try SyncState.load(stateURL) { state = s }
        } catch {
            report.skipped.append(.init(path: stateURL.path, message: "sync state unreadable (\(error.localizedDescription)); treated as a first sync"))
        }
        let rootEntries = try client.list([]) ?? []
        let remoteRoot = Dictionary(rootEntries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        try checkSameVault(remoteRoot)

        for name in [Self.manifestName, Self.journalName] {
            do { try syncMutable(name, remote: remoteRoot[name].flatMap { $0.isCollection ? nil : $0 }) } catch {
                report.errors.append(.init(path: name, message: Self.describe(error)))
            }
        }

        let remoteNotes = try listRemoteNotes(rootEntries)
        let localNotes = try localNoteIDs()
        for id in Set(remoteNotes.keys).union(localNotes).sorted() {
            do { try syncNote(id, remoteEntries: remoteNotes[id]) } catch {
                report.errors.append(.init(path: "notes/\(id)", message: Self.describe(error)))
            }
        }
        if !options.dryRun {
            do { try state.save(stateURL) } catch {
                report.errors.append(.init(path: stateURL.path, message: "cannot save sync state: \(Self.describe(error))"))
            }
        }
        return report
    }

    static func describe(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        return SyncReport.printable(text.split(whereSeparator: \.isNewline).joined(separator: " "))
    }

    // MARK: - Same vault?

    private func checkSameVault(_ remoteRoot: [String: RemoteEntry]) throws {
        guard remoteRoot[Self.manifestName] != nil,
              let local = try? Data(contentsOf: root.appendingPathComponent(Self.manifestName)),
              let localId = Self.vaultId(local) else { return }
        let remote = try client.get([Self.manifestName]).data
        guard let remoteId = Self.vaultId(remote) else {
            throw WebDAVError.malformedResponse("remote vault.json is not a vault manifest")
        }
        if localId != remoteId { throw WebDAVError.vaultMismatch(local: localId, remote: remoteId) }
    }

    private static func vaultId(_ manifest: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any] else { return nil }
        return (obj["vaultId"] as? String)?.lowercased()
    }

    // MARK: - Mutable files

    private func syncMutable(_ name: String, remote: RemoteEntry?) throws {
        let localURL = root.appendingPathComponent(name)
        let local = try? Data(contentsOf: localURL)
        let record = state.mutable[name]

        guard let local else {
            guard let remote else { return }
            // A rewrap journal removed locally is finished business, not a missing file.
            if name == Self.journalName, let record, record.stamp != nil, record.stamp == remote.stamp {
                report.skipped.append(.init(path: name, message: "removed locally; left on the server (sync never deletes it)"))
                return
            }
            try pullMutable(name, remote: remote)
            return
        }
        let localHash = sha256Hex(local)

        guard let remote else {
            // Never on the server, or wiped there: (re)create it, never overwriting.
            if try push(name, local, condition: .create) { try recordMutable(name, hash: localHash) }
            return
        }

        let (remoteData, getETag) = try client.get([name])
        let remoteHash = sha256Hex(remoteData)
        let stamp = remote.etag ?? getETag ?? remote.lastModified
        if remoteHash == localHash {
            state.mutable[name] = .init(hash: localHash, stamp: stamp)
            return
        }
        let localChanged = record.map { $0.hash != localHash } ?? true
        let remoteChanged = record.map { $0.hash != remoteHash } ?? true
        switch (localChanged, remoteChanged) {
        case (false, _):
            // Only the server moved on: take it (an atomic replace, the one in-place write sync makes).
            try accept(name, remoteData, stamp: stamp)
        case (true, false):
            let condition: PutCondition = (remote.etag ?? getETag).map { .replace(etag: $0) } ?? .unconditional
            if try push(name, local, condition: condition) {
                try recordMutable(name, hash: localHash)
            } else {
                try conflict(name, remote: remoteData, detail: "the server copy changed while uploading")
            }
        case (true, true):
            try conflict(name, remote: remoteData,
                         detail: record == nil ? "both sides differ and there is no common ancestor" : "changed on both sides since the last sync")
        }
    }

    private func pullMutable(_ name: String, remote: RemoteEntry) throws {
        let (data, etag) = try client.get([name])
        try accept(name, data, stamp: remote.etag ?? etag ?? remote.lastModified)
    }

    private func accept(_ name: String, _ data: Data, stamp: String?) throws {
        report.downloaded.append(name)
        guard !options.dryRun else { return }
        try LocalFS.write(data, to: root.appendingPathComponent(name), replacing: true)
        state.mutable[name] = .init(hash: sha256Hex(data), stamp: stamp)
    }

    /// Uploads a mutable file; false when the precondition failed.
    private func push(_ name: String, _ data: Data, condition: PutCondition) throws -> Bool {
        if options.dryRun { report.uploaded.append(name); return true }
        try ensureCollection([])
        guard try client.put([name], data, condition: condition) else { return false }
        report.uploaded.append(name)
        return true
    }

    private func recordMutable(_ name: String, hash: String) throws {
        guard !options.dryRun else { return }
        let entry = try client.stat([name])
        state.mutable[name] = .init(hash: hash, stamp: entry?.stamp)
    }

    private func conflict(_ name: String, remote: Data, detail: String) throws {
        let base = (name as NSString).deletingPathExtension
        var copy: String?
        if !options.dryRun {
            let existing = try LocalFS.entries(root).filter { $0.hasPrefix(base + ".conflict-") }
            let identical = existing.first { (try? Data(contentsOf: root.appendingPathComponent($0))) == remote }
            if let identical {
                copy = identical
            } else {
                let fname = "\(base).conflict-\(Self.sanitize(options.deviceLabel))-\(Self.compactUTC(options.now)).json"
                try LocalFS.write(remote, to: root.appendingPathComponent(fname), replacing: false)
                copy = fname
            }
        }
        report.conflicts.append(.init(path: name, remoteCopy: copy, detail: detail))
    }

    static func sanitize(_ label: String) -> String {
        let s = label.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? String($0) : "-" }.joined()
        return String(s.prefix(32)).isEmpty ? "device" : String(s.prefix(32))
    }

    static func compactUTC(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    // MARK: - Notes

    private func localNoteIDs() throws -> [String] {
        try LocalFS.entries(root.appendingPathComponent("notes")).filter(Self.isNoteID)
    }

    static func isNoteID(_ name: String) -> Bool {
        UUID(uuidString: name).map { $0.uuidString.lowercased() == name } ?? false
    }

    private func listRemoteNotes(_ rootEntries: [RemoteEntry]) throws -> [String: [RemoteEntry]] {
        guard rootEntries.contains(where: { $0.name == "notes" && $0.isCollection }),
              let dirs = try client.list(["notes"]) else { return [:] }
        var out: [String: [RemoteEntry]] = [:]
        for d in dirs {
            guard d.isCollection, Self.isNoteID(d.name) else {
                report.ignored.append(SyncReport.printable("notes/\(d.name)"))
                continue
            }
            out[d.name] = try client.list(["notes", d.name]) ?? []
        }
        return out
    }

    private func key(_ id: String, _ n: RevisionName) -> String { "\(id)/\(n.filename)" }

    private func syncNote(_ id: String, remoteEntries: [RemoteEntry]?) throws {
        let dir = root.appendingPathComponent("notes").appendingPathComponent(id)
        var size: [RevisionName: Int] = [:]
        var R = Set<RevisionName>()
        for e in remoteEntries ?? [] {
            guard !e.isCollection, let n = RevisionName(e.name), n.filename == e.name else {
                report.ignored.append(SyncReport.printable("notes/\(id)/\(e.name)"))
                continue
            }
            R.insert(n)
            if let s = e.size { size[n] = s }
        }
        let remoteListed = R
        var L = Set<RevisionName>()
        for f in try LocalFS.entries(dir) {
            if let n = RevisionName(f), n.filename == f { L.insert(n) }
        }
        let prefix = "\(id)/"
        let S = Set(state.files.keys.filter { $0.hasPrefix(prefix) }.compactMap { RevisionName(String($0.dropFirst(prefix.count))) })

        let newLocal = L.subtracting(R).subtracting(S)
        let newRemote = R.subtracting(L).subtracting(S)
        let remoteDeleted = L.subtracting(R).intersection(S)
        let localDeleted = R.subtracting(L).intersection(S)

        func attempt(_ n: RevisionName, _ body: () throws -> Void) {
            do { try body() } catch {
                report.errors.append(.init(path: "notes/\(key(id, n))", message: Self.describe(error)))
            }
        }

        for n in newRemote.sorted() { attempt(n) { if try download(id, n, size: size[n]) { L.insert(n) } } }
        for n in newLocal.sorted() { attempt(n) { try upload(id, n); R.insert(n) } }

        var loaded: LoadedNote?
        if let vault, let uuid = UUID(uuidString: id) {
            loaded = try? vault.loadNote(uuid)
        }
        let epoch = Date(timeIntervalSince1970: 0)

        // The other side deleted these: delete here only if compaction allows it, else put them back.
        // A compaction there kept its covering snapshot there, so only snapshots the server
        // listed count as cover; an emptied or recreated remote folder deletes nothing here.
        if !remoteDeleted.isEmpty {
            let onServer = (loaded?.revisions ?? []).filter { remoteListed.contains($0.name) }
                .compactMap(SnapshotCoverage.init)
            var coverage: [RevisionName: SnapshotCoverage] = [:]
            for r in loaded?.revisions ?? [] { if let c = SnapshotCoverage(r) { coverage[c.name] = c } }
            let readable = Set(loaded?.revisions.map(\.name) ?? [])
            for n in remoteDeleted.sorted() {
                attempt(n) {
                    var allowed = false
                    if loaded != nil, readable.contains(n) {
                        var snaps = onServer
                        if var own = coverage[n] { own.wall = epoch; snaps.append(own) }
                        allowed = CompactionPlanner.deletable(names: [n], wall: [n: epoch], snapshots: snaps,
                                                              retention: 0, now: options.now).contains(n)
                    }
                    if allowed {
                        report.deleted.append(.init(side: "local", path: "notes/\(key(id, n))"))
                        if !options.dryRun { try LocalFS.remove(dir.appendingPathComponent(n.filename)) }
                        L.remove(n)
                    } else if loaded != nil && readable.contains(n) {
                        // Not a compaction: the server lost it. Restore it.
                        try upload(id, n); R.insert(n)
                    } else {
                        report.skipped.append(.init(path: "notes/\(key(id, n))", message: loaded == nil
                            ? "deleted on the server; cannot check it against compaction (vault not unlocked)"
                            : "deleted on the server; unreadable here, kept"))
                    }
                }
            }
        }

        // We deleted these: delete remotely only if a snapshot we hold (and the server has) covers them.
        if !localDeleted.isEmpty {
            let cover = (loaded?.revisions ?? []).filter { R.contains($0.name) }.compactMap(SnapshotCoverage.init)
            for n in localDeleted.sorted() {
                attempt(n) {
                    guard loaded != nil else {
                        report.skipped.append(.init(path: "notes/\(key(id, n))",
                                                    message: "deleted locally; cannot check it against compaction (vault not unlocked)"))
                        return
                    }
                    var snaps = cover
                    if n.kind == .snapshot {
                        guard let included = state.files[key(id, n)]?.included else {
                            report.skipped.append(.init(path: "notes/\(key(id, n))",
                                                        message: "deleted locally; its coverage was never recorded, kept on the server"))
                            return
                        }
                        snaps.append(SnapshotCoverage(name: n, included: included, wall: epoch))
                    }
                    let ok = CompactionPlanner.deletable(names: [n], wall: [n: epoch], snapshots: snaps, retention: 0,
                                                         now: options.now).contains(n)
                    if ok {
                        report.deleted.append(.init(side: "remote", path: "notes/\(key(id, n))"))
                        if !options.dryRun { try client.delete(["notes", id, n.filename]) }
                        R.remove(n)
                    } else if try download(id, n, size: size[n]) {
                        L.insert(n)
                    }
                }
            }
        }

        guard !options.dryRun else { return }
        // Remember what both sides now share; drop what neither has.
        var coverage: [RevisionName: Included] = [:]
        for r in loaded?.revisions ?? [] {
            if case .snapshot(let inc, _) = r.body { coverage[r.name] = inc }
        }
        for n in L.intersection(R) {
            let k = key(id, n)
            state.files[k] = SyncState.FileRecord(included: coverage[n] ?? state.files[k]?.included)
        }
        for n in S where !L.contains(n) && !R.contains(n) { state.files[key(id, n)] = nil }
    }

    private func upload(_ id: String, _ n: RevisionName) throws {
        let path = "notes/\(key(id, n))"
        report.uploaded.append(path)
        guard !options.dryRun else { return }
        let data = try Data(contentsOf: root.appendingPathComponent("notes/\(id)/\(n.filename)"))
        try ensureCollection(["notes", id])
        // A 412 means the server already has it: write-once, so it is the same file.
        try client.put(["notes", id, n.filename], data, condition: .create)
    }

    /// Returns false when the file appeared locally in the meantime.
    private func download(_ id: String, _ n: RevisionName, size: Int?) throws -> Bool {
        let path = "notes/\(key(id, n))"
        if let size, size > options.maxFileBytes { throw WebDAVError.io("\(path) is \(size) bytes, over the limit; skipped") }
        report.downloaded.append(path)
        guard !options.dryRun else { return true }
        let (data, _) = try client.get(["notes", id, n.filename], maxBytes: options.maxFileBytes)
        guard data.count <= options.maxFileBytes else { throw WebDAVError.io("\(path) is over the size limit; skipped") }
        guard data.starts(with: Self.ageMagic) else {
            throw WebDAVError.malformedResponse("\(path) is not an age file; not written")
        }
        let url = root.appendingPathComponent("notes/\(id)/\(n.filename)")
        if try !LocalFS.write(data, to: url, replacing: false) { report.downloaded.removeLast(); return false }
        return true
    }

    private func ensureCollection(_ path: [String]) throws {
        guard !madeCollections.contains(path) else { return }
        switch try client.mkcol(path) {
        case .created, .exists: break
        case .missingParent:
            guard !path.isEmpty else {
                try client.createBase()
                break
            }
            try ensureCollection(Array(path.dropLast()))
            _ = try client.mkcol(path)
        }
        madeCollections.insert(path)
    }
}
