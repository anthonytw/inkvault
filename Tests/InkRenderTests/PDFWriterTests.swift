import XCTest
import InkVault
@testable import InkRender
#if canImport(PDFKit)
import PDFKit
#endif

final class PDFWriterTests: XCTestCase {
    private func sampleNote(title: String = "My Note", pages: Int = 2) -> NoteState {
        let s = T.stroke((0..<6).map { T.pt(Double($0) * 20 + 10, 100 + 30 * sin(Double($0))) })
        return T.note(pages: Array(repeating: [s], count: pages), meta: T.meta(title: title))
    }

    private func count(_ needle: String, in hay: String) -> Int { hay.components(separatedBy: needle).count - 1 }

    func testHeaderTrailerAndXref() throws {
        let data = try PDFWriter.render(note: sampleNote(), options: RenderOptions())
        let text = T.latin1(data)
        XCTAssertTrue(text.hasPrefix("%PDF-1.4"))
        XCTAssertTrue(text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("%%EOF"))

        let sx = try XCTUnwrap(text.range(of: "startxref\n", options: .backwards))
        let tail = text[sx.upperBound...]
        let xrefOffset = try XCTUnwrap(Int(tail.prefix(while: { $0.isNumber })))
        let bytes = [UInt8](data)
        let xrefLine = String(decoding: bytes[xrefOffset..<(xrefOffset + 5)], as: UTF8.self)
        XCTAssertEqual(xrefLine, "xref\n")

        let lines = text[text.index(text.startIndex, offsetBy: xrefOffset)...].split(separator: "\n", omittingEmptySubsequences: false)
        let sizeParts = lines[1].split(separator: " ")
        let n = try XCTUnwrap(Int(sizeParts[1]))
        XCTAssertEqual(lines[2], "0000000000 65535 f ")
        for obj in 1..<n {
            let entry = lines[2 + obj]
            XCTAssertEqual(entry.count, 19)   // 20 bytes with the newline
            let off = try XCTUnwrap(Int(entry.prefix(10)))
            let head = String(decoding: bytes[off..<min(off + 12, bytes.count)], as: UTF8.self)
            XCTAssertTrue(head.hasPrefix("\(obj) 0 obj"), "object \(obj) at \(off): \(head)")
        }
        XCTAssertTrue(text.contains("/Size \(n)"))
    }

    func testInfoAndPageCount() throws {
        let text = T.latin1(try PDFWriter.render(note: sampleNote(title: "Lecture (3)"), options: RenderOptions()))
        XCTAssertTrue(text.contains("/Title (Lecture \\(3\\))"))
        XCTAssertTrue(text.contains("/Producer (InkVault)"))
        XCTAssertEqual(count("/Type /Page /", in: text), 2)
        XCTAssertTrue(text.contains("/Count 2"))
        XCTAssertTrue(text.contains("/MediaBox [0 0 200 300]"))
    }

    func testNonASCIITitleIsUTF16() throws {
        let text = T.latin1(try PDFWriter.render(note: sampleNote(title: "\u{00E9}"), options: RenderOptions()))
        XCTAssertTrue(text.contains("/Title <FEFF00E9>"))
    }

    func testInfinitePageSplitting() throws {
        let tall = T.stroke([T.pt(10, 10), T.pt(20, 1500), T.pt(30, 1800)])
        let note = T.note(pages: [[tall], []], meta: T.meta(size: PageSize(width: 200, height: 500, infinite: true)))
        let text = T.latin1(try PDFWriter.render(note: note, options: RenderOptions(compress: false)))
        // First page: extent ~1800 -> 4 chunks of 500. Second page: empty -> 1 chunk.
        XCTAssertEqual(count("/Type /Page /", in: text), 5)
        var o = RenderOptions(compress: false)
        o.infiniteChunkHeight = 1000
        let text2 = T.latin1(try PDFWriter.render(note: note, options: o))
        XCTAssertEqual(count("/Type /Page /", in: text2), 2 + 1)
        XCTAssertTrue(text2.contains("/MediaBox [0 0 200 1000]"))
    }

    func testFiniteStrokeOutsidePageStillOnePagePerNotePage() throws {
        let far = T.stroke([T.pt(10, 5000), T.pt(20, 5100)])
        let text = T.latin1(try PDFWriter.render(note: T.note(pages: [[far]]), options: RenderOptions(compress: false)))
        XCTAssertEqual(count("/Type /Page /", in: text), 1)
    }

    func testUncompressedContainsOperators() throws {
        let text = T.latin1(try PDFWriter.render(note: sampleNote(), options: RenderOptions(compress: false)))
        XCTAssertTrue(text.contains("re f"), "paper background")
        XCTAssertTrue(text.contains(" m\n"))
        XCTAssertTrue(text.contains(" l\n"))
        XCTAssertTrue(text.contains("1 0 0 -1 0 300 cm"))
        XCTAssertFalse(text.contains("FlateDecode"))
    }

    func testAlphaUsesExtGState() throws {
        let s = T.stroke([T.pt(0, 0), T.pt(10, 10)], tool: .marker, width: 6, color: Color(r: 255, g: 0, b: 0, a: 255))
        let text = T.latin1(try PDFWriter.render(note: T.note(pages: [[s]]), options: RenderOptions(compress: false)))
        XCTAssertTrue(text.contains("/ca 0.5 /CA 0.5"))
        XCTAssertTrue(text.contains("/GS500 gs"))
        XCTAssertTrue(text.contains("/ExtGState << /GS500 "))
    }

    private func streams(_ data: Data) -> [Data] {
        let text = T.latin1(data)
        var result: [Data] = []
        var search = text.startIndex..<text.endIndex
        while let r = text.range(of: "stream\n", range: search), let e = text.range(of: "\nendstream", range: r.upperBound..<text.endIndex) {
            let lo = text.distance(from: text.startIndex, to: r.upperBound)
            let hi = text.distance(from: text.startIndex, to: e.lowerBound)
            result.append(data.subdata(in: lo..<hi))
            search = e.upperBound..<text.endIndex
        }
        return result
    }

    func testCompressedStreamInflatesToUncompressedContent() throws {
        let note = sampleNote()
        let plain = try PDFWriter.render(note: note, options: RenderOptions(compress: false))
        let packed = try PDFWriter.render(note: note, options: RenderOptions(compress: true))
        XCTAssertTrue(T.latin1(packed).contains("/Filter /FlateDecode"))
        XCTAssertLessThan(packed.count, plain.count)
        let a = streams(plain), b = streams(packed)
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(a.count, b.count)
        for (p, c) in zip(a, b) {
            XCTAssertEqual(try Zlib.decompress(c), p)
        }
    }

    func testEmptyNoteStillHasOnePage() throws {
        let text = T.latin1(try PDFWriter.render(note: T.note(pages: []), options: RenderOptions(compress: false)))
        XCTAssertEqual(count("/Type /Page /", in: text), 1)
    }

    func testMultipleNotes() throws {
        let data = try PDFWriter.render(notes: [sampleNote(title: "A"), sampleNote(title: "B", pages: 1)], options: RenderOptions())
        let text = T.latin1(data)
        XCTAssertEqual(count("/Type /Page /", in: text), 3)
        XCTAssertTrue(text.contains("/Title (A; B)"))
    }

    func testPaperOptionOff() throws {
        let text = T.latin1(try PDFWriter.render(note: sampleNote(), options: RenderOptions(paper: false, compress: false)))
        XCTAssertFalse(text.contains("re f"))
    }

    #if canImport(PDFKit)
    func testPDFKitOpensDocument() throws {
        let data = try PDFWriter.render(note: sampleNote(), options: RenderOptions())
        let doc = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(doc.pageCount, 2)
        XCTAssertEqual(doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "My Note")
    }
    #endif
}
