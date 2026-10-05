import Age
import Foundation
import InkRender
import InkVault
import XCTest
@testable import InkImport

/// Stage 1 of the import fidelity evaluation (`docs/import-notability.md`,
/// "Fidelity evaluation"; driven by `scripts/import-eval.sh`). Skipped unless
/// both `INKVAULT_NOTABILITY_SAMPLES` (a backup zip or directory of `.note`
/// files) and `INKVAULT_EVAL_DIR` (a scratch directory, emptied first) are
/// set; CI never has personal data.
///
/// Imports every note into a fresh scratch vault `<dir>/vault.inkvault`
/// (identity `<dir>/identity.key`), then for every imported note writes
/// `<dir>/oracle/<id8>/`, where `id8` is the first 8 hex digits of the vault
/// note id (itself a hash of Notability's uuid, so nothing names the note):
///
/// - `thumb*.png`: Notability's thumbnails, unchanged;
/// - `ours-<thumb>.png`: the first Notability page of the note as stored in
///   the vault, rendered by `PNGWriter` without paper (transparent) at the
///   thumbnail's width (page width 612 pt → thumbnail width), cropped to one
///   `breakHeight`;
/// - `page1.pdf` (+ `pdfPage` in the JSON): the PDF the first page sits on;
/// - `meta.json`: counts and geometry, no titles or text.
///
/// `<dir>/import.json` holds the aggregate import report.
final class ImportFidelityEvalTests: XCTestCase {
    func testExportEvaluationInputs() throws {
        let env = ProcessInfo.processInfo.environment
        guard let samples = env["INKVAULT_NOTABILITY_SAMPLES"].map({ URL(fileURLWithPath: $0) }),
              let dir = env["INKVAULT_EVAL_DIR"].map({ URL(fileURLWithPath: $0) }) else {
            throw XCTSkip("INKVAULT_NOTABILITY_SAMPLES and INKVAULT_EVAL_DIR not set")
        }
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir.appendingPathComponent("oracle"), withIntermediateDirectories: true)

        let identity = try NativeIdentity.generate(.postQuantum)
        try (identity.string + "\n").write(to: dir.appendingPathComponent("identity.key"), atomically: true,
                                           encoding: .utf8)
        let vault = try Vault.create(at: dir.appendingPathComponent("vault.inkvault"),
                                     recipients: [identity.recipient], identities: [identity])
        var clock = HybridClock()
        let report = try NotabilityImporter.import(paths: [samples], into: vault, device: DeviceID("e0a1e0a1")!,
                                                   clock: &clock)
        let sources = Dictionary(try NotabilityImporter.sources(samples).map { ($0.label, $0) },
                                 uniquingKeysWith: { a, _ in a })
        let summary: [String: Any] = [
            "notes": report.notes.count, "imported": report.imported, "skipped": report.skipped,
            "failed": report.failed, "strokes": report.strokes,
        ]
        try json(summary).write(to: dir.appendingPathComponent("import.json"))

        var written = 0
        for result in report.notes where result.status == .ok {
            guard let id = result.noteId, let source = sources[result.source] else {
                XCTFail("imported note without id or source"); continue
            }
            let error: Error? = NotabilityImporter.withPool {
                do {
                let id8 = String(id.uuidString.lowercased().prefix(8))
                let out = dir.appendingPathComponent("oracle").appendingPathComponent(id8)
                try fm.createDirectory(at: out, withIntermediateDirectories: true)
                let pkg = try source.load()
                let note = try NotabilityNote.parse(package: pkg)
                let state = try vault.reconstruct(noteId: id)
                try export(note: note, package: pkg, state: state, id: id, to: out)
                return nil
                } catch { return error }
            }
            if let error { throw error }
            written += 1
        }
        XCTAssertEqual(written, report.imported)
        print("EVAL: exported \(written) notes to \(dir.path)")
    }

    /// Writes one note's thumbnails, first-page renders, PDF and metadata.
    func export(note: NotabilityNote, package pkg: NotePackage, state: NoteState, id: UUID, to out: URL) throws {
        let size = state.meta.pageSize
        let breakHeight = size.breakHeight ?? size.width * 21 / 16
        let strokes = state.pages.flatMap(\.strokes)

        var thumbs: [[String: Any]] = []
        let names = pkg.paths.filter { p in
            let base = p.split(separator: "/").last.map(String.init) ?? p
            return base.hasPrefix("thumb") && base.hasSuffix(".png") && p.split(separator: "/").count <= 2
        }
        for path in names.sorted() {
            let base = String(path.split(separator: "/").last ?? "")
            let data = try pkg.read(path)
            guard let (w, h) = NotabilityNote.pngSize(data), w > 0 else { continue }
            try data.write(to: out.appendingPathComponent(base))
            // Our first page at the thumbnail's width: a finite page one break tall.
            var meta = state.meta
            meta.pageSize = PageSize(width: size.width, height: breakHeight, infinite: false)
            let scale = Double(w) / size.width
            var pngs: [Data] = []
            for page in state.pages {
                pngs += try PNGWriter.render(page: page, meta: meta, options: RenderOptions(paper: false),
                                             png: PNGOptions(scale: scale))
            }
            if let first = pngs.first { try first.write(to: out.appendingPathComponent("ours-" + base)) }
            thumbs.append(["name": base, "width": w, "height": h])
        }

        var pdf: [String: Any]?
        if let (file, page) = try firstPDFPage(pkg),
           let path = pkg.paths.first(where: { $0.hasSuffix("/PDFs/" + file) || $0.hasSuffix("PDFs/" + file) }) {
            try pkg.read(path).write(to: out.appendingPathComponent("page1.pdf"))
            pdf = ["page": page]
        }

        var lo = (x: Double.infinity, y: Double.infinity), hi = (x: -Double.infinity, y: -Double.infinity)
        for s in strokes {
            for p in s.points {
                lo = (min(lo.x, p.x), min(lo.y, p.y)); hi = (max(hi.x, p.x), max(hi.y, p.y))
            }
        }
        let colors = Set(strokes.map { s in String(format: "%02x%02x%02x", s.ink.color.r, s.ink.color.g, s.ink.color.b) })
        let dropped = NotabilityImporter.dropped(note)
        var meta: [String: Any] = [
            "id": id.uuidString.lowercased(),
            "strokes": strokes.count,
            "markers": strokes.filter { $0.ink.tool == .marker }.count,
            "strokesOnPage1": strokes.filter { s in s.points.contains { $0.y < breakHeight } }.count,
            "dashed": dropped.dashedStrokes,
            "unknownStyle": dropped.unknownStyleStrokes,
            "pdfs": note.pdfCount, "pdfPages": note.pdfPageCount,
            "media": note.mediaCount, "recordings": note.recordingCount,
            "typedChars": dropped.typedTextCharacters,
            "formatVersion": note.formatVersion ?? 0,
            "documentWidth": note.paper.width, "documentPageHeight": note.paper.pageHeight,
            "sizingBehavior": note.paper.sizingBehavior ?? "", "paperSize": note.paper.size ?? "",
            "paperKind": state.meta.paper.kind.rawValue, "paperIdentifier": note.paper.identifier ?? "",
            "pageWidth": size.width, "pageHeight": size.height, "breakHeight": breakHeight,
            "bands": max(Int((size.height / breakHeight).rounded(.up)), 1),
            "colors": colors.sorted(),
            "thumbs": thumbs,
        ]
        if strokes.contains(where: { !$0.points.isEmpty }) {
            meta["inkBounds"] = [lo.x, lo.y, hi.x, hi.y]
        }
        if let pdf { meta["pdf"] = pdf }
        try json(meta).write(to: out.appendingPathComponent("meta.json"))
    }

    /// The PDF file name and 1-based page number of the note's first page,
    /// from `richText.pageLayoutArray`, if the note is made from a PDF.
    func firstPDFPage(_ pkg: NotePackage) throws -> (String, Int)? {
        guard let sessionPath = pkg.paths.first(where: { $0.hasSuffix("/Session.plist") || $0 == "Session.plist" })
        else { return nil }
        let session = try KeyedArchive(data: pkg.read(sessionPath))
        let root = try session.root(anyOf: ["$0", "root"])
        let richText = try session.field(root, "richText")
        let layouts = try session.elements(session.field(richText, "pageLayoutArray"))
        guard let first = layouts.first else { return nil }
        let name = try session.field(first, "kPageLayoutPDFFileNameKey").string
            ?? (try? session.field(session.field(first, "kPageLayoutPDFFileKey"), "pdfFileName").string) ?? nil
        guard let name else { return nil }
        let page = Int(try session.field(first, "kPageLayoutPDFPageNumberKey").int ?? 1)
        return (name, page)
    }

    func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
