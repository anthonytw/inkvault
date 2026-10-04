import Age
import Foundation
import InkRender
import InkVault
import XCTest
@testable import InkImport

/// Tests against a real Notability backup. Skipped unless
/// `INKVAULT_NOTABILITY_SAMPLES` names a backup zip (or a directory of
/// `.note` files); CI never has personal data.
///
/// - `INKVAULT_NOTABILITY_RENDER_DIR`: also write each rendered first page
///   and its Notability thumbnail there as PNGs, for eyeballing.
/// - `INKVAULT_NOTABILITY_ONLY`: render only notes whose path contains this
///   text, including notes on PDFs, without asserting (for eyeballing).
/// - `INKVAULT_NOTABILITY_BULK_VAULT`: `testBulkImport` imports every note
///   into a fresh vault at that path (must not exist) and prints a report.
final class RealNotabilityTests: XCTestCase {
    static var samples: URL? {
        ProcessInfo.processInfo.environment["INKVAULT_NOTABILITY_SAMPLES"].map { URL(fileURLWithPath: $0) }
    }

    /// (label, notebook, bytes) of every `.note` in the samples.
    func allNotes() throws -> [(String, NotePackage)] {
        guard let url = Self.samples else { throw XCTSkip("INKVAULT_NOTABILITY_SAMPLES not set") }
        return try NotabilityImporter.sources(url).map { ($0.label, try $0.load()) }
    }

    /// Every note parses and converts; the mapping is self-consistent.
    func testEveryNoteParsesAndConverts() throws {
        var curves = 0, failures: [String] = []
        for (label, pkg) in try allNotes() {
            do {
                let note = try NotabilityNote.parse(package: pkg)
                let state = NotabilityImporter.convert(note)
                XCTAssertEqual(state.pages.count, 1)
                XCTAssertEqual(state.pages[0].strokes.count, note.curves.count, label)
                XCTAssertGreaterThan(note.paper.width, 0)
                curves += note.curves.count
            } catch {
                failures.append("\(label): \(error)")
            }
        }
        XCTAssertEqual(failures, [])
        print("parsed curves: \(curves)")
    }

    #if os(macOS)
    /// Renders the first Notability page of real notes and compares it with
    /// Notability's own thumbnail: same aspect ratio, and the ink's bounding
    /// box in the same place.
    func testRenderedFirstPageMatchesThumbnail() throws {
        let renderDir = ProcessInfo.processInfo.environment["INKVAULT_NOTABILITY_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("inkimport-fid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        if let renderDir { try FileManager.default.createDirectory(at: renderDir, withIntermediateDirectories: true) }

        let only = ProcessInfo.processInfo.environment["INKVAULT_NOTABILITY_ONLY"]
        var checked = 0, index = 0
        for (label, pkg) in try allNotes() {
            if let only, !label.contains(only) { continue }
            guard let thumbPath = pkg.paths.first(where: { $0.hasSuffix("/thumb12x.png") }) else { continue }
            let note = try NotabilityNote.parse(package: pkg)
            // Notes on imported PDFs show the PDF in the thumbnail; skip them.
            guard only != nil || (note.pdfCount == 0 && note.curves.count >= 50 && note.mediaCount == 0) else { continue }
            let state = NotabilityImporter.convert(note)
            // The page's breakHeight paginates it like Notability.
            let pdf = try PDFWriter.render(note: state)
            index += 1
            let name = "n\(index)"
            let pdfURL = tmp.appendingPathComponent("\(name).pdf")
            try pdf.write(to: pdfURL)
            let thumbURL = tmp.appendingPathComponent("\(name)-thumb.png")
            try pkg.read(thumbPath).write(to: thumbURL)
            let rendered = try bitmap(pdfURL, tmp.appendingPathComponent("\(name).bmp"))
            let thumb = try bitmap(thumbURL, tmp.appendingPathComponent("\(name)-thumb.bmp"))
            // Some thumbnails are stale and show blank paper: nothing to compare.
            guard let tb = thumb.inkBox() ?? (only != nil ? (0, 0, 1, 1) : nil) else { continue }
            if let renderDir {
                try sips(pdfURL, "png", renderDir.appendingPathComponent("\(name)-inkvault.png"))
                try FileManager.default.copyItem(at: thumbURL, to: renderDir.appendingPathComponent("\(name)-notability.png"))
                print("\(name): \(label)")
            }

            if only != nil { checked += 1; continue }
            let ra = Double(rendered.height) / Double(rendered.width)
            let ta = Double(thumb.height) / Double(thumb.width)
            XCTAssertEqual(ra, ta, accuracy: 0.01, "aspect \(label)")
            let rb = try XCTUnwrap(rendered.inkBox(), label)
            for (a, b, what) in [(rb.0, tb.0, "left"), (rb.1, tb.1, "top"), (rb.2, tb.2, "right"), (rb.3, tb.3, "bottom")] {
                XCTAssertEqual(a, b, accuracy: 0.02, "\(what) edge of ink, \(label)")
            }
            print(String(format: "%@: aspect %.4f vs %.4f; ink box %.3f %.3f %.3f %.3f vs %.3f %.3f %.3f %.3f", name, ra, ta,
                         rb.0, rb.1, rb.2, rb.3, tb.0, tb.1, tb.2, tb.3))
            checked += 1
            if checked >= 8, ProcessInfo.processInfo.environment["INKVAULT_FIDELITY_ALL"] == nil { break }
        }
        XCTAssertGreaterThanOrEqual(checked, only == nil ? 5 : 1, "not enough real notes with ink and thumbnails")
    }

    struct Bitmap {
        var width: Int, height: Int
        var pixels: [UInt8]   // RGBA, top-down

        /// Bounding box of dark (ink) pixels, as fractions of width/height.
        func inkBox() -> (Double, Double, Double, Double)? {
            var x0 = width, y0 = height, x1 = -1, y1 = -1
            for y in 0..<height {
                for x in 0..<width {
                    let i = 4 * (y * width + x)
                    let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                    let lum = 0.3 * Double(r) + 0.59 * Double(g) + 0.11 * Double(b)
                    // Dark ink, or grey (thin, antialiased) ink; not the bluish paper pattern.
                    let grey = max(r, g, b) - min(r, g, b) < 16
                    guard pixels[i + 3] > 128, lum < 110 || (grey && lum < 200) else { continue }
                    x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
                }
            }
            guard x1 >= 0 else { return nil }
            return (Double(x0) / Double(width), Double(y0) / Double(height),
                    Double(x1 + 1) / Double(width), Double(y1 + 1) / Double(height))
        }
    }

    func sips(_ input: URL, _ format: String, _ output: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        p.arguments = ["-s", "format", format, input.path, "--out", output.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ImportError.io("sips failed on \(input.lastPathComponent)") }
    }

    /// Converts with `sips` to BMP and decodes it.
    func bitmap(_ input: URL, _ bmp: URL) throws -> Bitmap {
        try sips(input, "bmp", bmp)
        let d = try Data(contentsOf: bmp)
        func u32(_ i: Int) -> Int { Int(d.u32(i)) }
        let offset = u32(10), width = u32(18)
        let rawHeight = Int32(bitPattern: d.u32(22))
        let bpp = Int(d.u16(28))
        let height = Int(abs(rawHeight))
        let stride = (width * bpp / 8 + 3) / 4 * 4
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let row = rawHeight > 0 ? height - 1 - y : y
            for x in 0..<width {
                let s = d.startIndex + offset + row * stride + x * bpp / 8
                let o = 4 * (y * width + x)
                px[o] = d[s + 2]; px[o + 1] = d[s + 1]; px[o + 2] = d[s]
                px[o + 3] = bpp == 32 ? d[s + 3] : 255
            }
        }
        return Bitmap(width: width, height: height, pixels: px)
    }
    #endif

    /// Imports everything into a fresh vault and prints the report.
    func testBulkImport() throws {
        guard let target = ProcessInfo.processInfo.environment["INKVAULT_NOTABILITY_BULK_VAULT"] else {
            throw XCTSkip("INKVAULT_NOTABILITY_BULK_VAULT not set")
        }
        guard let samples = Self.samples else { throw XCTSkip("INKVAULT_NOTABILITY_SAMPLES not set") }
        let identity = X25519Identity()
        let vault = try Vault.create(at: URL(fileURLWithPath: target), recipients: [identity.recipient],
                                     identities: [identity])
        var clock = HybridClock()
        let started = Date()
        let report = try NotabilityImporter.import(paths: [samples], into: vault, device: DeviceID("1a2b3c4d")!,
                                                   clock: &clock)
        let elapsed = Date().timeIntervalSince(started)
        for n in report.notes where n.status != .ok {
            print("NOT OK \(n.status) \(n.source)")
        }
        let slowest = report.notes.max { $0.seconds < $1.seconds }
        var dropped = NotabilityImporter.Dropped()
        for n in report.notes {
            dropped.typedTextCharacters += n.dropped.typedTextCharacters; dropped.pdfs += n.dropped.pdfs
            dropped.media += n.dropped.media; dropped.recordings += n.dropped.recordings
            dropped.dashedStrokes += n.dropped.dashedStrokes; dropped.unknownStyleStrokes += n.dropped.unknownStyleStrokes
        }
        print("""
        BULK: notes \(report.notes.count) ok \(report.imported) skipped \(report.skipped) failed \(report.failed)
        BULK: strokes \(report.strokes) recognised pages \(report.notes.reduce(0) { $0 + $1.recognizedPages })
        BULK: wall \(String(format: "%.1f", elapsed)) s; slowest \(String(format: "%.2f", slowest?.seconds ?? 0)) s \(slowest?.source ?? "")
        BULK: dropped \(dropped)
        """)
        // Every written note reconstructs.
        for n in report.notes where n.status == .ok {
            guard let id = n.noteId else { XCTFail("no id for \(n.source)"); continue }
            let state = try vault.reconstruct(noteId: id)
            XCTAssertEqual(state.pages.first?.strokes.count, n.strokes, n.source)
        }
        // A second run skips everything.
        let again = try NotabilityImporter.import(paths: [samples], into: vault, device: DeviceID("1a2b3c4d")!,
                                                  clock: &clock)
        XCTAssertEqual(again.imported, 0)
    }
}
