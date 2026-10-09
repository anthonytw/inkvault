import Foundation
import Sempere
import SempereImport
import UniformTypeIdentifiers

/// What a Notability import did, for the alert after it.
struct NotabilityImportSummary: Equatable, Sendable {
    var imported = 0
    var skipped = 0
    var failed = 0
    /// Source names (file names, never note content) of the notes that failed, with why.
    var failures: [String] = []
    /// Nothing to import was found in what was picked.
    var nothingFound = false
    /// What was imported and left out, and the importer's warnings (the report sheet).
    var details = NotabilityImportDetails()

    /// `failures` are (source path, why); only the file name is kept.
    init(imported: Int, skipped: Int, failed: Int, failures: [(source: String, why: String)], nothingFound: Bool = false) {
        self.imported = imported
        self.skipped = skipped
        self.failed = failed
        self.failures = failures.map { "\(($0.source as NSString).lastPathComponent): \($0.why)" }
        self.nothingFound = nothingFound
    }

    init(_ report: NotabilityImporter.ImportReport) {
        self.init(imported: report.imported, skipped: report.skipped, failed: report.failed,
                  failures: report.notes.compactMap { note in
                      guard case .failed(let why) = note.status else { return nil }
                      return (note.source, why)
                  },
                  nothingFound: report.notes.isEmpty)
        details = NotabilityImportDetails(report)
    }

    var title: String {
        failed > 0 ? String(localized: "Import Finished with Errors", comment: "Alert title after a Notability import")
            : String(localized: "Notability Import", comment: "Alert title after a Notability import")
    }

    /// Whole sentences, one per line (never joined fragments: docs/localization.md).
    var message: String {
        if nothingFound {
            return String(localized: "No Notability notes (.note or .ntb files, or a zip of them) were found in what you picked.")
        }
        var lines = [String(localized: "\(imported) notes imported.", comment: "Notability import result: notes written")]
        if skipped > 0 {
            lines.append(String(localized: "\(skipped) notes skipped (already in the vault, or a copy of a note imported from another file).",
                                comment: "Notability import result"))
        }
        if details.recognitionAsked, details.recognizedPages > 0 {
            lines.append(String(localized: "Handwriting read on \(details.recognizedPages) pages.",
                                comment: "Notability import result: pages the app read after the import"))
        }
        if details.recognitionFailed > 0 {
            lines.append(String(localized: "Handwriting could not be read in \(details.recognitionFailed) notes.",
                                comment: "Notability import result: notes the app could not read after the import"))
        }
        if failed > 0 {
            lines.append(String(localized: "\(failed) notes failed:", comment: "Notability import result, followed by one line per note"))
            lines += failures.prefix(5)
            if failures.count > 5 {
                lines.append(String(localized: "…and \(failures.count - 5) more.", comment: "After the first failed notes of a Notability import"))
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// What the app's Notability import does: the CLI's options (`sempere import notability`),
/// with its defaults (docs/cli.md): attachments imported, image metadata stripped, PDF page
/// text stored, folder names as tags, no handwriting reading afterwards.
struct NotabilityImportOptions: Equatable, Sendable {
    /// `--no-attachments` is `false`: PDF pages, images, typed text and recordings.
    var attachments = true
    /// `--keep-image-metadata`: camera and location data stay in JPEG and PNG images.
    var keepImageMetadata = false
    /// `--pdf-text` (not `none`): text of PDF pages for search, from PDFKit.
    var pdfText = true
    /// `--no-folder-tags` is `false`: each Notability folder name becomes a tag.
    var folderTags = true
    /// `--recognize missing`: read the handwriting of pages Notability never indexed, afterwards.
    var recognizeMissing = false

    /// The importer's options for a run filing notes under `notebook` (nil: Notability's subject).
    func importer(notebook: String?) -> NotabilityImporter.Options {
        NotabilityImporter.Options(notebook: NotebookPath.canonical(notebook), app: NoteWriter.appName,
                                   tagsFromFolders: folderTags, attachments: attachments,
                                   keepImageMetadata: keepImageMetadata,
                                   pdfText: pdfText ? PDFKitTextExtractor() : nil)
    }
}

/// The report of a Notability import as the app shows it: totals of what was imported and of what
/// the importer left out (`NotabilityImporter.Dropped`), and its warnings, which name file names
/// and field names of the user's own backup, never note text.
struct NotabilityImportDetails: Equatable, Sendable {
    /// A counted line of the report.
    struct Row: Equatable, Sendable, Identifiable {
        var label: String
        var count: Int
        var id: String { label }
    }

    var imported: [Row] = []
    var notImported: [Row] = []
    /// `"<file name>: <warning>"`, at most `maxWarnings` of them, each cut to `maxWarningLength` characters.
    var warnings: [String] = []
    /// Warnings beyond `maxWarnings`.
    var moreWarnings = 0
    /// `--recognize missing` was asked for, and what it did.
    var recognitionAsked = false
    var recognizedPages = 0
    var recognitionFailed = 0

    static let maxWarnings = 300
    static let maxWarningLength = 400

    init() {}

    init(_ report: NotabilityImporter.ImportReport) {
        let written = report.notes.filter { $0.status == .ok }
        func total(_ value: (NotabilityImporter.NoteResult) -> Int) -> Int { written.reduce(0) { $0 + value($1) } }
        let counts: [(String, Int)] = [
            (String(localized: "PDF pages", comment: "Notability import report row"), total { $0.attachments.pdfPages }),
            (String(localized: "PDF pages with text for search", comment: "Notability import report row"),
             total { $0.attachments.pdfTextPages }),
            (String(localized: "Images", comment: "Notability import report row"), total { $0.attachments.images }),
            (String(localized: "Text boxes", comment: "Notability import report row"), total { $0.attachments.textItems }),
            (String(localized: "Recordings", comment: "Notability import report row"), total { $0.attachments.recordings }),
            (String(localized: "Transcripts", comment: "Notability import report row"), total { $0.attachments.transcripts }),
            (String(localized: "Strokes linked to a recording", comment: "Notability import report row"),
             total { $0.attachments.recLinkedStrokes }),
        ]
        imported = counts.filter { $0.1 > 0 }.map { Row(label: $0.0, count: $0.1) }
        var left: [NotabilityImporter.Dropped.Kind: Int] = [:]
        for n in written { for (kind, count) in n.dropped.nonZero { left[kind, default: 0] += count } }
        notImported = NotabilityImporter.Dropped.Kind.allCases.compactMap { kind in
            left[kind].map { Row(label: Self.label(kind), count: $0) }
        }
        var all: [String] = []
        for n in report.notes {
            let name = (n.source as NSString).lastPathComponent
            for w in n.warnings { all.append("\(name): \(w)") }
        }
        warnings = all.prefix(Self.maxWarnings).map { String($0.prefix(Self.maxWarningLength)) }
        moreWarnings = max(0, all.count - Self.maxWarnings)
    }

    /// Nothing to show beyond the summary lines.
    var isEmpty: Bool { imported.isEmpty && notImported.isEmpty && warnings.isEmpty && moreWarnings == 0 }

    /// The localized name of a kind of left-out content (the CLI prints `Kind.english`).
    static func label(_ kind: NotabilityImporter.Dropped.Kind) -> String {
        switch kind {
        case .typedTextCharacters: return String(localized: "Typed text (characters)", comment: "Notability import report: not imported")
        case .pdfs: return String(localized: "PDF files", comment: "Notability import report: not imported")
        case .pdfPages: return String(localized: "PDF pages (blank paper instead)", comment: "Notability import report: not imported")
        case .media: return String(localized: "Images and other media", comment: "Notability import report: not imported")
        case .pdfHighlights: return String(localized: "PDF highlights", comment: "Notability import report: not imported")
        case .templatePDFs: return String(localized: "Template PDF paper", comment: "Notability import report: not imported")
        case .recLinks: return String(localized: "Links from strokes to recordings", comment: "Notability import report: not imported")
        case .recordings: return String(localized: "Recordings", comment: "Notability import report: not imported")
        case .dashedStrokes: return String(localized: "Dashed strokes (imported solid)", comment: "Notability import report: not imported")
        case .unknownStyleStrokes:
            return String(localized: "Strokes of an unknown style (imported as pen)", comment: "Notability import report: not imported")
        case .defaultedAttributeStrokes:
            return String(localized: "Strokes with a missing style, colour or width", comment: "Notability import report: not imported")
        case .unsupportedShapes: return String(localized: "Shapes not converted", comment: "Notability import report: not imported")
        case .unsupportedStrokes: return String(localized: "Strokes of a kind not understood", comment: "Notability import report: not imported")
        case .clampedStrokes: return String(localized: "Strokes whose position was not stored", comment: "Notability import report: not imported")
        case .bundleRecordsWithoutFile: return String(localized: "Attachments with no file in the backup", comment: "Notability import report: not imported")
        case .bundleFilesUnreferenced: return String(localized: "Attachment files no note names", comment: "Notability import report: not imported")
        case .pdfTextPages: return String(localized: "PDF pages without text for search", comment: "Notability import report: not imported")
        }
    }
}

/// Notability notes and backups into the open vault: the importer the CLI
/// runs (`sempere import notability`, `NotabilityImporter.import`) with its
/// defaults (folder names become tags, attachments imported, image metadata
/// stripped, notes already in the vault skipped), PDF page text from PDFKit, and its options
/// (`NotabilityImportOptions`, asked in `NotabilityImportOptionsSheet`); the result is the
/// alert's summary and the full report (`NotabilityImportDetails`).
extension AppModel {
    /// What the importer reads: `.note` and `.ntb` files, folders of them and
    /// zips (Notability's backup; pick every part of a split one).
    static var notabilityTypes: [UTType] {
        var types: [UTType] = [.zip, .folder]
        for ext in ["note", "ntb"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    /// Imports `urls` (security-scoped, from the file picker) into the open
    /// vault, filing every note under `notebook` (nil: Notability's subject).
    ///
    /// Writes through the model's one `DeviceClock` (`withClock`) under the
    /// edit gate, like every other write; in iCloud Drive the writes are one
    /// coordinated write on `notes/`. Existing notes are never overwritten,
    /// so no open editor's note changes. The result is in `notabilitySummary`.
    func importNotability(_ urls: [URL], notebook: String?, options: NotabilityImportOptions = NotabilityImportOptions()) async throws {
        guard !urls.isEmpty else { return }
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        try requireWritableVault()   // format.md §7.3
        guard !isImportingNotability else { return }
        isImportingNotability = true
        defer { isImportingNotability = false }
        let gen = generation
        let report: NotabilityImporter.ImportReport
        do {
            await editGate.acquire()
            defer { editGate.release() }
            try ensureCurrent(gen)
            let clock = try deviceClockForWriting()
            let device = clock.device
            let notes = isCloudVault ? vault.url.appendingPathComponent("notes", isDirectory: true) : nil
            let importer = options.importer(notebook: notebook)
            let scoped = urls.map { $0.startAccessingSecurityScopedResource() }
            defer { for (url, s) in zip(urls, scoped) where s { url.stopAccessingSecurityScopedResource() } }
            report = try await clock.withClock(save: true) { c in
                try CloudVault.coordinatedWrite(notes) {
                    try NotabilityImporter.import(paths: urls, into: vault, device: device, clock: &c, options: importer)
                }
            }
            try ensureCurrent(gen)
        }
        let written = report.notes.filter { $0.status == .ok }.compactMap(\.noteId)
        if !written.isEmpty { try await refresh(written) }
        var summary = NotabilityImportSummary(report)
        if options.recognizeMissing {
            summary.details.recognitionAsked = true
            await recognizeImported(written, into: &summary, generation: gen)
        }
        try ensureCurrent(gen)
        notabilitySummary = summary
    }

    /// `--recognize missing`: reads the pages of the notes just written that Notability never indexed
    /// (`RecognitionPolicy.needsRecognition`), one delta per note, outside the import's edit gate
    /// (each note's write takes it). The device's recognizer, else Vision; a note that fails is counted.
    private func recognizeImported(_ ids: [UUID], into summary: inout NotabilityImportSummary, generation gen: Int) async {
        let reader: any PageRecognizing = recognizer ?? VisionPageRecognizer()
        for id in ids {
            guard gen == generation, !Task.isCancelled else { return }
            do {
                if let done = try await recognizeNote(id, with: reader) { summary.details.recognizedPages += done.pagesRecognized }
            } catch is CancellationError {
                return
            } catch {
                summary.details.recognitionFailed += 1
            }
        }
    }
}
