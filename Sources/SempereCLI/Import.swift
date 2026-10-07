import ArgumentParser
import Foundation
import SempereImport
import SempereRender
import Sempere

struct ImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import notes from other apps.",
        subcommands: [ImportNotability.self, ImportPDFCommand.self]
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
    /// `meta.lang` (BCP 47), when the note has a handwriting language.
    var lang: String?
    var markersBehindText: Bool
    /// `#RRGGBBAA` from `paperColor`, when the note has one.
    var paperColor: String?

    struct Dropped: Encodable {
        var typedTextCharacters: Int, pdfs: Int, pdfPages: Int, media: Int, recordings: Int
        var pdfHighlights: Int, templatePDFs: Int, recLinks: Int
        var dashedStrokes: Int, unknownStyleStrokes: Int
        var defaultedAttributeStrokes: Int, unsupportedShapes: Int, unsupportedStrokes: Int, clampedStrokes: Int
        var bundleRecordsWithoutFile: Int, bundleFilesUnreferenced: Int, pdfTextPages: Int
    }

    struct Attachments: Encodable {
        var pdfs: Int, pdfPages: Int, templatePages: Int, images: Int, textItems: Int, textCharacters: Int
        var recordings: Int, recLinkedStrokes: Int, blobs: Int, blobBytes: Int64
        var pdfTextPages: Int, pdfTextFromIndex: Int, pdfTextExtracted: Int
        var bundlePDFRecords: Int, bundleMediaRecords: Int, bundleFiles: Int, bundleFilesImported: Int
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
                                  recLinkedStrokes: a.recLinkedStrokes, blobs: a.blobs, blobBytes: a.blobBytes,
                                  pdfTextPages: a.pdfTextPages, pdfTextFromIndex: a.pdfTextFromIndex,
                                  pdfTextExtracted: a.pdfTextExtracted, bundlePDFRecords: a.bundlePDFRecords,
                                  bundleMediaRecords: a.bundleMediaRecords, bundleFiles: a.bundleFiles,
                                  bundleFilesImported: a.bundleFilesImported)
        warnings = r.warnings
        lang = r.lang; markersBehindText = r.markersBehindText; paperColor = r.paperColor
        let d = r.dropped
        dropped = Dropped(typedTextCharacters: d.typedTextCharacters, pdfs: d.pdfs, pdfPages: d.pdfPages, media: d.media,
                          recordings: d.recordings, pdfHighlights: d.pdfHighlights, templatePDFs: d.templatePDFs,
                          recLinks: d.recLinks,
                          dashedStrokes: d.dashedStrokes,
                          unknownStyleStrokes: d.unknownStyleStrokes,
                          defaultedAttributeStrokes: d.defaultedAttributeStrokes,
                          unsupportedShapes: d.unsupportedShapes, unsupportedStrokes: d.unsupportedStrokes,
                          clampedStrokes: d.clampedStrokes, bundleRecordsWithoutFile: d.bundleRecordsWithoutFile,
                          bundleFilesUnreferenced: d.bundleFilesUnreferenced, pdfTextPages: d.pdfTextPages)
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

    @Option(name: .long, help: ArgumentHelp(
        "After importing, read the handwriting of pages Notability never indexed (macOS only).", valueName: "missing"))
    var recognize: RecognizeAfterImport?

    @OptionGroup var pdfText: PDFTextOptions

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    enum RecognizeAfterImport: String, ExpressibleByArgument, CaseIterable {
        case missing
    }

    func validate() throws {
        if paths.isEmpty { throw ValidationError("give at least one PATH") }
    }

    func run() throws {
        // Refused before anything is imported, not after.
        if recognize != nil && !dryRun && !RecognitionRun.available { throw RecognitionRun.unavailable }
        let options = NotabilityImporter.Options(overwrite: overwrite, notebook: notebook, scaleToLetterWidth: !noScale,
                                                 tagsFromFolders: !noFolderTags, extraTags: tags,
                                                 attachments: !noAttachments, keepImageMetadata: keepImageMetadata,
                                                 pdfText: try pdfText.extractor())
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let report: NotabilityImporter.ImportReport
        var recognized: [RecognitionRun.NoteResult] = []
        /// Runs `--recognize` over the notes just written.
        func recognizeImported(_ report: NotabilityImporter.ImportReport, in vault: Vault) {
            guard recognize != nil else { return }
            recognized = report.notes.filter { $0.status == .ok }.compactMap(\.noteId).map {
                RecognitionRun.run(note: $0, vault: vault, mode: .missing, dryRun: dryRun)
            }
        }
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
            let vault = try access.openVault(at: copy, .required, trust: scratchTrustStore(for: source))
            var clock = HybridClock()
            report = try NotabilityImporter.import(paths: urls, into: vault, device: .random(), clock: &clock,
                                                   options: options)
            recognizeImported(report, in: vault)
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
            // Recognition writes through the device state file: save the import's clock first.
            state.clock = clock
            try state.save(to: stateURL)
            recognizeImported(report, in: vault)
            if let saved = try? DeviceState.loadOrCreate(at: stateURL) { state = saved; clock = saved.clock }
        }
        try emit(report, recognized: recognized)
        if report.notes.isEmpty { throw CLIError.failure("no .note or .ntb files found in the given paths") }
        if report.failed > 0 { throw CLIError.failure("\(report.failed) note(s) failed to import") }
        let unread = recognized.filter { $0.error != nil }.count
        if unread > 0 { throw CLIError.failure("\(unread) imported note(s) could not be recognised") }
    }

    private func emit(_ report: NotabilityImporter.ImportReport, recognized: [RecognitionRun.NoteResult]) throws {
        let written = report.notes.filter { $0.status == .ok }
        let ntb = written.filter { $0.format == .ntb }
        if output.json {
            struct Summary: Encodable {
                var dryRun: Bool, notes: Int, imported: Int, skipped: Int, failed: Int, strokes: Int
                var ntb: Int, extraVersions: Int
                var pdfPages: Int, images: Int, textItems: Int, recordings: Int, recLinkedStrokes: Int
                var blobs: Int, blobBytes: Int64, droppedPDFPages: Int, droppedMedia: Int
                /// Counts to compare with a backup (docs/import-notability.md "Report").
                var pdfs: Int, ntbPDFPages: Int, ntbImages: Int, ntbDroppedPDFs: Int
                var pdfTextPages: Int, pdfTextFromIndex: Int, pdfTextExtracted: Int, pdfPagesWithoutText: Int
                var languages: [String: Int], markersBehindText: Int, paperColors: Int
            }
            struct Out: Encodable {
                var summary: Summary; var notes: [ImportNoteJSON]; var recognized: [RecognitionRun.NoteResult]?
            }
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
                                                     droppedMedia: written.reduce(0) { $0 + $1.dropped.media },
                                                     pdfs: written.reduce(0) { $0 + $1.attachments.pdfs },
                                                     ntbPDFPages: ntb.reduce(0) { $0 + $1.attachments.pdfPages },
                                                     ntbImages: ntb.reduce(0) { $0 + $1.attachments.images },
                                                     ntbDroppedPDFs: ntb.reduce(0) { $0 + $1.dropped.pdfs },
                                                     pdfTextPages: written.reduce(0) { $0 + $1.attachments.pdfTextPages },
                                                     pdfTextFromIndex: written.reduce(0) { $0 + $1.attachments.pdfTextFromIndex },
                                                     pdfTextExtracted: written.reduce(0) { $0 + $1.attachments.pdfTextExtracted },
                                                     pdfPagesWithoutText: written.reduce(0) { $0 + $1.dropped.pdfTextPages },
                                                     languages: written.reduce(into: [:]) { m, n in if let l = n.lang { m[l, default: 0] += 1 } },
                                                     markersBehindText: written.filter(\.markersBehindText).count,
                                                     paperColors: written.filter { $0.paperColor != nil }.count),
                                    notes: report.notes.map(ImportNoteJSON.init),
                                    recognized: recognize == nil ? nil : recognized))
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
        if recognize != nil {
            let pages = recognized.reduce(0) { $0 + $1.read.count }
            output.info("Recognition: \(pages) page(s) without Notability's text \(dryRun ? "would be read" : "read") in "
                        + "\(recognized.filter { !$0.read.isEmpty }.count) note(s).")
            for r in recognized where r.error != nil {
                printStderr("recognition failed for \(r.note): \(r.error ?? "")")
            }
        }
    }
}

// MARK: - import pdf

struct ImportPDFCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf",
        abstract: "Make a note from each PDF: one page per PDF page, the page as its background.",
        discussion: """
            The PDF is stored as one blob of the new note and each page becomes a note page with a pdfPage \
            item that fills it (docs/attachments.md §8): the note's page size is the first PDF page's \
            (effective size: crop box, rotation), paper is blank, later pages of another size are fitted and \
            centred. Everything is one delta. The title is --title (one file only) or the file name without \
            .pdf. Encrypted PDFs are refused, and so are more than 2000 pages; --pages imports a subset. \
            Each page's text is stored for search (--pdf-text: pdftotext when installed, else the built-in \
            reader; format.md §8.2.6). Writing on the pages is the app's job: ink is stored as usual on top. \
            Exit 1 if any file failed.
            """
    )

    @Argument(help: ArgumentHelp("PDF files.", valueName: "file"))
    var files: [String]

    @Option(name: .long, help: ArgumentHelp("Title of the note (a single file only; default: the file name).", valueName: "title"))
    var title: String?

    @Option(name: .long, help: ArgumentHelp("Put the note in this notebook (School/Math for levels).", valueName: "path"))
    var notebook: String?

    @Option(name: .customLong("tag"), help: ArgumentHelp("Add this tag. Repeatable.", valueName: "tag"))
    var tags: [String] = []

    @Option(name: .long, help: ArgumentHelp("Import only these PDF pages: 1-3,5,7- (default all).", valueName: "list"))
    var pages: PageSelection?

    @Flag(name: .customLong("dry-run"), help: "Check the files and say what would be imported; write nothing.")
    var dryRun = false

    @OptionGroup var pdfText: PDFTextOptions
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions
    @OptionGroup var cache: CacheOptions

    func validate() throws {
        if files.isEmpty { throw ValidationError("give at least one PDF file") }
        if title != nil && files.count > 1 { throw ValidationError("--title names one note: give one file, or no --title") }
    }

    struct Result: Encodable {
        var source: String
        var status: String
        var reason: String?
        var id: String?
        var title: String?
        var pages: Int?
        var blob: BlobRef?
        var file: String?
        /// Pages stored with their text (`pageText`, format.md §8.2.6) and the extractor.
        var pagesWithText: Int?
        var textEngine: String?
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let extractor = try pdfText.extractor()
        let known = NoteOps.normalizedTags(tags).isEmpty
            ? [] : NoteOps.vaultTags(try vault.summaries(of: nil, cache: cache.cache(for: vault)))
        let spelled = tags.map { NoteOps.tagSpelling($0, among: known) }
        var results: [Result] = []
        for path in files {
            var r = Result(source: path, status: dryRun ? "would import" : "imported")
            do {
                let data: Data
                do { data = try BoundedRead.contents(of: URL(fileURLWithPath: path), maxBytes: 1 << 30) } catch VaultError.fileTooLarge {
                    throw CLIError.failure("\(path) is larger than the 1 GiB limit")
                }
                let summary = try PDFIngest.inspect(data)
                var selected = try pages.map { try summary.pages(numbered: try $0.resolve(total: summary.pages.count)) } ?? summary.pages
                guard !selected.isEmpty else { throw CLIError.failure("no PDF pages selected") }
                let texts = PDFIngest.withText(selected, pdf: data, extractor: extractor)
                if texts.failed { printStderr("warning: \(extractor?.engine ?? "the extractor") could not read the text of \(path)") }
                selected = texts.refs
                r.pagesWithText = texts.withText
                r.textEngine = extractor?.engine
                let name = (title ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let ref = BlobRef(content: data, type: "application/pdf")
                let note = UUID()
                let ops = try NoteOps.newPDFNote(title: name, blob: ref, selected, notebook: NotebookPath.canonical(notebook), tags: spelled)
                r.id = note.uuidString.lowercased(); r.title = name; r.pages = selected.count; r.blob = ref
                if !dryRun {
                    _ = try vault.writeBlob(note: note, data, type: "application/pdf")
                    r.file = try vault.apply(ops, to: note, deviceState: DeviceState.defaultURL(), app: appName).name.filename
                }
            } catch {
                var e = CLIError.from(error)
                if let pdf = error as? PDFIngestError { e = .failure("\(pdf)") }
                if let ops = error as? AttachmentOpsError { e = .failure("\(ops)") }
                r.status = "failed"; r.reason = e.message
                r.id = nil
            }
            results.append(r)
        }
        let failed = results.filter { $0.status == "failed" }.count
        if output.json {
            struct Out: Encodable { var dryRun: Bool; var imported: Int; var failed: Int; var notes: [Result] }
            try output.emitJSON(Out(dryRun: dryRun, imported: results.count - failed, failed: failed, notes: results))
        } else {
            for r in results {
                if let id = r.id, output.quiet { print(id); continue }
                if r.status == "failed" { printStderr("failed \(r.source): \(r.reason ?? "")"); continue }
                print(r.id ?? "")
                output.info("\(dryRun ? "Would import" : "Imported") \(r.source): \(r.pages ?? 0) page(s) as \"\(r.title ?? "")\"")
            }
        }
        if failed > 0 { throw CLIError.failure("\(failed) file(s) failed to import") }
    }
}
