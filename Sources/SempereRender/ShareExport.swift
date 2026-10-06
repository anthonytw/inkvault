import Foundation
import Sempere

/// The formats the app's share/export action offers.
public enum ShareFormat: String, CaseIterable, Sendable, Identifiable {
    case pdf, png, markdown, html

    public var id: String { rawValue }

    /// The format's name for menus.
    public var title: String {
        switch self {
        case .pdf: return "PDF"
        case .png: return "PNG Pages"
        case .markdown: return "Markdown (Obsidian)"
        case .html: return "HTML"
        }
    }
}

/// What to export and how (`ShareExport.run`).
public struct ShareOptions: Sendable, Equatable {
    public var format: ShareFormat
    /// Draw the paper background and ruling (the CLI's inverse of `--no-paper`).
    public var paper: Bool
    /// PNG resolution in dots per inch (a page point is 1/72 inch); also the Markdown page images'.
    public var dpi: Double
    /// PDF only: one file with every note instead of one per note.
    public var mergePDF: Bool
    /// Markdown only: a PNG per page next to the note's PDF.
    public var markdownImages: ExportImages

    public init(format: ShareFormat, paper: Bool = true, dpi: Double = 144, mergePDF: Bool = false,
                markdownImages: ExportImages = .none) {
        self.format = format; self.paper = paper; self.dpi = dpi; self.mergePDF = mergePDF
        self.markdownImages = markdownImages
    }

    /// The largest `dpi` the exporters take (as the CLI's `--dpi`).
    public static let maxDPI = 2400.0

    /// True when `dpi` is a usable resolution.
    public var isValid: Bool { dpi.isFinite && dpi > 0 && dpi <= Self.maxDPI }
}

/// Why an export was refused before it started.
public enum ShareExportError: Error, Equatable, CustomStringConvertible, Sendable {
    /// A PNG resolution outside 0 ... `ShareOptions.maxDPI`.
    case invalidResolution(Double)

    public var description: String {
        switch self {
        case .invalidResolution: return "The resolution must be greater than 0 and at most \(Int(ShareOptions.maxDPI)) dpi."
        }
    }
}

/// What an export produced.
public struct ShareResult: Sendable {
    /// What to hand to the share sheet or Save to Files: files and/or folders under the scratch directory.
    public var items: [URL]
    /// Notes that could not be rendered, as `<id>: <reason>`; the rest were exported.
    public var failures: [String]
    /// Number of notes in `items`.
    public var exported: Int
    /// Items drawn as placeholders (`RenderReport`), over every note.
    public var placeholders = 0
}

/// Renders notes into a scratch directory for sharing. One engine for the app's
/// share sheet (the CLI's `export` writes the same files by the same renderers):
///
/// | format | one note | several notes |
/// | --- | --- | --- |
/// | PDF | `<stem>.pdf` | `<stem>.pdf` each, or one merged `Sempere-Notes.pdf` |
/// | PNG | `<stem>-p001.png`, ... | a folder `<stem>/` per note with `p001.png`, ... |
/// | Markdown | folder `<stem>/` with the `.md`, the PDF (+ page PNGs) and a `README.md` | folder `Sempere Export/` mirroring the notebooks |
/// | HTML | one self-contained `<stem>.html` | folder `Sempere Export/` with one file per note and `index.html` |
///
/// Everything is blocking: call `run` off the main actor. It checks
/// `Task.checkCancellation()` between notes (and pages).
/// The output is PLAINTEXT, as everything an export writes.
public enum ShareExport {
    /// The folder a multi-note Markdown or HTML export is written to.
    public static let treeFolderName = "Sempere Export"
    /// The merged PDF's name.
    public static let mergedPDFName = "Sempere-Notes.pdf"

    /// Renders `notes` into `scratch` (created if missing).
    ///
    /// - Parameters:
    ///   - vaultSource: the `source` recorded in Markdown front matter and HTML, e.g. `sempere:<vault id>`.
    ///   - errorText: how a failed note's error is worded in `failures`.
    ///   - progress: `(done, total)` before each note and once at the end.
    /// - Throws: `ShareExportError`, `CancellationError`, `TreeExportError` or a file error when `scratch` cannot be written.
    ///   - blobs: each note's attachments (`Vault.blobSource(note:)`); without
    ///     it attachments are placeholders. PDF and PNG only; Markdown and HTML
    ///     do not read attachments yet.
    ///   - pdfRasterizer: draws PDF page backgrounds for PNG (the app's PDFKit one).
    public static func run(_ notes: [(NoteSummary, NoteState)], options: ShareOptions, into scratch: URL,
                           vaultSource: String, blobs: (@Sendable (UUID) -> (any BlobSource)?)? = nil,
                           pdfRasterizer: (any PDFPageRasterizer)? = nil,
                           progress: (Int, Int) -> Void = { _, _ in },
                           errorText: @escaping @Sendable (Error) -> String = { "\($0)" }) throws -> ShareResult {
        let needsDPI = options.format == .png || (options.format == .markdown && options.markdownImages == .png)
        if needsDPI && !options.isValid { throw ShareExportError.invalidResolution(options.dpi) }
        let fm = FileManager.default
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let render = RenderOptions(paper: options.paper, pdfRasterizer: pdfRasterizer)
        func renderOptions(for id: UUID) -> RenderOptions {
            var r = render
            r.blobs = blobs?(id)
            return r
        }
        var report = RenderReport()
        var items: [URL] = []
        var failures: [String] = []
        var exported = 0
        func write(_ data: Data, _ url: URL) throws {
            // A cancelled run (the sheet went away) writes no more plaintext.
            try Task.checkCancellation()
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try data.write(to: url, options: .atomic) } catch {
                throw TreeExportError.cannotWrite(path: url.path, reason: error.localizedDescription)
            }
        }
        func name(_ s: NoteSummary, _ state: NoteState) -> String { ExportName.stem(title: state.meta.title, noteId: s.id) }

        switch options.format {
        case .markdown, .html:
            if options.format == .html && notes.count == 1, let (s, state) = notes.first {
                progress(0, 1)
                try Task.checkCancellation()
                do {
                    let info = Self.info(s, state, source: vaultSource)
                    let svgs = try SVGWriter.render(note: state, options: render)
                    let html = HTMLExport.notePage(info: info, state: state, svgs: svgs, indexHref: nil)
                    let url = scratch.appendingPathComponent(name(s, state) + ".html")
                    try write(Data(html.utf8), url)
                    items = [url]
                    exported = 1
                } catch let e as TreeExportError { throw e } catch is CancellationError { throw CancellationError() } catch {
                    failures.append("\(s.id.uuidString.lowercased()): \(errorText(error))")
                }
                progress(1, 1)
                break
            }
            let format: TreeFormat = options.format == .markdown ? .markdown : .html
            let root = scratch.appendingPathComponent(
                options.format == .markdown && notes.count == 1 ? name(notes[0].0, notes[0].1) : treeFolderName,
                isDirectory: true)
            let tree = TreeExporter(root: root, format: format, images: options.markdownImages, options: render,
                                    png: PNGOptions(dpi: options.dpi), source: "sempere", errorText: errorText)
            let r = try tree.run(notes, protected: [], vaultSource: vaultSource, onNote: progress)
            // A one-off share keeps no manifest: it only serves `--clean` and re-runs into the same folder.
            try? fm.removeItem(at: root.appendingPathComponent(".sempere-export-\(format.rawValue).json"))
            failures = r.errors
            exported = r.results.count
            if exported > 0 { items = [root] }
        case .pdf where options.mergePDF && notes.count > 1:
            // A note that cannot be rendered is left out and reported, as in
            // the other formats, instead of failing the whole document.
            var good: [NoteState] = []
            var goodBlobs: [(any BlobSource)?] = []
            for (n, (s, state)) in notes.enumerated() {
                try Task.checkCancellation()
                progress(n, notes.count)
                do {
                    for page in state.pages { _ = try PreparedPage(page: page, meta: state.meta, options: render) }
                    good.append(state)
                    goodBlobs.append(blobs?(s.id))
                } catch is CancellationError { throw CancellationError() } catch {
                    failures.append("\(s.id.uuidString.lowercased()): \(errorText(error))")
                }
            }
            try Task.checkCancellation()
            if !good.isEmpty {
                let url = scratch.appendingPathComponent(mergedPDFName)
                try write(try PDFWriter.render(notes: good, blobs: goodBlobs, options: render, report: &report), url)
                items = [url]
                exported = good.count
            }
            progress(notes.count, notes.count)
        case .pdf, .png:
            for (n, (s, state)) in notes.enumerated() {
                try Task.checkCancellation()
                progress(n, notes.count)
                let stem = name(s, state)
                do {
                    var files: [(URL, Data)] = []
                    if options.format == .pdf {
                        files = [(scratch.appendingPathComponent(stem + ".pdf"),
                                  try PDFWriter.render(note: state, options: renderOptions(for: s.id), report: &report))]
                    } else {
                        let pages = try PNGWriter.render(note: state, options: renderOptions(for: s.id), png: PNGOptions(dpi: options.dpi),
                                                         report: &report)
                        for (i, data) in pages.enumerated() {
                            let rel = notes.count > 1 ? stem + String(format: "/p%03d.png", i + 1)
                                                      : stem + String(format: "-p%03d.png", i + 1)
                            files.append((scratch.appendingPathComponent(rel), data))
                        }
                    }
                    for (url, data) in files { try write(data, url) }
                    if options.format == .png && notes.count > 1 {
                        items.append(scratch.appendingPathComponent(stem, isDirectory: true))
                    } else {
                        items += files.map(\.0)
                    }
                    exported += 1
                } catch let e as TreeExportError { throw e } catch is CancellationError { throw CancellationError() } catch {
                    failures.append("\(s.id.uuidString.lowercased()): \(errorText(error))")
                }
            }
            progress(notes.count, notes.count)
        }
        return ShareResult(items: items, failures: failures, exported: exported, placeholders: report.placeholders.count)
    }

    static func info(_ s: NoteSummary, _ state: NoteState, source: String) -> ExportNoteInfo {
        ExportNoteInfo(id: s.id, title: state.meta.title, tags: state.meta.tags, notebook: state.meta.notebook,
                       favorite: state.meta.favorite, created: state.meta.created, modified: s.modified,
                       pages: state.pages.count, source: source)
    }
}
