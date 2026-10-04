import Age
import Foundation
import InkVault
import XCTest
@testable import InkImport

/// Notes laid out on imported PDF pages (synthetic, no personal data).
final class NotabilityPDFTests: XCTestCase {
    /// Landscape slides, as Notability stores them: 4:3 thumbnails.
    static let slideThumbs = [("thumb.png", 48, 36), ("thumb2x.png", 96, 72), ("thumb12x.png", 576, 432)]

    func testPDFPagesStackAtRoundedUpHeight() throws {
        let note = try NotabilityNote.parse(data: SyntheticNote.package(pdfPages: 3, thumbnails: Self.slideThumbs))
        XCTAssertEqual(note.pdfCount, 1)
        XCTAssertEqual(note.pdfPageCount, 3)
        // 716.8 × 0.75 = 537.6; PDF pages repeat every 538 units.
        XCTAssertEqual(note.paper.pageHeight, 538, accuracy: 1e-9)

        let raw = NotabilityImporter.convert(note, scaleToLetterWidth: false)
        XCTAssertEqual(raw.meta.pageSize.breakHeight ?? 0, 538, accuracy: 1e-9)
        let scaled = NotabilityImporter.convert(note)
        XCTAssertEqual(scaled.meta.pageSize.breakHeight ?? 0, 538 * 612 / 716.8, accuracy: 1e-9)

        // Recognition on page 2 is offset by one stride.
        let words = try XCTUnwrap(raw.pages[0].recognition?.words)
        XCTAssertEqual(words.last?.box.y ?? 0, 49 + 538, accuracy: 1e-9)

        // Ink is placed exactly as on paper: the layout only moves breaks and recognition.
        let paper = NotabilityImporter.convert(try NotabilityNote.parse(data: SyntheticNote.package()),
                                               scaleToLetterWidth: false)
        XCTAssertEqual(raw.pages[0].strokes, paper.pages[0].strokes)
        XCTAssertEqual(NotabilityImporter.dropped(note).pdfPages, 3)
        XCTAssertEqual(NotabilityImporter.dropped(note).pdfs, 1)
    }

    func testWholeUnitPDFPageIsNotRoundedFurther() throws {
        // A 572-wide note on 4:3 slides: 572 × 0.75 = 429 exactly.
        let files = SyntheticNote.files(pdfPages: 2, thumbnails: Self.slideThumbs).map { path, data in
            ZipWriter.File(path: path, data: path.hasSuffix("Session.plist") ? Self.relocked(data, to: "572.0:Mac") : data)
        }
        let note = try NotabilityNote.parse(data: ZipWriter.write(files))
        XCTAssertEqual(note.paper.width, 572, accuracy: 1e-9)
        XCTAssertEqual(note.paper.pageHeight, 429, accuracy: 1e-9)
    }

    /// Rewrites the `lockedWidth:716.8:iPad` sizing string of a session
    /// archive in place (same byte length, padded with spaces).
    static func relocked(_ session: Data, to value: String) -> Data {
        let old = Data("lockedWidth:716.8:iPad".utf8), new = Data("lockedWidth:\(value)".utf8)
        precondition(new.count <= old.count)
        guard let r = session.range(of: old) else { return session }
        var out = session
        out.replaceSubrange(r, with: new + Data(repeating: 0x20, count: old.count - new.count))
        return out
    }

    func testLargestThumbnailGivesTheAspect() throws {
        // thumb.png rounds 576 × 432 down to 48 × 37; the 12× thumbnail is exact.
        let note = try NotabilityNote.parse(data: SyntheticNote.package(
            thumbnails: [("thumb.png", 48, 37), ("thumb12x.png", 576, 432)]))
        XCTAssertEqual(note.pdfPageCount, 0)
        // Paper pages are not rounded.
        XCTAssertEqual(note.paper.pageHeight, 537.6, accuracy: 1e-9)
    }

    func testPaperNoteUnchanged() throws {
        let note = try NotabilityNote.parse(data: SyntheticNote.package(
            thumbnails: [("thumb.png", 48, 63), ("thumb12x.png", 576, 756)]))
        XCTAssertEqual(note.pdfPageCount, 0)
        XCTAssertEqual(note.paper.pageHeight, 940.8, accuracy: 1e-9)
        XCTAssertEqual(NotabilityImporter.dropped(note).pdfPages, 0)
    }

    /// A PDF that was never written on: no curves, no handwriting index.
    func testInklessPDFNoteImportsEmptyAndReportsItsPages() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("inkimport-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = tmp.appendingPathComponent("Deck.note")
        try SyntheticNote.package(curves: [], pdfPages: 94, thumbnails: Self.slideThumbs, handwriting: false).write(to: path)

        let note = try NotabilityNote.parse(data: try Data(contentsOf: path))
        XCTAssertEqual(note.curves.count, 0)
        XCTAssertTrue(note.recognition.isEmpty)
        XCTAssertEqual(note.pdfPageCount, 94)

        let identity = X25519Identity()
        let vault = try Vault.create(at: tmp.appendingPathComponent("V.inkvault"), recipients: [identity.recipient],
                                     identities: [identity])
        var clock = HybridClock()
        let report = try NotabilityImporter.import(paths: [path], into: vault, device: DeviceID("0a0b0c0d")!, clock: &clock)
        let r = try XCTUnwrap(report.notes.first)
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.strokes, 0)
        XCTAssertEqual(r.dropped.pdfs, 1)
        XCTAssertEqual(r.dropped.pdfPages, 94)
        let state = try vault.reconstruct(noteId: try XCTUnwrap(r.noteId))
        XCTAssertEqual(state.pages.count, 1)
        XCTAssertEqual(state.pages[0].strokes.count, 0)
        XCTAssertEqual(state.meta.pageSize.breakHeight ?? 0, 538 * 612 / 716.8, accuracy: 1e-9)
    }
}
