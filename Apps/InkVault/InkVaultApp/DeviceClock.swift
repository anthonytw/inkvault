import Foundation
import InkVault

/// This installation's device id and hybrid clock (format.md §5), kept in
/// the package's `DeviceState` file inside the app container and saved after
/// every reading, so readings never repeat across launches.
actor DeviceClock {
    /// This installation's device id.
    nonisolated let device: DeviceID
    private var state: DeviceState
    private let url: URL

    /// `Application Support/InkVault/device.json` in the app's container
    /// (on iPad and in the Catalyst sandbox that is per installation).
    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("InkVault/device.json")
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
actor NoteWriter {
    let vault: Vault
    let noteID: UUID
    let clock: DeviceClock
    let app: String
    private var nextSeq: Int

    init(vault: Vault, noteID: UUID, clock: DeviceClock, nextSeq: Int, app: String = NoteWriter.appName) {
        self.vault = vault; self.noteID = noteID; self.clock = clock; self.nextSeq = nextSeq; self.app = app
    }

    /// `inkvault-ios/<version>` (format.md §5.1 `app`).
    static var appName: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "inkvault-ios/\(v)"
    }

    /// Writes one delta holding `ops`. A `seq` already taken (another window
    /// of this app wrote to the note) is re-read from disk and the write retried once.
    @discardableResult
    func write(_ ops: [Op]) async throws -> RevisionName {
        do {
            return try await attempt(ops)
        } catch VaultError.seqInUse {
            nextSeq = try vault.nextSeq(noteId: noteID, device: clock.device)
            return try await attempt(ops)
        }
    }

    private func attempt(_ ops: [Op]) async throws -> RevisionName {
        let hlc = try await clock.tick()
        let rev = Revision(noteId: noteID, device: clock.device, seq: nextSeq, hlc: hlc, wall: Date(), app: app,
                           body: .delta(ops: ops))
        try vault.write(rev)
        nextSeq += 1
        return rev.name
    }
}
