import Foundation
import Sempere

/// Which per-page images a Markdown export embeds besides the PDF.
public enum ExportImages: String, CaseIterable, Sendable {
    case none, png
}

/// The two folder-tree export formats.
public enum TreeFormat: String, CaseIterable, Sendable {
    case markdown, html
}

/// Why a tree export stopped (a note that fails to render is reported in
/// `TreeExporter.run`'s `errors`, not thrown).
public enum TreeExportError: Error, Equatable, CustomStringConvertible, Sendable {
    case cannotWrite(path: String, reason: String)

    public var description: String {
        switch self {
        case .cannotWrite(let path, let reason): return "cannot write \(path): \(reason)"
        }
    }
}

/// What a tree export (Markdown or HTML) wrote, per note.
public struct TreeResult: Sendable {
    public var noteId: String
    public var files: [String]
    public var changed: [String]
}

/// `.sempere-export-<format>.json` in the output root: which files an export
/// produced, so `--clean` removes only those and the folder indexes can list
/// notes from earlier runs.
struct ExportManifest: Codable {
    struct FileEntry: Codable {
        /// The note id, nil for an index file.
        var note: String?
        var notebook: String?
    }
    struct NoteEntry: Codable {
        var title: String
        /// File name without extension.
        var stem: String
        /// Sanitised folder components below the output root.
        var folder: [String]
        var notebook: String?
        var tags: [String]
        var pages: Int
        var modified: Date?
        /// Recognised text of the note (HTML index search only).
        var searchText: String?
    }
    var version = 1
    var files: [String: FileEntry] = [:]
    var notes: [String: NoteEntry] = [:]

    /// A path component that stays inside its folder: not empty, not `.` or `..`,
    /// no separator or control character.
    static func isSafeComponent(_ c: String) -> Bool {
        !c.isEmpty && c != "." && c != ".." && !c.unicodeScalars.contains { $0 == "/" || $0 == "\\" || $0.value < 0x20 }
    }

    /// The manifest is a file in a folder that may be shared, so it is not trusted: `--clean`
    /// deletes and the indexes write the paths it names. Entries that would leave the output
    /// folder (or are not what this exporter writes) are forgotten.
    mutating func dropUnsafeEntries() {
        files = files.filter { rel, _ in
            !rel.hasPrefix("/") && rel.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { Self.isSafeComponent(String($0)) }
        }
        notes = notes.filter { _, n in Self.isSafeComponent(n.stem) && n.folder.allSatisfy(Self.isSafeComponent) }
    }
}

/// Writes notes as a folder tree: Markdown (`.md` + PDF [+ PNG pages] + a
/// `README.md` per folder) or HTML (one file per note + `index.html`).
/// Re-running rewrites only files whose content changed.
///
/// `run` is synchronous and blocking: call it off the main actor. It checks
/// `Task.checkCancellation()` before each note, so cancelling the task that
/// runs it stops the export between notes (files already written stay).
public struct TreeExporter: Sendable {
    public var root: URL
    public var format: TreeFormat
    public var images: ExportImages
    /// Markdown only: write each note's PDF next to its `.md` and embed it
    /// (the CLI always does; the app's "Text (Markdown)" export makes it optional).
    public var pdf: Bool
    public var options: RenderOptions
    public var png: PNGOptions
    public var source: String
    public var clean: Bool
    public var notebookFilter: String?
    /// How a note's failure is worded in `run`'s `errors`.
    public var errorText: @Sendable (Error) -> String

    public init(root: URL, format: TreeFormat, images: ExportImages = .none, pdf: Bool = true,
                options: RenderOptions = RenderOptions(),
                png: PNGOptions = PNGOptions(), source: String, clean: Bool = false, notebookFilter: String? = nil,
                errorText: @escaping @Sendable (Error) -> String = { "\($0)" }) {
        self.root = root; self.format = format; self.images = images; self.pdf = pdf; self.options = options; self.png = png
        self.source = source; self.clean = clean; self.notebookFilter = notebookFilter; self.errorText = errorText
    }

    private var manifestURL: URL { root.appendingPathComponent(".sempere-export-\(format.rawValue).json") }

    /// The largest export manifest read back (one entry per note and file).
    static let maxManifestBytes = 256 << 20

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        // The output folder may be synced or shared (format.md §9): its manifest
        // is read like format JSON (RFC 3339 dates), never Foundation's ISO 8601 parser.
        return (e, InkJSON.decoder())
    }

    /// Folder components for each notebook: segments sanitised, and names
    /// that differ only by case share one spelling (the smallest), so a
    /// case-insensitive file system cannot merge two folders by accident.
    public static func folders(for notebooks: [String?]) -> [String?: [String]] {
        func sanitized(_ nb: String?) -> [String] {
            NotebookPath.components(nb).map { ExportName.folderComponent($0) }
        }
        var spelling: [String: String] = [:]
        for nb in Set(notebooks) {
            var key = ""
            for part in sanitized(nb) {
                key += "/" + part.lowercased()
                if let old = spelling[key] { spelling[key] = min(old, part) } else { spelling[key] = part }
            }
        }
        var out: [String?: [String]] = [:]
        for nb in Set(notebooks) {
            var key = "", parts: [String] = []
            for part in sanitized(nb) {
                key += "/" + part.lowercased()
                parts.append(spelling[key] ?? part)
            }
            out[nb] = parts
        }
        return out
    }

    private func inScope(_ notebook: String?) -> Bool {
        guard let f = notebookFilter else { return true }
        return NotebookPath.name(notebook, isWithin: f)
    }

    /// Exports `notes`; `protected` are note ids that failed earlier in this run and must survive `--clean`.
    /// `onNote(done, total)` is called before each note starts (with notes finished so far) and once at the end;
    /// `onFile(path, changed)` after each file.
    public func run(_ notes: [(NoteSummary, NoteState)], protected: Set<String>, vaultSource: String,
                    onNote: (Int, Int) -> Void = { _, _ in }, onFile: (String, Bool) -> Void = { _, _ in }) throws -> (results: [TreeResult], failures: Int, errors: [String]) {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let (enc, dec) = Self.coder()
        var manifest = (try? dec.decode(ExportManifest.self,
                                        from: BoundedRead.contents(of: manifestURL, maxBytes: Self.maxManifestBytes)))
            ?? ExportManifest()
        manifest.dropUnsafeEntries()
        let folderMap = Self.folders(for: notes.map { NotebookPath.canonical($0.1.meta.notebook) })
        var runFiles = Set<String>()
        var results: [TreeResult] = [], errors: [String] = []
        var failures = 0
        var failedIDs = protected

        /// Writes `data` unless the file already holds exactly that.
        func put(_ rel: String, _ data: Data) throws -> Bool {
            let url = root.appendingPathComponent(rel)
            if let old = try? BoundedRead.contents(of: url, maxBytes: data.count), old == data { return false }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try data.write(to: url, options: .atomic) } catch {
                throw TreeExportError.cannotWrite(path: url.path, reason: error.localizedDescription)
            }
            return true
        }

        for (n, (s, state)) in notes.enumerated() {
            try Task.checkCancellation()
            onNote(n, notes.count)
            let id = s.id.uuidString.lowercased()
            let folder = folderMap[NotebookPath.canonical(state.meta.notebook)] ?? []
            var stem = ExportName.stem(title: state.meta.title, noteId: s.id)
            if format == .markdown {
                // `[`, `]`, `#` and `^` break Obsidian's [[wikilinks]].
                stem = String(stem.map { "[]#^".contains($0) ? "-" : $0 })
            }
            let prefix = (folder + [stem]).joined(separator: "/")
            let info = ExportNoteInfo(id: s.id, title: state.meta.title, tags: state.meta.tags,
                                      notebook: state.meta.notebook, favorite: state.meta.favorite,
                                      created: state.meta.created, modified: s.modified, pages: state.pages.count,
                                      source: vaultSource)
            do {
                var outputs: [(String, Data)] = []
                var searchText: String?
                switch format {
                case .markdown:
                    if pdf { outputs.append((prefix + ".pdf", try PDFWriter.render(note: state, options: options))) }
                    var pageImages: [[String]] = []
                    if images == .png {
                        for (i, page) in state.pages.enumerated() {
                            let data = try PNGWriter.render(page: page, meta: state.meta, options: options, png: png)
                            var names: [String] = []
                            for (k, d) in data.enumerated() {
                                let name = String(format: "p%03d", i + 1) + (k == 0 ? "" : "-\(k + 1)") + ".png"
                                outputs.append((prefix + "-assets/" + name, d))
                                names.append(stem + "-assets/" + name)
                            }
                            pageImages.append(names)
                        }
                    }
                    let md = MarkdownExport.note(info: info, state: state, pdfName: pdf ? stem + ".pdf" : nil,
                                                    pageImages: pageImages)
                    outputs.append((prefix + ".md", Data(md.utf8)))
                case .html:
                    let svgs = try SVGWriter.render(note: state, options: options)
                    let back = String(repeating: "../", count: folder.count) + "index.html"
                    let html = HTMLExport.notePage(info: info, state: state, svgs: svgs, indexHref: back)
                    outputs.append((prefix + ".html", Data(html.utf8)))
                    searchText = state.pages.compactMap { $0.recognition?.text }.joined(separator: "\n")
                default:
                    break
                }
                var result = TreeResult(noteId: id, files: [], changed: [])
                let nb = NotebookPath.canonical(state.meta.notebook)
                for (rel, data) in outputs {
                    let changed = try put(rel, data)
                    result.files.append(root.appendingPathComponent(rel).path)
                    if changed { result.changed.append(root.appendingPathComponent(rel).path) }
                    runFiles.insert(rel)
                    manifest.files[rel] = .init(note: id, notebook: nb)
                    onFile(root.appendingPathComponent(rel).path, changed)
                }
                manifest.notes[id] = .init(title: state.meta.title, stem: stem, folder: folder, notebook: nb,
                                           tags: state.meta.tags, pages: state.pages.count, modified: s.modified,
                                           searchText: searchText)
                results.append(result)
            } catch let e as TreeExportError {
                throw e
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                failedIDs.insert(id)
                errors.append("\(id): \(errorText(error))")
            }
        }
        onNote(notes.count, notes.count)

        // --clean: forget notes in scope that this run did not export.
        let exported = Set(results.map(\.noteId))
        if clean {
            for (id, n) in manifest.notes where !exported.contains(id) && !failedIDs.contains(id) && inScope(n.notebook) {
                manifest.notes[id] = nil
            }
        }

        // Indexes, from every note the manifest knows.
        let known = manifest.notes.values.sorted { ($0.title.lowercased(), $0.stem) < ($1.title.lowercased(), $1.stem) }
        switch format {
        case .markdown:
            var folders = Set<[String]>([[]])
            for n in known { for k in 1...max(1, n.folder.count) where n.folder.count >= k { folders.insert(Array(n.folder.prefix(k))) } }
            for f in folders.sorted(by: { $0.joined(separator: "/") < $1.joined(separator: "/") }) {
                let entries = known.filter { $0.folder == f }.map {
                    ExportIndexEntry(title: $0.title, href: $0.stem + ".md", notebook: $0.notebook, tags: $0.tags,
                                     pages: $0.pages, modified: $0.modified)
                }
                let subs = Set(folders.filter { $0.count == f.count + 1 && Array($0.prefix(f.count)) == f }.map { $0.last ?? "" })
                    .sorted().map { (name: $0, href: $0 + "/README.md") }
                let md = MarkdownExport.folderIndex(title: f.last ?? "Sempere export", subfolders: subs, notes: entries)
                let rel = (f + ["README.md"]).joined(separator: "/")
                let changed = try put(rel, Data(md.utf8))
                runFiles.insert(rel)
                manifest.files[rel] = .init(note: nil, notebook: nil)
                onFile(root.appendingPathComponent(rel).path, changed)
            }
        case .html:
            let entries = known.map {
                ExportIndexEntry(title: $0.title, href: ($0.folder + [$0.stem + ".html"]).joined(separator: "/"),
                                 notebook: $0.notebook, tags: $0.tags, pages: $0.pages, modified: $0.modified,
                                 searchText: $0.searchText ?? "")
            }
            let changed = try put("index.html", Data(HTMLExport.indexPage(entries: entries).utf8))
            runFiles.insert("index.html")
            manifest.files["index.html"] = .init(note: nil, notebook: nil)
            onFile(root.appendingPathComponent("index.html").path, changed)
        default:
            break
        }

        // --clean: delete files of ours that this run did not produce.
        if clean {
            let rootPath = root.standardizedFileURL.path
            for (rel, entry) in manifest.files where !runFiles.contains(rel) {
                if let n = entry.note, failedIDs.contains(n) { continue }
                if entry.note != nil && !inScope(entry.notebook) { continue }
                manifest.files[rel] = nil
                let parts = rel.split(separator: "/", omittingEmptySubsequences: false)
                guard !rel.hasPrefix("/"), !parts.contains(".."), !parts.contains("") else { continue }
                var url = root.appendingPathComponent(rel).standardizedFileURL
                guard url.path.hasPrefix(rootPath + "/") else { continue }
                if (try? fm.removeItem(at: url)) != nil { onFile(url.path, true) }
                // Remove folders this left empty.
                url.deleteLastPathComponent()
                while url.path.hasPrefix(rootPath + "/"),
                      (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true {
                    try? fm.removeItem(at: url)
                    url.deleteLastPathComponent()
                }
            }
        }

        try enc.encode(manifest).write(to: manifestURL, options: .atomic)
        return (results, failures, errors)
    }
}
