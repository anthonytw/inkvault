import ArgumentParser
import Foundation
import Sempere

let appName = "sempere-cli/0.4"

struct CompactCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compact",
        abstract: "Delete revisions that a snapshot makes redundant and that are past the retention window.",
        discussion: """
            Only files covered by a snapshot are ever deleted (format.md §5.3). When a note has no
            snapshot, or has deltas past the retention window that no snapshot covers, a snapshot is
            written first (device id and clock as for `sempere snapshot`). With --dry-run nothing
            is written or deleted; the output says what would be.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title (or use --all).", valueName: "id|title"))
    var note: String?

    @Flag(name: .long, help: "Compact every note.")
    var all = false

    @Option(name: .long, help: ArgumentHelp("Keep revisions younger than this many days.", valueName: "days"))
    var retention: Double = CompactionPlanner.defaultRetention / 86400

    @Flag(name: .customLong("dry-run"), help: "Only list what would be deleted.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard all != (note != nil) else { throw ValidationError("give exactly one of a note (id or title) and --all") }
        guard retention >= 0 else { throw ValidationError("--retention must not be negative") }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let ids = try note.map { [try vault.resolveNote($0)] } ?? vault.noteIDs()
        let seconds = retention * 86400
        struct Item: Encodable {
            var note: String
            /// A snapshot is (dry run) or was (real run) needed before compacting.
            var snapshotNeeded: Bool
            /// The snapshot file written; nil on a dry run or when none was needed.
            var snapshot: String?
            var files: [String]
        }
        var items: [Item] = []
        var failures = 0
        for id in ids {
            let name = id.uuidString.lowercased()
            do {
                var loaded = try vault.loadNote(id)
                let needs = loaded.needsSnapshotBeforeCompaction(retention: seconds)
                var snapName: String?
                let names: [RevisionName]
                if dryRun {
                    // A real run would fail on an unreadable revision when it snapshots; so does the dry run.
                    if needs { _ = try vault.reconstruct(loaded) }
                    names = loaded.compactionPlan(retention: seconds, assumingSnapshot: needs)
                } else {
                    if needs {
                        let (snap, _) = try takeSnapshot(vault, loaded: loaded)
                        snapName = snap.name.filename
                        loaded.revisions.append(snap)
                    }
                    names = try vault.compact(noteId: id, loaded: loaded, retention: seconds)
                }
                items.append(Item(note: name, snapshotNeeded: needs, snapshot: snapName, files: names.map(\.filename)))
            } catch {
                failures += 1
                printError("\(name): \(CLIError.from(error).message)")
            }
        }
        if output.json {
            try output.emitJSON(items)
        } else {
            let total = items.reduce(0) { $0 + $1.files.count }
            for i in items {
                if i.snapshotNeeded {
                    print(dryRun ? "would snapshot \(i.note)" : "snapshot \(i.note)/\(i.snapshot ?? "")")
                }
                for f in i.files { print("\(dryRun ? "would delete" : "deleted") \(i.note)/\(f)") }
            }
            output.info("\(dryRun ? "Would delete" : "Deleted") \(total) file(s).")
        }
        if failures > 0 { throw CLIError.failure("\(failures) note(s) could not be compacted") }
    }
}

/// Writes a snapshot of an already-loaded note with this machine's device id
/// and clock, and saves the clock. Returns the snapshot and the device state.
func takeSnapshot(_ vault: Vault, loaded: LoadedNote) throws -> (Revision, DeviceState) {
    let stateURL = DeviceState.defaultURL()
    var state = try DeviceState.loadOrCreate(at: stateURL)
    var clock = state.clock
    let snap = try vault.snapshot(loaded: loaded, device: state.device, clock: &clock, wall: Date(), app: appName)
    state.clock = clock
    try state.save(to: stateURL)
    return (snap, state)
}

struct SnapshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Write a snapshot of a note (so older revisions can be compacted).",
        discussion: "The device id and clock come from $XDG_STATE_HOME/sempere/device.json (default ~/.local/state), created on first use."
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let (snap, state) = try takeSnapshot(vault, loaded: try vault.loadNote(id))
        if output.json {
            struct Out: Encodable { var note: String; var file: String; var device: String }
            try output.emitJSON(Out(note: id.uuidString.lowercased(), file: snap.name.filename,
                                    device: state.device.rawValue))
        } else {
            output.info("Wrote \(id.uuidString.lowercased())/\(snap.name.filename)")
        }
    }
}
