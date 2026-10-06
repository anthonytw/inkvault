import Foundation
import Sempere

/// This installation's device id and hybrid clock (format.md §5), kept in
/// the package's `DeviceState` file inside the app container and saved after
/// every reading, so readings never repeat across launches.
actor DeviceClock {
    /// This installation's device id.
    nonisolated let device: DeviceID
    private var state: DeviceState
    private let url: URL

    /// `Application Support/Sempere/device.json` in the app's container
    /// (on iPad and in the Catalyst sandbox that is per installation).
    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Sempere/device.json")
    }

    /// Loads the state file at `url`, creating it with a fresh device id.
    init(url: URL = DeviceClock.defaultURL) throws {
        let loaded = try DeviceState.loadOrCreate(at: url)
        self.url = url
        self.state = loaded
        self.device = loaded.device
    }

    /// A reading for a revision about to be written; saved before it is returned.
    func tick(wall: Date = Date()) throws -> HLC {
        var clock = state.clock
        let hlc = clock.tick(wall: wall)
        state.clock = clock
        try state.save(to: url)
        return hlc
    }

    /// Merges readings seen in revisions read from the vault, so the next
    /// local reading sorts after them.
    func observe(_ readings: [HLC], wall: Date = Date()) {
        guard !readings.isEmpty else { return }
        var clock = state.clock
        for r in readings { clock.observe(r, wall: wall) }
        guard clock != state.clock else { return }
        state.clock = clock
        try? state.save(to: url)   // a lost observation only weakens ordering, never correctness
    }
}

/// Appends one note's deltas: picks `seq`, stamps the clock, writes the
/// revision (format.md §5). Vault I/O runs on this actor, off the main actor.
/// In iCloud Drive (`coordinated`) each write is a coordinated write on the
/// note's folder, so iCloud uploads it (`CloudVault`).
actor NoteWriter {
    let vault: Vault
    let noteID: UUID
    let clock: DeviceClock
    let app: String
    let coordinated: Bool
    /// The wall-clock time of every revision this writer writes; nil: the time of each write.
    /// Only the demo vault for the App Store screenshots sets it (`DemoVault`).
    let wall: Date?
    private var nextSeq: Int

    init(vault: Vault, noteID: UUID, clock: DeviceClock, nextSeq: Int, app: String = NoteWriter.appName,
         coordinated: Bool = false, wall: Date? = nil) {
        self.vault = vault; self.noteID = noteID; self.clock = clock; self.nextSeq = nextSeq; self.app = app
        self.coordinated = coordinated; self.wall = wall
    }

    /// `sempere-ios/<version>` (format.md §5.1 `app`).
    static var appName: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "sempere-ios/\(v)"
    }

    /// The note's folder, coordinated on for writes; nil outside iCloud Drive.
    private var coordinationURL: URL? {
        guard coordinated else { return nil }
        return vault.url.appendingPathComponent("notes", isDirectory: true)
            .appendingPathComponent(noteID.uuidString.lowercased(), isDirectory: true)
    }

    /// Writes one delta of `ops` to a note that is not loaded (the browser's
    /// edits): the clock first observes every readable revision of the note,
    /// so these ops win last-writer-wins races against what is already there.
    /// Creates the note when it has no revisions yet. `verify` runs inside
    /// that read, before and after the note is loaded, and throws to refuse a
    /// note whose files are not all local (`CloudVault.requireLocal`): `seq`
    /// and the clock must never come from a partial log.
    @discardableResult
    static func append(_ ops: [Op], to noteID: UUID, vault: Vault, clock: DeviceClock, app: String = NoteWriter.appName,
                       coordinated: Bool = false, wall: Date? = nil,
                       verify: (@Sendable () throws -> Void)? = nil) async throws -> RevisionName {
        let (readings, seq, _) = try await read(noteID, vault: vault, device: clock.device, coordinated: coordinated,
                                                verify: verify, build: nil)
        await clock.observe(readings)
        let writer = NoteWriter(vault: vault, noteID: noteID, clock: clock, nextSeq: seq, app: app, coordinated: coordinated,
                                wall: wall)
        return try await writer.write(ops)
    }

    /// Like `append(_:to:...)`, but `build` computes the ops from the note as
    /// it is on disk at write time (nil: no readable revision). Writes nothing
    /// when it returns no ops. Tag edits use this: a `removeTag` observes
    /// every instance on disk, not just those in a possibly stale summary
    /// (format.md §5.4.1). `verify` is as for `append(_:to:...)`.
    @discardableResult
    static func append(to noteID: UUID, vault: Vault, clock: DeviceClock, app: String = NoteWriter.appName,
                       coordinated: Bool = false,
                       verify: (@Sendable () throws -> Void)? = nil,
                       building build: @escaping @Sendable (NoteState?) -> [Op]) async throws -> RevisionName? {
        let (readings, seq, ops) = try await read(noteID, vault: vault, device: clock.device, coordinated: coordinated,
                                                  verify: verify, build: build)
        guard !ops.isEmpty else { return nil }
        await clock.observe(readings)
        let writer = NoteWriter(vault: vault, noteID: noteID, clock: clock, nextSeq: seq, app: app, coordinated: coordinated)
        return try await writer.write(ops)
    }

    /// The note's revision clocks, this device's next `seq`, and the ops
    /// `build` makes from its reconstructed state (empty without `build`).
    /// `verify` runs inside the coordinated read, before and after loading.
    private static func read(_ noteID: UUID, vault: Vault, device: DeviceID, coordinated: Bool,
                             verify: (@Sendable () throws -> Void)?,
                             build: (@Sendable (NoteState?) -> [Op])?) async throws -> ([HLC], Int, [Op]) {
        try await Task.detached(priority: .userInitiated) {
            try CloudVault.coordinatedRead(coordinated ? vault.url : nil) { () throws -> ([HLC], Int, [Op]) in
                try verify?()
                let loaded = try vault.loadNote(noteID)
                try verify?()
                let seq = loaded.failures.isEmpty
                    ? Vault.nextSeq(from: loaded.revisions, device: device)
                    : try vault.nextSeq(noteId: noteID, device: device)
                var ops: [Op] = []
                if let build {
                    ops = build(loaded.revisions.isEmpty ? nil : try NoteReducer.reconstruct(loaded.revisions))
                }
                return (loaded.revisions.map(\.hlc), seq, ops)
            }
        }.value
    }

    /// Writes one delta holding `ops`. A `seq` already taken (another window
    /// of this app, or a browser edit, wrote to the note) is re-read from disk
    /// and the write retried once.
    @discardableResult
    func write(_ ops: [Op]) async throws -> RevisionName {
        do {
            return try await attempt(ops)
        } catch VaultError.seqInUse {
            let vault = self.vault, noteID = self.noteID, device = clock.device
            nextSeq = try CloudVault.coordinatedRead(coordinated ? vault.url : nil) {
                try vault.nextSeq(noteId: noteID, device: device)
            }
            return try await attempt(ops)
        }
    }

    private func attempt(_ ops: [Op]) async throws -> RevisionName {
        let now = wall ?? Date()
        let hlc = try await clock.tick(wall: now)
        let rev = Revision(noteId: noteID, device: clock.device, seq: nextSeq, hlc: hlc, wall: now, app: app,
                           body: .delta(ops: ops))
        try CloudVault.coordinatedWrite(coordinationURL) { try vault.write(rev) }
        nextSeq += 1
        return rev.name
    }
}
