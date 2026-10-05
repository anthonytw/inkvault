import ArgumentParser
import Foundation
import InkImport
import InkVault

struct ImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import notes from other apps.",
        subcommands: [ImportNotability.self]
    )
}

struct ImportNoteJSON: Encodable {
    var source: String
    var status: String
    var reason: String?
    var id: String?
    var title: String?
    var notebook: String?
    var strokes: Int
    var recognizedPages: Int
    var originalWidth: Double?
    var dropped: Dropped
    var seconds: Double

    struct Dropped: Encodable {
        var typedTextCharacters: Int, pdfs: Int, pdfPages: Int, media: Int, recordings: Int
        var dashedStrokes: Int, unknownStyleStrokes: Int
    }

    init(_ r: NotabilityImporter.NoteResult) {
        source = r.source; id = r.noteId?.uuidString.lowercased(); title = r.title; notebook = r.notebook
        strokes = r.strokes; recognizedPages = r.recognizedPages; originalWidth = r.originalWidth
        seconds = r.seconds
        let d = r.dropped
        dropped = Dropped(typedTextCharacters: d.typedTextCharacters, pdfs: d.pdfs, pdfPages: d.pdfPages, media: d.media,
                          recordings: d.recordings, dashedStrokes: d.dashedStrokes,
                          unknownStyleStrokes: d.unknownStyleStrokes)
        switch r.status {
        case .ok: status = "imported"
        case .skipped(let why): status = "skipped"; reason = why
        case .failed(let why): status = "failed"; reason = why
        }
    }
}

struct ImportNotability: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notability",
        abstract: "Import Notability .note files into a vault.",
        discussion: """
            Each PATH is a .note file (zip), an unzipped .note package directory, a folder searched
            recursively for .note files, or a zip of .note files (Notability's backup). Notes already
            in the vault are skipped unless --overwrite. The device id and clock come from
            $XDG_STATE_HOME/inkvault/device.json; --dry-run leaves both and the vault untouched.
            Exit 1 if any note failed.
            """
    )

    @Argument(help: ArgumentHelp("A .note file or package, a folder, or a zip of notes.", valueName: "path"))
    var paths: [String]

    @Option(name: .long, help: ArgumentHelp("File every note under this notebook.", valueName: "name"))
    var notebook: String?

    @Flag(name: .long, help: "Re-import notes that are already in the vault (replaces their pages).")
    var overwrite = false

    @Flag(name: .long, help: "Report what would happen without writing to the vault or the device state.")
    var dryRun = false

    @Flag(name: .long, help: "Keep Notability's document units instead of scaling to 612 pt width.")
    var noScale = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if paths.isEmpty { throw ValidationError("give at least one PATH") }
    }

    func run() throws {
        let options = NotabilityImporter.Options(overwrite: overwrite, notebook: notebook, scaleToLetterWidth: !noScale)
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let report: NotabilityImporter.ImportReport
        if dryRun {
            // Import into a throwaway copy of the vault with a throwaway device.
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("inkvault-dry-run-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let source = try access.vaultURL()
            let copy = scratch.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: copy)
            } catch {
                throw CLIError.failure("cannot prepare dry run: \(error.localizedDescription)")
            }
            let vault = try access.openVault(at: copy, .required)
            var clock = HybridClock()
            report = try NotabilityImporter.import(paths: urls, into: vault, device: .random(), clock: &clock,
                                                   options: options)
        } else {
            let vault = try access.openVault(.required)
            let stateURL = DeviceState.defaultURL()
            var state = try DeviceState.loadOrCreate(at: stateURL)
            var clock = state.clock
            defer {
                // Keep the clock even when the import throws half way.
                state.clock = clock
                try? state.save(to: stateURL)
            }
            report = try NotabilityImporter.import(paths: urls, into: vault, device: state.device, clock: &clock,
                                                   options: options)
        }
        try emit(report)
        if report.notes.isEmpty { throw CLIError.failure("no .note files found in the given paths") }
        if report.failed > 0 { throw CLIError.failure("\(report.failed) note(s) failed to import") }
    }

    private func emit(_ report: NotabilityImporter.ImportReport) throws {
        if output.json {
            struct Summary: Encodable { var dryRun: Bool, notes: Int, imported: Int, skipped: Int, failed: Int, strokes: Int }
            struct Out: Encodable { var summary: Summary; var notes: [ImportNoteJSON] }
            try output.emitJSON(Out(summary: Summary(dryRun: dryRun, notes: report.notes.count, imported: report.imported,
                                                     skipped: report.skipped, failed: report.failed, strokes: report.strokes),
                                    notes: report.notes.map(ImportNoteJSON.init)))
            return
        }
        var rows = output.quiet ? [] : [["STATUS", "TITLE", "NOTEBOOK", "STROKES", "TEXT", "SOURCE"]]
        for n in report.notes {
            let status: String
            switch n.status {
            case .ok: status = dryRun ? "would import" : "imported"
            case .skipped: status = "skipped"
            case .failed: status = "FAILED"
            }
            rows.append([status, n.title.map { $0.isEmpty ? "(untitled)" : $0 } ?? "-", n.notebook ?? "-",
                         String(n.strokes), String(n.recognizedPages), n.source])
        }
        if !rows.isEmpty { print(Format.table(rows)) }
        for n in report.notes {
            switch n.status {
            case .skipped(let why) where !output.quiet: print("skipped \(n.source): \(why)")
            case .failed(let why): printStderr("failed \(n.source): \(why)")
            default: break
            }
            if n.status == .ok, n.strokes == 0, n.dropped.pdfPages > 0, !output.quiet {
                print("no ink in \(n.source): its \(n.dropped.pdfPages) page(s) are PDF pages, which are not imported yet")
            }
            if output.verbose, !n.dropped.isEmpty {
                let d = n.dropped
                let parts = [(d.typedTextCharacters, "typed text characters"), (d.pdfs, "pdfs"),
                             (d.pdfPages, "pdf pages (imported as blank paper)"), (d.media, "media objects"),
                             (d.recordings, "recordings"), (d.dashedStrokes, "dashed strokes imported solid"),
                             (d.unknownStyleStrokes, "strokes of unknown style imported as pen")]
                    .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
                print("not imported from \(n.source): " + parts.joined(separator: ", "))
            }
        }
        output.info("\(dryRun ? "Dry run: " : "")\(report.imported) \(dryRun ? "would be imported" : "imported"), "
                    + "\(report.skipped) skipped, \(report.failed) failed; \(report.strokes) strokes.")
    }
}
