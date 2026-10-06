import ArgumentParser
import Foundation
import Sempere

/// `sempere vault index`: the file listing a static web server cannot give
/// the web viewer (docs/web-viewer.md "Hosting").
struct VaultIndex: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Write sempere-index.json, the note and revision listing the web viewer reads on a static server.",
        discussion: """
            A plain static web server cannot list folders, so the web viewer (web/, docs/web-viewer.md) reads
            this file instead: {"format": "sempere-index/1", "notes": {"<noteId>": ["<revision file>", ...]}}.
            It holds only names that storage already shows (note ids and revision file names), never
            content, and needs no key. Run it after every sync of the mirror the viewer reads; a WebDAV
            server needs no index. --out - prints it instead of writing <vault>/sempere-index.json.
            """
    )

    /// The file the viewer looks for at the vault root.
    static let fileName = "sempere-index.json"

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    @Option(name: .long, help: "Where to write the index (default <vault>/sempere-index.json; - for stdout).")
    var out: String?

    func run() throws {
        let vault = try access.openVault(.ifPossible)
        var notes: [String: [String]] = [:]
        var revisions = 0
        for id in try vault.noteIDs() {
            let names = try vault.revisionNames(of: id).map(\.filename).sorted()
            notes[id.uuidString.lowercased()] = names
            revisions += names.count
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(Index(format: "sempere-index/1", notes: notes))
        data.append(0x0A)
        if out == "-" {
            FileHandle.standardOutput.write(data)
            return
        }
        let url = out.map { URL(fileURLWithPath: $0) } ?? vault.url.appendingPathComponent(Self.fileName)
        try data.write(to: url, options: .atomic)
        if output.json {
            try output.emitJSON(Report(path: url.path, notes: notes.count, revisions: revisions))
        } else {
            output.info("Wrote \(url.path): \(notes.count) notes, \(revisions) revisions")
        }
    }

    private struct Index: Encodable {
        var format: String
        var notes: [String: [String]]
    }

    private struct Report: Encodable {
        var path: String
        var notes: Int
        var revisions: Int
    }
}
