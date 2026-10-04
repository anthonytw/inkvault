import Foundation
import InkVault

/// Maps Notability notes to InkVault notes and writes them into a vault
/// (`docs/import-notability.md`).
public enum NotabilityImporter {
    /// Options for `import`.
    public struct Options: Sendable {
        /// Re-import notes whose derived id already exists in the vault. The
        /// old pages are removed and the note's content written again with
        /// fresh page and stroke ids (removed ids are never reused, format.md §5.2).
        public var overwrite: Bool
        /// Notebook for every imported note instead of the path-derived one.
        public var notebook: String?
        /// `app` field of written revisions.
        public var app: String
        /// Scale every length (coordinates, widths, paper pitch, recognition
        /// boxes, break height) by `612 / width`, so the page is US-letter
        /// width in points and exports paginate as letter-width pages.
        /// Off keeps Notability's document units (716.8 wide for iPad notes).
        public var scaleToLetterWidth: Bool

        public init(overwrite: Bool = false, notebook: String? = nil, app: String = "inkvault-import/0.1",
                    scaleToLetterWidth: Bool = true) {
            self.overwrite = overwrite; self.notebook = notebook; self.app = app
            self.scaleToLetterWidth = scaleToLetterWidth
        }
    }

    /// Content of a Notability note that the import leaves behind.
    public struct Dropped: Hashable, Sendable {
        /// Characters of typed text.
        public var typedTextCharacters = 0
        /// Imported PDFs the ink was written on.
        public var pdfs = 0
        /// Pages of the note that were PDF pages (the PDF is not imported, so
        /// they become blank paper; a note without ink is then empty).
        public var pdfPages = 0
        /// Images and other media objects.
        public var media = 0
        /// Audio recordings.
        public var recordings = 0
        /// Strokes imported solid although Notability draws them dashed.
        public var dashedStrokes = 0
        /// Strokes of a `curvesstyles` value other than pen or highlighter (imported as pen).
        public var unknownStyleStrokes = 0

        public init() {}

        /// True when nothing was left behind.
        public var isEmpty: Bool { self == Dropped() }
    }

    /// Outcome for one source note.
    public enum Status: Hashable, Sendable {
        case ok
        /// Not written; the reason says why (already in the vault, duplicate in this run).
        case skipped(String)
        /// Could not be parsed or written.
        case failed(String)
    }

    /// One row of an `ImportReport`.
    public struct NoteResult: Hashable, Sendable {
        /// Where the note came from: a file path, or `<zip>!<entry>`.
        public var source: String
        /// Derived note id (nil when the note could not be parsed).
        public var noteId: UUID?
        /// Note title.
        public var title: String?
        /// Notebook it went to.
        public var notebook: String?
        public var status: Status
        /// Strokes written.
        public var strokes = 0
        /// Notability pages with recognised text.
        public var recognizedPages = 0
        /// Notability's document width before any scaling (document units).
        public var originalWidth: Double?
        /// What was not imported.
        public var dropped = Dropped()
        /// Wall time spent on this note, seconds.
        public var seconds = 0.0

        public init(source: String, status: Status) { self.source = source; self.status = status }
    }

    /// Result of `import`.
    public struct ImportReport: Hashable, Sendable {
        /// One entry per source note, in input order.
        public var notes: [NoteResult] = []

        public init() {}

        /// Notes written.
        public var imported: Int { notes.filter { $0.status == .ok }.count }
        /// Notes skipped.
        public var skipped: Int { notes.filter { if case .skipped = $0.status { return true }; return false }.count }
        /// Notes that failed.
        public var failed: Int { notes.filter { if case .failed = $0.status { return true }; return false }.count }
        /// Strokes written across all notes.
        public var strokes: Int { notes.reduce(0) { $0 + $1.strokes } }
    }

    // MARK: - Mapping

    /// US letter width in points, the target of `scaleToLetterWidth`.
    public static let letterWidth = 612.0

    /// The vault note id for a Notability note: a name-based UUID
    /// (`UUID.derived(from:)`) of `"inkvault-notability:" + uuidKey`, so a
    /// re-import of the same note finds it. Notes without a `uuidKey` (not
    /// seen in practice) use their name and creation time instead.
    public static func noteId(for note: NotabilityNote) -> UUID {
        UUID.derived(from: "inkvault-notability:" + sourceKey(note))
    }

    static func sourceKey(_ note: NotabilityNote) -> String {
        if let u = note.metadata.uuid, !u.isEmpty { return u }
        return "name:\(note.metadata.name)|created:\(note.metadata.created?.timeIntervalSinceReferenceDate ?? 0)"
    }

    /// Maps a parsed note to an InkVault note state: one infinite page, one
    /// stroke per curve, Notability's recognised text merged into the page's
    /// `recognition`. Ids are derived from the Notability uuid (and
    /// `idSalt`, set by an overwrite), so the mapping is deterministic.
    ///
    /// The page is infinite with `breakHeight` set to one Notability page
    /// (`width × 21/16` for letter), so exports paginate like Notability.
    ///
    /// - Parameters:
    ///   - notebook: the notebook to file the note under (else the Notability subject).
    ///   - idSalt: nil for a first import; distinct values mint fresh page and
    ///     stroke ids (an overwrite uses `"<device>-<seq>"` of its delta).
    ///   - scaleToLetterWidth: scale every length by `612 / width` (see `Options`).
    public static func convert(_ note: NotabilityNote, notebook: String? = nil, idSalt: String? = nil,
                               scaleToLetterWidth: Bool = true) -> NoteState {
        let k = scaleToLetterWidth ? letterWidth / note.paper.width : 1
        let key = "inkvault-notability:" + sourceKey(note) + (idSalt.map { ":gen:" + $0 } ?? "")
        let pageId = UUID.derived(from: key + ":page")

        // Highlighter first so it sits behind the ink, as Notability draws it.
        let order = note.curves.indices.sorted { a, b in
            let ha = note.curves[a].isHighlighter, hb = note.curves[b].isHighlighter
            return ha != hb ? ha : a < b
        }
        var strokes: [Stroke] = []
        strokes.reserveCapacity(note.curves.count)
        var maxY = 0.0
        for i in order {
            let c = note.curves[i]
            let dx = note.paper.insetX
            let pts = BezierToBSpline.strokePoints(of: c).map { p -> StrokePoint in
                var p = p
                p.x = (p.x + dx) * k; p.y *= k; p.w *= k; p.h *= k
                return p
            }
            guard !pts.isEmpty else { continue }
            let highlighter = c.isHighlighter
            // Marker colours are opaque pigment; the marker tool supplies the
            // translucency (as PencilKit's does).
            var color = c.color
            if highlighter { color.a = 255 }
            strokes.append(Stroke(id: UUID.derived(from: key + ":stroke:\(i)"),
                                  ink: Ink(tool: highlighter ? .marker : .pen, color: color, width: c.width * k),
                                  points: pts))
            for p in pts where p.y.isFinite { maxY = max(maxY, p.y + max(p.w, c.width * k) / 2) }
        }

        let paper = note.paper
        let meta = NoteMeta(title: note.metadata.name, tags: note.metadata.tags,
                            notebook: notebook ?? note.metadata.subject,
                            created: note.metadata.created ?? Date(timeIntervalSince1970: 0),
                            paper: Paper(kind: paper.kind, spacing: (paper.spacing ?? 24 / k) * k),
                            pageSize: PageSize(width: paper.width * k,
                                               height: max(paper.pageHeight * k, maxY.rounded(.up)), infinite: true,
                                               breakHeight: paper.pageHeight * k))
        let page = Page(id: pageId, order: PageOrder.between(nil, nil), strokes: strokes,
                        recognition: recognition(note, scale: k))
        return NoteState(meta: meta, pages: [page])
    }

    /// Notability's per-page recognition merged into one `Recognition` for
    /// the single infinite page: texts joined by newlines in page order,
    /// words built by grouping character boxes between whitespace, boxes moved
    /// by `pageContentOrigin` and the page's offset (`(n - 1) × pageHeight`).
    /// Every box is then multiplied by `scale`.
    public static func recognition(_ note: NotabilityNote, scale: Double = 1) -> Recognition? {
        guard !note.recognition.isEmpty else { return nil }
        var texts: [String] = []
        var words: [Recognition.Word] = []
        for number in note.recognition.keys.sorted() {
            guard let page = note.recognition[number] else { continue }
            texts.append(page.text)
            let dx = page.origin.x + note.paper.insetX, dy = page.origin.y + Double(number - 1) * note.paper.pageHeight
            var current = "", box: Recognition.Box?
            func flush() {
                if !current.isEmpty, let b = box {
                    words.append(Recognition.Word(text: current, box: Recognition.Box(
                        x: (b.x + dx) * scale, y: (b.y + dy) * scale, w: b.w * scale, h: b.h * scale)))
                }
                current = ""; box = nil
            }
            var unit = 0
            for ch in page.text {
                let units = ch.utf16.count
                defer { unit += units }
                if ch.isWhitespace { flush(); continue }
                current.append(ch)
                for u in unit..<(unit + units) where u < page.characterBoxes.count {
                    guard let b = page.characterBoxes[u] else { continue }
                    box = box.map { union($0, b) } ?? b
                }
            }
            flush()
        }
        let engine = "notability" + (note.bundleVersion.map { "-" + $0 } ?? "")
        return Recognition(engine: engine, text: texts.joined(separator: "\n"), words: words)
    }

    private static func union(_ a: Recognition.Box, _ b: Recognition.Box) -> Recognition.Box {
        let x0 = min(a.x, b.x), y0 = min(a.y, b.y)
        let x1 = max(a.x + a.w, b.x + b.w), y1 = max(a.y + a.h, b.y + b.h)
        return Recognition.Box(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    /// What `convert` leaves out of `note`.
    public static func dropped(_ note: NotabilityNote) -> Dropped {
        var d = Dropped()
        d.typedTextCharacters = note.typedText.trimmingCharacters(in: .whitespacesAndNewlines).count
        d.pdfs = note.pdfCount
        d.pdfPages = note.pdfPageCount
        d.media = note.mediaCount
        d.recordings = note.recordingCount
        d.dashedStrokes = note.curves.filter(\.dashed).count
        d.unknownStyleStrokes = note.curves.filter {
            $0.style != NotabilityNote.penStyle && $0.style != NotabilityNote.highlighterStyle
        }.count
        return d
    }

    /// The ops of one import delta for `state` (as `convert` builds it):
    /// `addPage`, one `addStroke` per stroke, `setMeta` for title, tags,
    /// notebook (even when empty), paper and page size, and `setPageRecognition`.
    public static func ops(for state: NoteState) -> [Op] {
        var ops: [Op] = []
        for page in state.pages {
            ops.append(.addPage(Page(id: page.id, order: page.order)))
            for s in page.strokes { ops.append(.addStroke(page: page.id, stroke: s)) }
        }
        let m = state.meta
        ops.append(.setMeta(.title(m.title)))
        // Always set, so an overwrite can clear them.
        ops.append(.setMeta(.tags(m.tags)))
        ops.append(.setMeta(.notebook(m.notebook)))
        ops.append(.setMeta(.paper(m.paper)))
        ops.append(.setMeta(.pageSize(m.pageSize)))
        for page in state.pages where page.recognition != nil {
            ops.append(.setPageRecognition(pageId: page.id, recognition: page.recognition))
        }
        return ops
    }

    // MARK: - Import

    /// One `.note` found in the inputs.
    struct Source {
        var label: String
        var notebook: String?
        var load: () throws -> NotePackage
    }

    /// Imports Notability notes into `vault`, one delta per note.
    ///
    /// Each path may be a `.note` file, a directory (searched recursively for
    /// `.note` files), or a zip holding `.note` files (Notability's Google
    /// Drive backup). The notebook is the directory under `Notability/` in the
    /// path (e.g. `Research/Daily log`), else the directory relative to an
    /// input directory, else the note's Notability subject; `options.notebook`
    /// overrides all of them.
    ///
    /// A note whose derived id already exists is skipped unless
    /// `options.overwrite`. Per-note problems are reported, not thrown. The
    /// delta's `wall` is the note's Notability creation date, so the note's
    /// `created` (format.md §5.4) is preserved; its `hlc` comes from `clock`.
    ///
    /// - Throws: `ImportError.io` / `.zip` when an input cannot be listed or
    ///   opened; `VaultError` when the vault cannot be listed.
    public static func `import`(paths: [URL], into vault: Vault, device: DeviceID, clock: inout HybridClock,
                                options: Options = Options(), now: () -> Date = Date.init) throws -> ImportReport {
        var report = ImportReport()
        var existing = Set(try vault.noteIDs())
        var seen = Set<UUID>()
        for url in paths {
            for source in try sources(url) {
                let started = Date()
                // Drain Foundation's autoreleased plist objects per note on Darwin.
                var result = withPool {
                    importOne(source, into: vault, device: device, clock: &clock, options: options, now: now,
                              existing: &existing, seen: &seen)
                }
                result.seconds = Date().timeIntervalSince(started)
                report.notes.append(result)
            }
        }
        return report
    }

    static func withPool<T>(_ body: () -> T) -> T {
        #if canImport(Darwin)
        return autoreleasepool(invoking: body)
        #else
        return body()
        #endif
    }

    static func importOne(_ source: Source, into vault: Vault, device: DeviceID, clock: inout HybridClock,
                          options: Options, now: () -> Date, existing: inout Set<UUID>,
                          seen: inout Set<UUID>) -> NoteResult {
        var result = NoteResult(source: source.label, status: .ok)
        let note: NotabilityNote
        do { note = try NotabilityNote.parse(package: source.load()) } catch {
            result.status = .failed(describe(error)); return result
        }
        let id = noteId(for: note)
        result.noteId = id
        result.title = note.metadata.name
        let notebook = options.notebook ?? source.notebook ?? note.metadata.subject
        result.notebook = notebook
        result.dropped = dropped(note)
        result.originalWidth = note.paper.width
        guard seen.insert(id).inserted else {
            result.status = .skipped("duplicate of an earlier note in this import (same Notability uuid)")
            return result
        }
        let exists = existing.contains(id)
        if exists && !options.overwrite {
            result.status = .skipped("already in the vault"); return result
        }
        do {
            var ops: [Op] = []
            var seq = 1
            var salt: String?
            if exists {
                let old = try vault.reconstruct(noteId: id)
                seq = try vault.nextSeq(noteId: id, device: device)
                // Unique per (device, seq), so no two overwrites, from any
                // device, mint the same (possibly tombstoned) ids.
                salt = "\(device)-\(seq)"
                ops += old.pages.map { .removePage(pageId: $0.id) }
                if old.deleted { ops.append(.restoreNote) }
            }
            let state = convert(note, notebook: notebook, idSalt: salt,
                                scaleToLetterWidth: options.scaleToLetterWidth)
            ops += Self.ops(for: state)
            let wall = note.metadata.created ?? now()
            let hlc = clock.tick(wall: now())
            try vault.write(Revision(noteId: id, device: device, seq: seq, hlc: hlc, wall: wall,
                                     app: options.app, body: .delta(ops: ops)))
            existing.insert(id)
            result.strokes = state.pages.reduce(0) { $0 + $1.strokes.count }
            result.recognizedPages = note.recognition.count
        } catch {
            result.status = .failed(describe(error))
        }
        return result
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case ImportError.zip(let s): return "zip: \(s)"
        case ImportError.archive(let s): return "plist: \(s)"
        case ImportError.notability(let s): return "note: \(s)"
        case ImportError.io(let s): return "io: \(s)"
        default: return "\(error)"
        }
    }

    /// Expands one input path into `.note` sources. A `.note` may be a zip
    /// file or an unzipped package directory; a directory is searched
    /// recursively (without descending into packages); anything else is
    /// opened as a zip of `.note` files.
    static func sources(_ url: URL) throws -> [Source] {
        func isDirectory(_ u: URL) -> Bool {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue
        }
        func source(_ f: URL, notebook: String?) -> Source {
            let dir = isDirectory(f)
            return Source(label: f.path, notebook: notebook,
                          load: { dir ? try NotePackage(directory: f) : try NotePackage(data: readFile(f)) })
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw ImportError.io("no such file: \(url.path)") }
        if url.pathExtension.lowercased() == "note" {
            let comps = Array(url.standardizedFileURL.pathComponents.dropLast())
            return [source(url, notebook: notebook(fromDirectories: comps))]
        }
        if isDirectory(url) {
            guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
                throw ImportError.io("cannot list \(url.path)")
            }
            var found: [URL] = []
            for case let f as URL in walker where f.pathExtension.lowercased() == "note" {
                found.append(f)
                if isDirectory(f) { walker.skipDescendants() }
            }
            let base = url.standardizedFileURL.pathComponents
            return found.sorted { $0.path < $1.path }.map { f in
                let comps = Array(f.standardizedFileURL.pathComponents.dropLast())
                let rel = comps.count > base.count ? Array(comps[base.count...]) : []
                return source(f, notebook: notebook(fromDirectories: comps) ?? join(rel))
            }
        }
        // A zip of .note files (Notability's backup). The sources keep it open.
        let zip = try ZipArchive(url: url)
        return zip.entries.filter { !$0.isDirectory && $0.path.lowercased().hasSuffix(".note") }
            .sorted { $0.path < $1.path }
            .map { e in
                let comps = e.path.split(separator: "/").map(String.init).dropLast()
                return Source(label: "\(url.path)!\(e.path)", notebook: notebook(fromDirectories: Array(comps)),
                              load: { try NotePackage(data: zip.read(e)) })
            }
    }

    /// The directories after the last `Notability` component, joined by `/`.
    static func notebook(fromDirectories comps: [String]) -> String? {
        guard let i = comps.lastIndex(of: "Notability") else { return nil }
        return join(Array(comps[(i + 1)...]))
    }

    private static func join(_ comps: [String]) -> String? {
        comps.isEmpty ? nil : comps.joined(separator: "/")
    }

    private static func readFile(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url) } catch {
            throw ImportError.io("cannot read \(url.path): \(error.localizedDescription)")
        }
    }
}
