import ArgumentParser
import Foundation
import SempereRender
import Sempere

enum ExportFormat: String, ExpressibleByArgument, CaseIterable {
    case pdf, svg, png, json, markdown, html
}

struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export notes to PDF, SVG or PNG (one file per page), JSON, or a Markdown or HTML folder tree.",
        discussion: """
            File names are the sanitised title plus the first 8 characters of the note id, e.g.
            Physics-week-3-0d1c6a1e.pdf. --out is a directory, except for a single note's pdf/json
            (a path ending in .pdf/.json is taken as the file) and for --merge (always the file).
            Deleted notes are skipped by --all unless --deleted; a deleted note named explicitly
            is exported with a warning. --at exports a single note as it was at that revision (a
            name from `notes history`, as for `notes restore --to`).

            markdown and html write a folder tree under --out that mirrors the notebook hierarchy:
            markdown gives <name>.md (YAML front matter, the PDF, recognised text) plus the PDF,
            optionally per-page PNGs (--images png), and a README.md per folder; html gives one
            self-contained <name>.html per note and an index.html with a search box. Re-running
            rewrites only files whose content changed; --clean (with --all) removes files an earlier
            run wrote that this run did not. WARNING: these formats write your notes as PLAINTEXT.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title (or use --all).", valueName: "id|title"))
    var note: String?

    @Flag(name: .long, help: "Export every note.")
    var all = false

    @Option(name: .long, help: "pdf, svg, png or json.")
    var format: ExportFormat

    @Option(name: .long, help: ArgumentHelp("Output path (see above).", valueName: "path"))
    var out: String

    @Option(name: .long, help: ArgumentHelp("With --all, only notes in this notebook or below it.", valueName: "name"))
    var notebook: String?

    @Option(name: .long, help: "markdown only: none or png (a PNG per page, embedded in the note).")
    var images: ExportImages = .none

    @Flag(name: .long, help: "markdown/html: remove files an earlier export wrote that this run did not (needs --all).")
    var clean = false

    @Flag(name: .long, help: "pdf only: write all notes into one PDF file.")
    var merge = false

    @Option(name: .long, help: "png only: resolution in dots per inch (a page point is 1/72 inch).")
    var dpi: Double = 144

    @Flag(name: .long, help: "With --all, include deleted notes.")
    var deleted = false

    @Flag(name: .customLong("no-paper"), help: "Leave out the paper background and ruling.")
    var noPaper = false

    @Option(name: .long, help: ArgumentHelp("Export the note as of this revision (see `notes history`).",
                                            valueName: "revision"))
    var at: String?

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard all != (note != nil) else { throw ValidationError("give exactly one of a note (id or title) and --all") }
        if merge && format != .pdf { throw ValidationError("--merge only applies to --format pdf") }
        if at != nil && all { throw ValidationError("--at needs a single note, not --all") }
        let tree = format == .markdown || format == .html
        if images != .none && format != .markdown { throw ValidationError("--images only applies to --format markdown") }
        if clean && !tree { throw ValidationError("--clean only applies to --format markdown or html") }
        if clean && !all { throw ValidationError("--clean needs --all") }
        if notebook != nil && !all { throw ValidationError("--notebook needs --all") }
        if format == .markdown && images == .png && !(dpi.isFinite && dpi > 0 && dpi <= 2400) {
            throw ValidationError("--dpi must be greater than 0 and at most 2400")
        }
        if format == .png, !(dpi.isFinite && dpi > 0 && dpi <= 2400) {
            throw ValidationError("--dpi must be greater than 0 and at most 2400")
        }
    }

    private struct Written: Encodable { var note: String; var files: [String]; var changed: [String]? = nil }

    func run() throws {
        let vault = try access.openVault(.required)
        // Each note is decrypted once: loaded, summarised and reconstructed from the same read.
        let ids = try note.map { [try vault.resolveNote($0)] } ?? vault.noteIDs()
        var states: [(NoteSummary, NoteState)] = []
        var failures = 0
        var failedIDs = Set<String>()
        for id in ids {
            let loaded = try vault.loadNote(id)
            let s = vault.summary(of: id, loaded: loaded)
            if note != nil {
                if s.deleted { printStderr("sempere: warning: \(id.uuidString.lowercased()) is deleted") }
            } else if s.deleted && !deleted {
                continue
            }
            if let nb = notebook, !NotebookPath.name(s.notebook, isWithin: nb) { continue }
            do {
                if let at {
                    let point = try NoteHistory.resolve(at, among: loaded.revisions.map(\.name))
                    states.append((s, try loaded.state(at: point)))
                } else {
                    states.append((s, try vault.reconstruct(loaded)))
                }
            } catch {
                failures += 1
                failedIDs.insert(id.uuidString.lowercased())
                printError("\(id.uuidString.lowercased()): \(CLIError.from(error).message)")
            }
        }
        if states.isEmpty { throw CLIError.failure("no notes to export") }

        let options = RenderOptions(paper: !noPaper)
        let fm = FileManager.default
        func mkdir(_ path: String) throws {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        func write(_ data: Data, to path: String) throws {
            do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) } catch {
                throw CLIError.failure("cannot write \(path): \(error.localizedDescription)")
            }
        }

        var written: [Written] = []
        func report(_ s: NoteSummary, _ files: [String]) {
            written.append(Written(note: s.id.uuidString.lowercased(), files: files))
            if !output.json { for f in files { output.info("Wrote \(f)") } }
        }

        let singleFile = note != nil && (out.hasSuffix(".\(format.rawValue)") && format != .svg
                                         && format != .markdown && format != .html)
        if format == .markdown || format == .html {
            let tree = TreeExporter(root: URL(fileURLWithPath: out), format: format, images: images, options: options,
                                    png: PNGOptions(dpi: dpi), source: "sempere", clean: clean, notebookFilter: notebook)
            var counts = (written: 0, unchanged: 0)
            let r = try tree.run(states, protected: failedIDs, vaultSource: "sempere:\(vault.vaultId.uuidString.lowercased())") { file, changed in
                if changed { counts.written += 1 } else { counts.unchanged += 1 }
                if changed && !output.json { output.info("Wrote \(file)") }
            }
            for e in r.errors { printError(e) }
            failures += r.failures
            written = r.results.map { Written(note: $0.noteId, files: $0.files, changed: $0.changed) }
            output.info("\(r.results.count) note(s): \(counts.written) file(s) written, \(counts.unchanged) unchanged (PLAINTEXT in \(out))")
        } else if merge {
            try mkdir(URL(fileURLWithPath: out).deletingLastPathComponent().path)
            try write(try PDFWriter.render(notes: states.map(\.1), options: options), to: out)
            written.append(Written(note: "*", files: [out]))
            output.info("Wrote \(out) (\(states.count) note(s))")
        } else {
            if !singleFile { try mkdir(out) } else { try mkdir(URL(fileURLWithPath: out).deletingLastPathComponent().path) }
            for (s, state) in states {
                let stem = ExportName.stem(title: state.meta.title, noteId: s.id)
                func path(_ name: String) -> String { URL(fileURLWithPath: out).appendingPathComponent(name).path }
                do {
                    switch format {
                    case .pdf:
                        let file = singleFile ? out : path(stem + ".pdf")
                        try write(try PDFWriter.render(note: state, options: options), to: file)
                        report(s, [file])
                    case .json:
                        let file = singleFile ? out : path(stem + ".json")
                        try write(try InkJSON.encoder().encode(state), to: file)
                        report(s, [file])
                    case .markdown, .html:
                        break
                    case .svg, .png:
                        let pages: [Data]
                        if format == .png {
                            pages = try PNGWriter.render(note: state, options: options, png: PNGOptions(dpi: dpi))
                        } else {
                            pages = try SVGWriter.render(note: state, options: options).map { Data($0.utf8) }
                        }
                        let ext = format.rawValue
                        var files: [String] = []
                        if all { try mkdir(path(stem)) }
                        for (i, data) in pages.enumerated() {
                            let file = all ? path(stem + String(format: "/p%03d.", i + 1) + ext)
                                : path(stem + String(format: "-p%03d.", i + 1) + ext)
                            try write(data, to: file)
                            files.append(file)
                        }
                        report(s, files)
                    }
                } catch let e as CLIError {
                    throw e
                } catch {
                    failures += 1
                    printError("\(s.id.uuidString.lowercased()): \(CLIError.from(error).message)")
                }
            }
        }
        if output.json { try output.emitJSON(written) }
        if failures > 0 { throw CLIError.failure("\(failures) note(s) could not be exported") }
    }
}
