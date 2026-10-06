import ArgumentParser
import Foundation
import SempereImport
import Sempere

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
    var format: String
    var shapes: Int
    var duplicateOf: String?
    var extraVersion: Bool
    var selection: String?
    var attachments: Attachments
    var warnings: [String]

    struct Dropped: Encodable {
        var typedTextCharacters: Int, pdfs: Int, pdfPages: Int, media: Int, recordings: Int
        var pdfHighlights: Int, templatePDFs: Int, recLinks: Int
        var dashedStrokes: Int, unknownStyleStrokes: Int
        var defaultedAttributeStrokes: Int, unsupportedShapes: Int, unsupportedStrokes: Int, clampedStrokes: Int
    }

    struct Attachments: Encodable {
        var pdfs: Int, pdfPages: Int, templatePages: Int, images: Int, textItems: Int, textCharacters: Int
        var recordings: Int, recLinkedStrokes: Int, blobs: Int, blobBytes: Int64
    }

    init(_ r: NotabilityImporter.NoteResult) {
        source = r.source; id = r.noteId?.uuidString.lowercased(); title = r.title; notebook = r.notebook
        strokes = r.strokes; recognizedPages = r.recognizedPages; originalWidth = r.originalWidth
        seconds = r.seconds
        format = r.format.rawValue; shapes = r.shapes; duplicateOf = r.duplicateOf
        extraVersion = r.extraVersion; selection = r.selection
        let a = r.attachments
        attachments = Attachments(pdfs: a.pdfs, pdfPages: a.pdfPages, templatePages: a.templatePages, images: a.images,
                                  textItems: a.textItems, textCharacters: a.textCharacters, recordings: a.recordings,
                                  recLinkedStrokes: a.recLinkedStrokes, blobs: a.blobs, blobBytes: a.blobBytes)
        warnings = r.warnings
        let d = r.dropped
        dropped = Dropped(typedTextCharacters: d.typedTextCharacters, pdfs: d.pdfs, pdfPages: d.pdfPages, media: d.media,
                          recordings: d.recordings, pdfHighlights: d.pdfHighlights, templatePDFs: d.templatePDFs,
                          recLinks: d.recLinks,
                          dashedStrokes: d.dashedStrokes,
                          unknownStyleStrokes: d.unknownStyleStrokes,
                          defaultedAttributeStrokes: d.defaultedAttributeStrokes,
                          unsupportedShapes: d.unsupportedShapes, unsupportedStrokes: d.unsupportedStrokes,
                          clampedStrokes: d.clampedStrokes)
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
            Each PATH is a .note or .ntb file, an unzipped .note package directory, a folder searched
            recursively for both, or a zip of them (Notability's backup; pass every part of a split
            backup). Copies of one note are resolved across all paths: the newest .note with ink is imported,
            copies with no other ink are skipped, and a copy holding ink the chosen one lacks is
            imported as a separate note. Notes already in the vault are skipped unless --overwrite.
            PDF pages become page backgrounds, images image items, typed text text items and
            recordings the note's recordings; files are stored encrypted in the note's att/ folder (image
            metadata stripped unless --keep-image-metadata). --no-attachments imports ink only. The device id and clock come from
            $XDG_STATE_HOME/sempere/device.json; --dry-run leaves both and the vault untouched.
            Exit 1 if any note failed.
            """
    )

    @Argument(help: ArgumentHelp("A .note or .ntb file, a .note package, a folder, or a zip of notes.", valueName: "path"))
    var paths: [String]

    @Option(name: .long, help: ArgumentHelp("File every note under this notebook.", valueName: "name"))
    var notebook: String?

    @Flag(name: .long, help: "Re-import notes that are already in the vault (replaces their pages).")
    var overwrite = false

    @Flag(name: .long, help: "Report what would happen without writing to the vault or the device state.")
    var dryRun = false

    @Flag(name: .long, help: "Keep Notability's document units instead of scaling to 612 pt width.")
    var noScale = false

    @Flag(name: .long, help: "Do not tag notes with their Notability folder names (tagging is on by default).")
    var noFolderTags = false

    @Option(name: .customLong("tag"), help: ArgumentHelp("Add this tag to every imported note (repeatable).", valueName: "tag"))
    var tags: [String] = []

    @Flag(name: .long, help: "Import ink only: no PDF backgrounds, images, typed text or recordings (reported as dropped).")
    var noAttachments = false

    @Flag(name: .long, help: "Store images with their camera and location metadata (stripped by default).")
    var keepImageMetadata = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if paths.isEmpty { throw ValidationError("give at least one PATH") }
    }

    func run() throws {
        let options = NotabilityImporter.Options(overwrite: overwrite, notebook: notebook, scaleToLetterWidth: !noScale,
                                                 tagsFromFolders: !noFolderTags, extraTags: tags,
                                                 attachments: !noAttachments, keepImageMetadata: keepImageMetadata)
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let report: NotabilityImporter.ImportReport
        if dryRun {
            // Import into a throwaway copy of the vault with a throwaway device.
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("sempere-dry-run-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let source = try access.vaultURL()
            try Vault.open(at: source).requireMigrated()   // refused before copying anything
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
        if report.notes.isEmpty { throw CLIError.failure("no .note or .ntb files found in the given paths") }
        if report.failed > 0 { throw CLIError.failure("\(report.failed) note(s) failed to import") }
    }

    private func emit(_ report: NotabilityImporter.ImportReport) throws {
        let written = report.notes.filter { $0.status == .ok }
        if output.json {
            struct Summary: Encodable {
                var dryRun: Bool, notes: Int, imported: Int, skipped: Int, failed: Int, strokes: Int
                var ntb: Int, extraVersions: Int
                var pdfPages: Int, images: Int, textItems: Int, recordings: Int, recLinkedStrokes: Int
                var blobs: Int, blobBytes: Int64, droppedPDFPages: Int, droppedMedia: Int
            }
            struct Out: Encodable { var summary: Summary; var notes: [ImportNoteJSON] }
            try output.emitJSON(Out(summary: Summary(dryRun: dryRun, notes: report.notes.count, imported: report.imported,
                                                     skipped: report.skipped, failed: report.failed, strokes: report.strokes,
                                                     ntb: report.notes.filter { $0.format == .ntb }.count,
                                                     extraVersions: report.notes.filter(\.extraVersion).count,
                                                     pdfPages: written.reduce(0) { $0 + $1.attachments.pdfPages },
                                                     images: written.reduce(0) { $0 + $1.attachments.images },
                                                     textItems: written.reduce(0) { $0 + $1.attachments.textItems },
                                                     recordings: written.reduce(0) { $0 + $1.attachments.recordings },
                                                     recLinkedStrokes: written.reduce(0) { $0 + $1.attachments.recLinkedStrokes },
                                                     blobs: written.reduce(0) { $0 + $1.attachments.blobs },
                                                     blobBytes: written.reduce(0) { $0 + $1.attachments.blobBytes },
                                                     droppedPDFPages: written.reduce(0) { $0 + $1.dropped.pdfPages },
                                                     droppedMedia: written.reduce(0) { $0 + $1.dropped.media }),
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
            if n.status == .ok, n.extraVersion, !output.quiet, let why = n.selection {
                print("separate version \(n.source): \(why)")
            }
            if n.status == .ok, n.strokes == 0, n.dropped.pdfPages > 0, !output.quiet {
                print("no ink in \(n.source), and \(n.dropped.pdfPages) of its PDF page(s) were not imported"
                      + (noAttachments ? " (--no-attachments)" : ""))
            }
            if output.verbose, n.status == .ok {
                for w in n.warnings { print("attachments \(n.source): \(w)") }
            }
            if output.verbose, !n.dropped.isEmpty {
                let d = n.dropped
                let parts = [(d.typedTextCharacters, "typed text characters"), (d.pdfs, "pdfs"),
                             (d.pdfPages, "pdf pages (imported as blank paper)"), (d.media, "media objects"),
                             (d.pdfHighlights, "pdf highlights"), (d.templatePDFs, "template PDF paper"),
                             (d.recLinks, "stroke links to recordings"),
                             (d.recordings, "recordings"), (d.dashedStrokes, "dashed strokes imported solid"),
                             (d.unknownStyleStrokes, "strokes of unknown style imported as pen"),
                             (d.defaultedAttributeStrokes, "strokes with a missing style, colour or width (defaulted)"),
                             (d.unsupportedShapes, "shapes not converted"),
                             (d.unsupportedStrokes, "strokes of an undecoded .ntb kind"),
                             (d.clampedStrokes, ".ntb strokes placed at the page edge (position not stored)")]
                    .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
                print("not imported from \(n.source): " + parts.joined(separator: ", "))
            }
        }
        output.info("\(dryRun ? "Dry run: " : "")\(report.imported) \(dryRun ? "would be imported" : "imported"), "
                    + "\(report.skipped) skipped, \(report.failed) failed; \(report.strokes) strokes.")
    }
}
