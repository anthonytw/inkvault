import ArgumentParser
import Foundation
import Sempere

struct NotesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "List, create and edit notes, switch page layout, show their history and restore earlier revisions.",
        subcommands: [NotesList.self, NotesShow.self, NotesNew.self, NotesRename.self, NotesTag.self, NotesMove.self,
                      NotesPaper.self, NotesLayout.self, NotesDelete.self, NotesUndelete.self, NotesHistory.self,
                      NotesRestore.self]
    )
}

struct NoteJSON: Encodable {
    var id: String
    var title: String
    var tags: [String]
    var notebook: String?
    var deleted: Bool
    var pages: Int
    var strokes: Int
    var recognizedPages: Int
    var modified: Date?
    var problem: String?

    init(_ s: NoteSummary) {
        id = s.id.uuidString.lowercased(); title = s.title; tags = s.tags; notebook = s.notebook
        deleted = s.deleted; pages = s.pages; strokes = s.strokes
        recognizedPages = s.recognizedPages; modified = s.modified; problem = s.problem
    }
}

struct NotesList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List notes: id, title, pages, strokes, modified.",
        discussion: """
            Deleted notes are hidden unless --deleted. Summaries are kept in an encrypted per-device cache \
            ($XDG_CACHE_HOME/sempere, default ~/.cache/sempere), so only notes with new revisions are read again.
            """
    )

    @Option(name: .long, help: ArgumentHelp("Only notes with this tag.", valueName: "tag"))
    var tag: String?

    @Option(name: .long, help: ArgumentHelp("Only notes in this notebook or below it.", valueName: "path"))
    var notebook: String?

    @Flag(name: .long, help: "Include deleted notes.")
    var deleted = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions
    @OptionGroup var cache: CacheOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let notes = try vault.summaries(of: nil, cache: cache.cache(for: vault)).filter { n in
            (deleted || !n.deleted) && (tag.map { t in n.tags.contains { NoteOps.tagKey($0) == NoteOps.tagKey(t) } } ?? true) && (notebook.map { NotebookPath.name(n.notebook, isWithin: $0) } ?? true)
        }
        if output.json { try output.emitJSON(notes.map(NoteJSON.init)); return }
        if notes.isEmpty { output.info("No notes."); return }
        var rows = output.quiet ? [] : [["ID", "TITLE", "PAGES", "STROKES", "MODIFIED"]]
        for n in notes {
            let title = (n.title.isEmpty ? "(untitled)" : n.title) + (n.deleted ? " [deleted]" : "")
                + (n.problem != nil ? " [!]" : "")
            rows.append([n.id.uuidString.lowercased(), title, String(n.pages), String(n.strokes), Format.local(n.modified)])
        }
        print(Format.table(rows))
    }
}

struct NotesShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show a note's metadata and revision history.",
        discussion: "The note is picked by id, an id prefix of 4 or more characters, or exact title."
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let loaded = try vault.loadNote(id, detail: .withoutStrokePoints)
        let summary = vault.summary(of: id, loaded: loaded)
        let history = loaded.history
        if output.json {
            struct Rev: Encodable { var name: String; var kind: String; var wall: Date?; var app: String?; var error: String? }
            struct Out: Encodable { var note: NoteJSON; var revisions: [Rev] }
            try output.emitJSON(Out(note: NoteJSON(summary), revisions: history.map {
                Rev(name: $0.name.filename, kind: $0.name.kind.rawValue, wall: $0.wall, app: $0.app,
                    error: $0.error.map { "\($0)" })
            }))
            return
        }
        print("Id:       \(summary.id.uuidString.lowercased())")
        print("Title:    \(summary.title.isEmpty ? "(untitled)" : summary.title)")
        print("Tags:     \(summary.tags.isEmpty ? "-" : summary.tags.joined(separator: ", "))")
        print("Notebook: \(summary.notebook ?? "-")")
        print("Deleted:  \(summary.deleted ? "yes" : "no")")
        print("Pages:    \(summary.pages)   Strokes: \(summary.strokes)")
        print("Text:     \(summary.recognizedPages) of \(summary.pages) page(s) with recognised text")
        print("Modified: \(Format.local(summary.modified))")
        if let p = summary.problem { print("Problem:  \(p)") }
        print("\nRevisions (\(history.count)):")
        print(Format.table(history.map { h in
            [h.name.kind.rawValue, Format.local(h.wall), h.name.filename,
             h.error.map { "UNREADABLE: \($0)" } ?? (output.verbose ? (h.app ?? "") : "")]
        }))
    }
}

enum NoteLayout: String, ExpressibleByArgument, CaseIterable {
    case paged, pageless
}

struct NotesLayout: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "layout",
        abstract: "Switch a note between paged and pageless by writing one new delta.",
        discussion: """
            pageless joins the pages into one infinite page (sheet height = the page height);
            paged cuts an infinite page into pages of its sheet height (breakHeight, default
            width x 11/8.5). No ink is deleted and none moves relative to its sheet: strokes that
            change page are re-added under new ids with `parent` naming the old ones (format.md
            §5.4.3). Nothing is written when the note already has the layout (a pageless note with
            several pages, left by concurrent edits, is joined), or with --dry-run.
            The device id and clock come from $XDG_STATE_HOME/sempere/device.json.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: "paged or pageless.")
    var layout: NoteLayout

    @Flag(name: .customLong("dry-run"), help: "Only say what would change.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let layout = self.layout
        func switched(_ state: NoteState) -> LayoutEdit {
            layout == .paged
                ? NoteOps.makePaged(pages: state.pages, pageSize: state.meta.pageSize)
                : NoteOps.makePageless(pages: state.pages, pageSize: state.meta.pageSize)
        }
        // The switch is computed from the note as it is on disk when the delta is written.
        var before = 0
        var edit = LayoutEdit(ops: [], pages: [], pageSize: .letter)
        var file: String?
        if dryRun {
            let state = try vault.reconstruct(try vault.loadNote(id))
            try requireLive(state)
            before = state.pages.count
            edit = switched(state)
        } else {
            file = try editNote(vault, id) { current in
                try requireLive(current)
                before = current.pages.count
                edit = switched(current)
                return edit.ops
            }?.name.filename
        }
        let noteName = id.uuidString.lowercased()
        if output.json {
            struct Out: Encodable {
                var note: String; var layout: String; var dryRun: Bool; var changed: Bool
                var pagesBefore: Int; var pagesAfter: Int; var file: String?
            }
            try output.emitJSON(Out(note: noteName, layout: layout.rawValue, dryRun: dryRun, changed: !edit.ops.isEmpty,
                                    pagesBefore: before, pagesAfter: edit.pages.count, file: file))
            return
        }
        guard !edit.ops.isEmpty else {
            output.info("\(noteName) is already \(layout.rawValue); nothing to write.")
            return
        }
        let what = "\(before) page(s) -> \(edit.pages.count) page(s)"
        print("\(dryRun ? "would make" : "made") \(noteName) \(layout.rawValue): \(what)")
        if let file { output.info("Wrote \(noteName)/\(file)") }
    }
}
