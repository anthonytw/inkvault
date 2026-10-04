import ArgumentParser
import Foundation
import InkVault

struct NotesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "List notes and show their history.",
        subcommands: [NotesList.self, NotesShow.self]
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
        discussion: "Deleted notes are hidden unless --deleted."
    )

    @Option(name: .long, help: ArgumentHelp("Only notes with this tag.", valueName: "tag"))
    var tag: String?

    @Option(name: .long, help: ArgumentHelp("Only notes in this notebook.", valueName: "name"))
    var notebook: String?

    @Flag(name: .long, help: "Include deleted notes.")
    var deleted = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let notes = try vault.summaries().filter { n in
            (deleted || !n.deleted) && (tag.map(n.tags.contains) ?? true) && (notebook.map { n.notebook == $0 } ?? true)
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
        let loaded = try vault.loadNote(id)
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
