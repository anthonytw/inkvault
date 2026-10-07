import Foundation
import XCTest
@testable import Sempere

/// The optional note registers `lang` and `markersBehindText` (format.md
/// §5.4), PDF page text (`pageText`, §8.2.6) and the recognition language.
final class NoteLanguageTests: XCTestCase {
    let p1 = UUID(uuidString: "00000000-0000-4000-8000-0000000000b1")!

    func decodeOp(_ json: String) throws -> Op { try JSONDecoder().decode(Op.self, from: Data(json.utf8)) }

    func testSetMetaRoundTripsAndValidates() throws {
        for op in [Op.setMeta(.lang("es-ES")), .setMeta(.lang(nil)), .setMeta(.markersBehindText(true))] {
            let data = try JSONEncoder().encode(op)
            XCTAssertEqual(try JSONDecoder().decode(Op.self, from: data), op)
        }
        XCTAssertEqual(try decodeOp(#"{"op":"setMeta","field":"lang","value":null}"#), .setMeta(.lang(nil)))
        // Not BCP 47, or the wrong type: the revision is rejected.
        XCTAssertThrowsError(try decodeOp(#"{"op":"setMeta","field":"lang","value":"en US"}"#))
        XCTAssertThrowsError(try decodeOp(#"{"op":"setMeta","field":"lang","value":"en_US"}"#))
        XCTAssertThrowsError(try decodeOp(#"{"op":"setMeta","field":"markersBehindText","value":"yes"}"#))
    }

    func testValidLanguage() {
        XCTAssertEqual(NoteMeta.validLanguage("en_US"), "en-US")
        XCTAssertEqual(NoteMeta.validLanguage("zh-Hans-CN"), "zh-Hans-CN")
        XCTAssertEqual(NoteMeta.validLanguage("es"), "es")
        for bad in ["", "1en", "en--US", "en-", "toolongsubtag", "en US", "é", String(repeating: "a-", count: 40) + "a"] {
            XCTAssertNil(NoteMeta.validLanguage(bad), bad)
        }
    }

    func testMetaJSONOmitsDefaultsAndToleratesBadSnapshotValues() throws {
        let meta = NoteMeta(created: Date(timeIntervalSince1970: 0))
        let json = String(decoding: try JSONEncoder().encode(meta), as: UTF8.self)
        XCTAssertFalse(json.contains("lang"))
        XCTAssertFalse(json.contains("markersBehindText"))
        var set = meta
        set.lang = "pt-BR"; set.markersBehindText = true
        XCTAssertEqual(try JSONDecoder().decode(NoteMeta.self, from: try JSONEncoder().encode(set)), set)
        // A snapshot written by another reader with a bad value reads as absent.
        var obj = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(meta)) as! [String: Any]
        obj["lang"] = 12; obj["markersBehindText"] = "no"
        let decoded = try JSONDecoder().decode(NoteMeta.self, from: try JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(decoded.lang)
        XCTAssertFalse(decoded.markersBehindText)
    }

    func testLastWriterWinsAndSnapshotsWithoutAClockDoNotCompete() throws {
        var log = LogBuilder()
        let base = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V"))])
        let es = log.delta(devA, 100, [.setMeta(.lang("es-ES")), .setMeta(.markersBehindText(true))])
        let en = log.delta(devB, 200, [.setMeta(.lang("en-US"))])
        let state = try NoteReducer.reconstruct([en, es, base])
        XCTAssertEqual(state.meta.lang, "en-US")
        XCTAssertTrue(state.meta.markersBehindText)
        XCTAssertEqual(state.clocks?["lang"]?.isEmpty, false)

        // A snapshot that never saw `es` and has no lang clock (as one written before the field)
        // must not beat it, although the snapshot is newer.
        let snap = try log.snapshot(devC, 500, from: [base])
        guard case .snapshot(_, let snapState) = snap.body else { return XCTFail("not a snapshot") }
        XCTAssertNil(snapState.clocks?["lang"])
        XCTAssertNil(snapState.clocks?["markersBehindText"])
        let merged = try NoteReducer.reconstruct([snap, es])
        XCTAssertEqual(merged.meta.lang, "es-ES")
        XCTAssertTrue(merged.meta.markersBehindText)

        // Cleared later: nil wins with its stamp, and the snapshot keeps the clock.
        let clear = log.delta(devA, 600, [.setMeta(.lang(nil)), .setMeta(.markersBehindText(false))])
        let cleared = try NoteReducer.reconstruct([snap, es, clear])
        XCTAssertNil(cleared.meta.lang)
        XCTAssertFalse(cleared.meta.markersBehindText)
        let snap2 = try log.snapshot(devC, 700, from: [snap, es, clear])
        guard case .snapshot(_, let s2) = snap2.body else { return XCTFail("not a snapshot") }
        XCTAssertNotNil(s2.clocks?["lang"])
        XCTAssertNil(try NoteReducer.reconstruct([snap2, es]).meta.lang)
    }

    func testRestoreSetsTheLanguageBack() throws {
        var current = NoteState(meta: NoteMeta(created: Date(timeIntervalSince1970: 0)))
        var target = current
        target.meta.lang = "fr"
        target.meta.markersBehindText = true
        let ops = NoteHistory.restoreOps(current: current, target: target)
        XCTAssertTrue(ops.contains(.setMeta(.lang("fr"))))
        XCTAssertTrue(ops.contains(.setMeta(.markersBehindText(true))))
        current.meta.lang = "fr"; current.meta.markersBehindText = true
        XCTAssertTrue(NoteHistory.restoreOps(current: current, target: target).isEmpty)
    }

    func testNoteOps() throws {
        var state = NoteState(meta: NoteMeta(created: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(try NoteOps.setLanguage(" en_US ", state: state), [.setMeta(.lang("en-US"))])
        XCTAssertThrowsError(try NoteOps.setLanguage("not a tag", state: state))
        state.meta.lang = "en-US"
        XCTAssertEqual(try NoteOps.setLanguage("en-US", state: state), [])
        XCTAssertEqual(try NoteOps.setLanguage(nil, state: state), [.setMeta(.lang(nil))])
        XCTAssertEqual(NoteOps.setMarkersBehindText(false, state: state), [])
        XCTAssertEqual(NoteOps.setMarkersBehindText(true, state: state), [.setMeta(.markersBehindText(true))])
    }

    // MARK: Recognition language

    func testRecognitionLanguagePreference() {
        let vision = ["en-US", "fr-FR", "es-ES", "es-MX", "pt-BR", "zh-Hans"]
        XCTAssertNil(RecognitionLanguage.preferred(for: nil, supported: vision))
        XCTAssertEqual(RecognitionLanguage.preferred(for: "en-US", supported: vision), ["en-US"])
        XCTAssertEqual(RecognitionLanguage.preferred(for: "es_es", supported: vision), ["es-ES"])
        XCTAssertEqual(RecognitionLanguage.preferred(for: "es-AR", supported: vision), ["es-ES", "es-MX"])
        XCTAssertEqual(RecognitionLanguage.preferred(for: "zh", supported: vision), ["zh-Hans"])
        XCTAssertNil(RecognitionLanguage.preferred(for: "de-DE", supported: vision))
        XCTAssertNil(RecognitionLanguage.preferred(for: "bad tag", supported: vision))
        XCTAssertNil(RecognitionLanguage.preferred(for: "en", supported: []))
    }

    // MARK: PDF page text

    func testPDFPageTextNormalisesAndCaps() {
        let t = PDFPageText(text: "  Line one \r\n\r\n\r\n\tline\u{0}two\u{0C}three  \n", engine: "x-1")
        XCTAssertEqual(t.text, "Line one\n\nline two\nthree".replacingOccurrences(of: "line two", with: "linetwo"))
        XCTAssertFalse(t.truncated)
        let long = PDFPageText(text: String(repeating: "é", count: 40_000), engine: "x")
        XCTAssertTrue(long.truncated)
        XCTAssertLessThanOrEqual(long.text.utf8.count, PDFPageText.maxBytes)
        XCTAssertEqual(long.text.utf8.count % 2, 0)   // cut between characters
        XCTAssertEqual(PDFPageText(json: long.json), long)
        XCTAssertNil(PDFPageText(json: .string("x")))
        XCTAssertNil(PDFPageText(json: .object(["text": .number(1)])))
    }

    func testPageTextOnItemsAndInSearch() throws {
        let blob = BlobRef(content: Data("%PDF".utf8), type: "application/pdf")
        var item = Item.pdfPage(blob: blob, pageIndex: 2, pageSize: Size(w: 612, h: 792),
                                frame: Rect(x: 0, y: 0, w: 612, h: 792), z: "a0")
        XCTAssertNil(item.pageText)
        item.pageText = PDFPageText(text: "Spectral theorem", engine: "semperepdf-1")
        // Stored as an extra field: survives a JSON round trip, readers without it keep it.
        let back = try JSONDecoder().decode(Item.self, from: try JSONEncoder().encode(item))
        XCTAssertEqual(back.pageText?.text, "Spectral theorem")
        // A malformed value is ignored, not fatal.
        var bad = item
        bad.extra[PDFPageText.field] = .array([])
        XCTAssertNil(bad.pageText)
        // Not on other kinds.
        var text = Item.text(TextContent(size: 12, color: .black, runs: [TextRun("box")]), frame: Rect(x: 0, y: 0, w: 10, h: 10), z: "a1")
        text.extra[PDFPageText.field] = item.extra[PDFPageText.field]
        XCTAssertNil(text.pageText)

        let page = Page(id: p1, order: "V", items: [item, text])
        let texts = PageText.texts(of: [page])
        XCTAssertEqual(texts.first?.text, "Spectral theorem\nbox")
        // A setItem of the register changes it like any unknown register.
        let change = try ItemChange(field: PDFPageText.field, value: .null)
        XCTAssertEqual(change, .other(field: PDFPageText.field, value: .null))
    }
}
