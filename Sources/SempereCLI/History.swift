import ArgumentParser
import Foundation
import Sempere

struct NotesHistory: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "List a note's restore points: one per revision, oldest first.",
        discussion: """
            Each row is a revision the note can be viewed at (`export --at`) or restored to
            (`notes restore --to`): kind, wall time, device, app and the revision name. Revisions
            deleted by compaction are not restore points; a point marked "incomplete" cannot be
            rebuilt because revisions before it were compacted away or are unreadable.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let loaded = try vault.loadNote(id)
        let points = loaded.restorePoints
        if !loaded.failures.isEmpty {
            printError("warning: \(loaded.failures.count) unreadable revision(s) are not listed (see `notes show`)")
        }
        if output.json {
            struct Point: Encodable {
                var revision: String; var kind: String; var hlc: String; var device: String; var seq: Int
                var wall: Date; var app: String; var complete: Bool
            }
            try output.emitJSON(points.map {
                Point(revision: $0.name.filename, kind: $0.kind.rawValue, hlc: $0.hlc.description,
                      device: $0.device.rawValue, seq: $0.name.seq, wall: $0.wall, app: $0.app, complete: $0.complete)
            })
            return
        }
        if points.isEmpty { output.info("No restore points."); return }
        var rows = output.quiet ? [] : [["KIND", "WALL", "DEVICE", "APP", "REVISION"]]
        for p in points {
            rows.append([p.kind.rawValue, Format.local(p.wall), p.device.rawValue, p.app,
                         p.name.filename + (p.complete ? "" : "  (incomplete)")])
        }
        print(Format.table(rows))
    }
}

struct NotesRestore: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore a note to an earlier revision by writing one new delta.",
        discussion: """
            History is never rewritten: the new delta removes pages and strokes that did not exist
            at the restore point, re-adds those removed since under new ids (with `parent` naming the
            old id) and sets title, tags, notebook, paper, page size, page order and recognition back.
            REVISION is a name from `notes history`, with or without its `.delta.age` /
            `.snapshot.age` suffix, or a unique prefix of 6 or more characters. Nothing is written
            when the note already matches, or with --dry-run. The device id and clock come from
            $XDG_STATE_HOME/sempere/device.json, as for `snapshot`.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Option(name: .long, help: ArgumentHelp("The revision to restore to.", valueName: "revision"))
    var to: String

    @Flag(name: .customLong("dry-run"), help: "Only say what would change.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let point = try NoteHistory.resolve(to, among: try vault.revisionNames(of: id))
        let stateURL = DeviceState.defaultURL()
        var device = try DeviceState.loadOrCreate(at: stateURL)
        var clock = device.clock
        let result = try vault.restore(note: id, toRevision: point, device: device.device, clock: &clock,
                                       wall: Date(), app: appName, dryRun: dryRun)
        if result.written {
            device.clock = clock
            try device.save(to: stateURL)
        }
        let noteName = id.uuidString.lowercased()
        if output.json {
            struct Out: Encodable {
                var note: String; var to: String; var dryRun: Bool; var changed: Bool; var file: String?
                var changes: RestoreSummary
            }
            try output.emitJSON(Out(note: noteName, to: point.filename, dryRun: dryRun, changed: result.delta != nil,
                                    file: result.written ? result.delta?.name.filename : nil, changes: result.summary))
            return
        }
        guard result.delta != nil else {
            output.info("\(noteName) already matches \(point.filename); nothing to write.")
            return
        }
        let s = result.summary
        var parts: [String] = []
        if s.pagesRemoved > 0 { parts.append("remove \(s.pagesRemoved) page(s)") }
        if s.pagesRestored > 0 { parts.append("re-add \(s.pagesRestored) page(s)") }
        if s.strokesRemoved > 0 { parts.append("remove \(s.strokesRemoved) stroke(s)") }
        if s.strokesRestored > 0 { parts.append("re-add \(s.strokesRestored) stroke(s)") }
        if s.pageOrderChanges > 0 { parts.append("reorder \(s.pageOrderChanges) page(s)") }
        if s.recognitionChanges > 0 { parts.append("reset recognition on \(s.recognitionChanges) page(s)") }
        if s.pagePaperChanges > 0 { parts.append("reset paper on \(s.pagePaperChanges) page(s)") }
        if s.itemsRemoved > 0 { parts.append("remove \(s.itemsRemoved) item(s)") }
        if s.itemsRestored > 0 { parts.append("re-add \(s.itemsRestored) item(s)") }
        if s.itemChanges > 0 { parts.append("set back \(s.itemChanges) item(s)") }
        if s.recordingsRemoved > 0 { parts.append("remove \(s.recordingsRemoved) recording(s)") }
        if s.recordingsRestored > 0 { parts.append("re-add \(s.recordingsRestored) recording(s)") }
        if s.recordingChanges > 0 { parts.append("set back \(s.recordingChanges) recording(s)") }
        if !s.metaFields.isEmpty { parts.append("set \(s.metaFields.joined(separator: ", "))") }
        if let d = s.deleted { parts.append(d ? "delete the note" : "undelete the note") }
        let what = parts.joined(separator: "; ")
        if dryRun {
            print("would restore \(noteName) to \(point.filename): \(what)")
        } else {
            print("restored \(noteName) to \(point.filename): \(what)")
            output.info("Wrote \(noteName)/\(result.delta?.name.filename ?? "")")
        }
    }
}
