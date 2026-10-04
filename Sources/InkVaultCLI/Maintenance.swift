import ArgumentParser
import Foundation
import InkVault

private let appName = "inkvault-cli/0.4"

struct CompactCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compact",
        abstract: "Delete revisions that a snapshot makes redundant and that are past the retention window.",
        discussion: """
            Only files covered by a snapshot are ever deleted (format.md §5.3). If a note has no
            snapshot nothing is deleted: take one first with `inkvault snapshot`.
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
        let chosen = note != nil
            ? [try NoteSummary.find(note ?? "", in: try vault.summaries())]
            : try vault.summaries()
        let seconds = retention * 86400
        struct Item: Encodable { var note: String; var files: [String] }
        var items: [Item] = []
        for s in chosen {
            let names = dryRun
                ? try vault.compactionPlan(noteId: s.id, retention: seconds)
                : try vault.compact(noteId: s.id, retention: seconds)
            items.append(Item(note: s.id.uuidString.lowercased(), files: names.map(\.filename)))
        }
        if output.json { try output.emitJSON(items); return }
        let total = items.reduce(0) { $0 + $1.files.count }
        for i in items { for f in i.files { print("\(dryRun ? "would delete" : "deleted") \(i.note)/\(f)") } }
        output.info("\(dryRun ? "Would delete" : "Deleted") \(total) file(s).")
        if total == 0 { output.info("Nothing is covered by a snapshot and past retention; see `inkvault snapshot`.") }
    }
}

struct SnapshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Write a snapshot of a note (so older revisions can be compacted).",
        discussion: "The device id and clock come from $XDG_STATE_HOME/inkvault/device.json (default ~/.local/state), created on first use."
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let summary = try NoteSummary.find(note, in: try vault.summaries())
        let stateURL = DeviceState.defaultURL()
        var state = try DeviceState.loadOrCreate(at: stateURL)
        var clock = state.clock
        let snap = try vault.snapshot(noteId: summary.id, device: state.device, clock: &clock, wall: Date(), app: appName)
        state.clock = clock
        try state.save(to: stateURL)
        if output.json {
            struct Out: Encodable { var note: String; var file: String; var device: String }
            try output.emitJSON(Out(note: summary.id.uuidString.lowercased(), file: snap.name.filename,
                                    device: state.device.rawValue))
        } else {
            output.info("Wrote \(summary.id.uuidString.lowercased())/\(snap.name.filename)")
        }
    }
}
