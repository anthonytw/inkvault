import Age
import Foundation
import InkRender
import InkVault
import XCTest
@testable import InkImport

/// Parsing, mapping and import of the synthetic `.note` (no personal data).
final class NotabilityTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("inkimport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testParseSyntheticNote() throws {
        let note = try NotabilityNote.parse(data: SyntheticNote.package())
        XCTAssertEqual(note.metadata.name, "Synthetic note")
        XCTAssertEqual(note.metadata.subject, "Fixtures")
        XCTAssertEqual(note.metadata.tags, ["alpha", "beta"])
        XCTAssertEqual(note.metadata.uuid, SyntheticNote.uuid)
        XCTAssertEqual(note.metadata.created, SyntheticNote.created)
        XCTAssertEqual(note.metadata.modified, SyntheticNote.created.addingTimeInterval(60))
        XCTAssertEqual(note.bundleVersion, "14.2.6")
        XCTAssertEqual(note.formatVersion, 9)
        XCTAssertEqual(note.typedText, "typed words")
        XCTAssertEqual(note.recordingCount, 0)
        XCTAssertEqual(note.pdfPageCount, 0)

        XCTAssertEqual(note.paper.width, 716.8, accuracy: 1e-9)
        XCTAssertEqual(note.paper.pageHeight, 716.8 * 63 / 48, accuracy: 1e-9)   // thumbnail 48 × 63
        XCTAssertEqual(note.paper.kind, .dot)
        XCTAssertEqual(try XCTUnwrap(note.paper.spacing), 0.25 * 716.8 / 8.5, accuracy: 1e-9)

        XCTAssertEqual(note.curves.count, 4)
        let c0 = note.curves[0]
        XCTAssertEqual(c0.points.count, 4)
        XCTAssertEqual(c0.points[1], .init(x: 110, y: 90))
        XCTAssertEqual(c0.fractionalWidths, [0.5, 1.0])
        XCTAssertEqual(c0.width, 1.4, accuracy: 1e-6)
        XCTAssertEqual(c0.color, Color(r: 0, g: 0, b: 0, a: 255))
        XCTAssertEqual(c0.forces, [1, 1])
        XCTAssertEqual(c0.azimuths?.first ?? 0, .pi / 2, accuracy: 1e-6)
        XCTAssertEqual(c0.altitudes?.first ?? 0, .pi / 2, accuracy: 1e-6)
        XCTAssertNotNil(c0.uuid)
        XCTAssertEqual(note.curves[1].color, Color(r: 0x00, g: 0x6F, b: 0xFF))
        XCTAssertEqual(note.curves[1].fractionalWidths.count, 3)
        XCTAssertTrue(note.curves[2].isHighlighter)
        XCTAssertEqual(note.curves[2].color.a, 0x6B)
        XCTAssertTrue(note.curves[3].dashed)
        XCTAssertFalse(note.curves[0].dashed)

        XCTAssertEqual(note.recognition.keys.sorted(), [1, 2])
        let p1 = try XCTUnwrap(note.recognition[1])
        XCTAssertEqual(p1.text, "ab cd")
        XCTAssertEqual(p1.origin, .init(x: 99, y: 89))
        XCTAssertEqual(p1.characterBoxes.count, 5)
        XCTAssertNil(p1.characterBoxes[2])
        XCTAssertEqual(p1.characterBoxes[1], Recognition.Box(x: 10, y: 1, w: 10, h: 11))
    }

    func testConvertMapping() throws {
        let note = try NotabilityNote.parse(data: SyntheticNote.package())
        let state = NotabilityImporter.convert(note, notebook: "Research/Daily log", scaleToLetterWidth: false)
        let inset = 716.8 / 38.4
        XCTAssertEqual(state.meta.title, "Synthetic note")
        XCTAssertEqual(state.meta.notebook, "Research/Daily log")
        XCTAssertEqual(state.meta.tags, ["alpha", "beta"])
        XCTAssertEqual(state.meta.created, SyntheticNote.created)
        XCTAssertEqual(state.meta.paper.kind, .dot)
        XCTAssertTrue(state.meta.pageSize.infinite)
        XCTAssertEqual(state.meta.pageSize.width, 716.8, accuracy: 1e-9)
        XCTAssertEqual(state.meta.pageSize.breakHeight ?? 0, SyntheticNote.pageHeight, accuracy: 1e-9)
        // Ink reaches page 2, so the extent covers it.
        XCTAssertGreaterThan(state.meta.pageSize.height, SyntheticNote.pageHeight + 50)

        XCTAssertEqual(state.pages.count, 1)
        let strokes = state.pages[0].strokes
        XCTAssertEqual(strokes.count, 4)
        // Highlighter first (drawn behind the ink), opaque pigment, marker tool, base width.
        XCTAssertEqual(strokes[0].ink.tool, .marker)
        XCTAssertEqual(strokes[0].ink.color, Color(r: 0xFF, g: 0xFF, b: 0))
        XCTAssertEqual(strokes[0].ink.width, 28, accuracy: 1e-6)
        XCTAssertEqual(strokes[1].ink.tool, .pen)
        XCTAssertEqual(strokes[2].ink.color, Color(r: 0x00, g: 0x6F, b: 0xFF))

        // The spline passes through Notability's on-curve points (shifted by the inset).
        let pen = strokes[1]
        XCTAssertEqual(pen.points.first?.x ?? 0, 100 + inset, accuracy: 1e-6)
        XCTAssertEqual(pen.points.last?.x ?? 0, 140 + inset, accuracy: 1e-6)
        XCTAssertEqual(pen.points.first?.w ?? 0, 1.4 * 0.5, accuracy: 1e-6)
        XCTAssertEqual(pen.points.last?.w ?? 0, 1.4, accuracy: 1e-6)
        XCTAssertEqual(pen.points.first?.f ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(pen.points.first?.az ?? 0, .pi / 2, accuracy: 1e-6)
        // Evaluated B-spline at the interior samples hits the Bézier.
        let mid = BSpline.location(of: pen.points, at: Double(pen.points.count - 1) / 2)
        XCTAssertEqual(mid.x, 120 + inset, accuracy: 0.05)   // symmetric arc: u = 0.5 at x = 120
        XCTAssertEqual(mid.y, 92.5, accuracy: 0.05)

        // Ids are derived and stable.
        XCTAssertEqual(NotabilityImporter.convert(note), NotabilityImporter.convert(note))
        XCTAssertNotEqual(NotabilityImporter.convert(note, idSalt: "0a0b0c0d-2").pages[0].id, state.pages[0].id)
        XCTAssertEqual(NotabilityImporter.noteId(for: note), UUID.derived(from: "inkvault-notability:" + SyntheticNote.uuid))
        let id = NotabilityImporter.noteId(for: note).uuidString
        XCTAssertEqual(Array(id)[14], "8")   // version 8

        let dropped = NotabilityImporter.dropped(note)
        XCTAssertEqual(dropped.typedTextCharacters, 11)
        XCTAssertEqual(dropped.dashedStrokes, 1)
        XCTAssertEqual(dropped.pdfs, 0)

        // Renders.
        XCTAssertFalse(try PDFWriter.render(note: state).isEmpty)
    }

    func testRecognitionMerge() throws {
        let note = try NotabilityNote.parse(data: SyntheticNote.package())
        let rec = try XCTUnwrap(NotabilityImporter.convert(note, scaleToLetterWidth: false).pages[0].recognition)
        let inset = 716.8 / 38.4
        XCTAssertEqual(rec.engine, "notability-14.2.6")
        XCTAssertEqual(rec.text, "ab cd\nx")
        XCTAssertEqual(rec.words.map(\.text), ["ab", "cd", "x"])
        // "ab": union of (0,0,10,12) and (10,1,10,11), moved by origin (99, 89).
        for (box, x, w) in [(rec.words[0].box, 99.0, 20.0), (rec.words[1].box, 124.0, 16.0)] {
            XCTAssertEqual(box.x, x + inset, accuracy: 1e-9)
            XCTAssertEqual(box.y, 89, accuracy: 1e-9)
            XCTAssertEqual(box.w, w, accuracy: 1e-9)
            XCTAssertEqual(box.h, 12, accuracy: 1e-9)
        }
        // Page 2 adds one page height.
        let b = rec.words[2].box
        XCTAssertEqual(b.x, 199 + inset, accuracy: 1e-9)
        XCTAssertEqual(b.y, 49 + SyntheticNote.pageHeight, accuracy: 1e-9)
        XCTAssertEqual(b.w, 32, accuracy: 1e-9)
    }

    func testScaleToLetterWidth() throws {
        let note = try NotabilityNote.parse(data: SyntheticNote.package())
        let raw = NotabilityImporter.convert(note, scaleToLetterWidth: false)
        let scaled = NotabilityImporter.convert(note)   // default: scaled
        let k = 612 / 716.8
        XCTAssertEqual(scaled.meta.pageSize.width, 612, accuracy: 1e-9)
        XCTAssertEqual(scaled.meta.pageSize.breakHeight ?? 0, 612 * 21 / 16, accuracy: 1e-9)
        XCTAssertEqual(scaled.meta.pageSize.height, raw.meta.pageSize.height * k, accuracy: 1)
        XCTAssertEqual(scaled.meta.paper.spacing, raw.meta.paper.spacing * k, accuracy: 1e-9)
        XCTAssertEqual(scaled.meta.paper.spacing, 18, accuracy: 1e-9)   // 0.25 in on letter
        for (a, b) in zip(raw.pages[0].strokes, scaled.pages[0].strokes) {
            XCTAssertEqual(b.ink.width, a.ink.width * k, accuracy: 1e-9)
            for (p, q) in zip(a.points, b.points) {
                XCTAssertEqual(q.x, p.x * k, accuracy: 1e-9)
                XCTAssertEqual(q.y, p.y * k, accuracy: 1e-9)
                XCTAssertEqual(q.w, p.w * k, accuracy: 1e-9)
                XCTAssertEqual(q.f, p.f)
            }
        }
        let rb = try XCTUnwrap(raw.pages[0].recognition?.words.first?.box)
        let sb = try XCTUnwrap(scaled.pages[0].recognition?.words.first?.box)
        XCTAssertEqual(sb.x, rb.x * k, accuracy: 1e-9)
        XCTAssertEqual(sb.h, rb.h * k, accuracy: 1e-9)
        // Same ids either way.
        XCTAssertEqual(scaled.pages[0].strokes.map(\.id), raw.pages[0].strokes.map(\.id))
    }

    func testImportIntoVaultSkipAndOverwrite() throws {
        let noteDir = tmp.appendingPathComponent("Notability/Research/Daily log")
        try FileManager.default.createDirectory(at: noteDir, withIntermediateDirectories: true)
        let notePath = noteDir.appendingPathComponent("Synthetic.note")
        try SyntheticNote.package().write(to: notePath)
        try Data("not a zip".utf8).write(to: noteDir.appendingPathComponent("Broken.note"))

        let identity = try NativeIdentity.generate(.postQuantum)
        let vault = try Vault.create(at: tmp.appendingPathComponent("V.inkvault"), recipients: [identity.recipient],
                                     identities: [identity])
        let device = DeviceID("0a0b0c0d")!
        var clock = HybridClock()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let report = try NotabilityImporter.import(paths: [tmp.appendingPathComponent("Notability")], into: vault,
                                                   device: device, clock: &clock, now: { now })
        XCTAssertEqual(report.notes.count, 2)
        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.failed, 1)
        let ok = try XCTUnwrap(report.notes.first { $0.status == .ok })
        XCTAssertEqual(ok.notebook, "Research/Daily log")
        XCTAssertEqual(ok.strokes, 4)
        XCTAssertEqual(ok.recognizedPages, 2)
        XCTAssertEqual(ok.dropped.typedTextCharacters, 11)
        XCTAssertEqual(ok.originalWidth ?? 0, 716.8, accuracy: 1e-9)

        let id = try XCTUnwrap(ok.noteId)
        let state = try vault.reconstruct(noteId: id)
        XCTAssertEqual(state.meta.title, "Synthetic note")
        XCTAssertEqual(state.meta.notebook, "Research/Daily log")
        XCTAssertEqual(state.meta.created, SyntheticNote.created)   // wall = Notability creation date
        XCTAssertEqual(state.pages.first?.strokes.count, 4)
        XCTAssertEqual(state.pages.first?.recognition?.words.count, 3)
        XCTAssertEqual(state.meta.pageSize.width, 612, accuracy: 1e-9)
        XCTAssertEqual(state.meta.pageSize.breakHeight ?? 0, 803.25, accuracy: 1e-9)
        let names = try vault.revisionNames(of: id)
        XCTAssertEqual(names.count, 1)

        // Again: skipped, nothing written.
        let again = try NotabilityImporter.import(paths: [notePath], into: vault, device: device, clock: &clock,
                                                  now: { now })
        XCTAssertEqual(again.notes.map(\.status), [.skipped("already in the vault")])
        XCTAssertEqual(try vault.revisionNames(of: id).count, 1)

        // Overwrite: a second delta removes the old page and adds fresh ids.
        let over = try NotabilityImporter.import(paths: [notePath], into: vault, device: device, clock: &clock,
                                                 options: .init(overwrite: true, notebook: "Elsewhere"), now: { now })
        XCTAssertEqual(over.imported, 1)
        let rewritten = try vault.reconstruct(noteId: id)
        XCTAssertEqual(rewritten.pages.count, 1)
        XCTAssertNotEqual(rewritten.pages[0].id, state.pages[0].id)
        XCTAssertEqual(rewritten.pages[0].strokes.count, 4)
        XCTAssertEqual(rewritten.meta.notebook, "Elsewhere")
        XCTAssertEqual(try vault.revisionNames(of: id).count, 2)
    }

    func testImportFromBackupZip() throws {
        let note = SyntheticNote.package()
        let backup = ZipWriter.write([
            .init(path: "Notability/Research/Daily log/A.note", data: note, deflate: false),
            .init(path: "Notability/Research/Daily log/A copy.note", data: note, deflate: true),
            .init(path: "Notability/Research/Daily log/A.pdf", data: Data("%PDF".utf8)),
        ], zip64: true)
        let url = tmp.appendingPathComponent("backup.zip")
        try backup.write(to: url)
        let identity = try NativeIdentity.generate(.postQuantum)
        let vault = try Vault.create(at: tmp.appendingPathComponent("Z.inkvault"), recipients: [identity.recipient],
                                     identities: [identity])
        var clock = HybridClock()
        let report = try NotabilityImporter.import(paths: [url], into: vault, device: DeviceID("0a0b0c0d")!,
                                                   clock: &clock)
        XCTAssertEqual(report.notes.count, 2)
        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.skipped, 1)   // same Notability uuid twice
        XCTAssertEqual(report.notes[0].notebook, "Research/Daily log")
        XCTAssertTrue(report.notes[0].source.hasSuffix("!Notability/Research/Daily log/A copy.note"))
    }

    /// Two devices overwriting in turn never re-mint a tombstoned id.
    func testOverwriteFromTwoDevices() throws {
        let notePath = tmp.appendingPathComponent("Synthetic.note")
        try SyntheticNote.package().write(to: notePath)
        let identity = try NativeIdentity.generate(.postQuantum)
        let vault = try Vault.create(at: tmp.appendingPathComponent("T.inkvault"), recipients: [identity.recipient],
                                     identities: [identity])
        let a = DeviceID("aaaaaaaa")!, b = DeviceID("bbbbbbbb")!
        var clock = HybridClock()
        var pageIds = Set<UUID>()
        for (device, overwrite) in [(a, false), (a, true), (b, true), (b, true), (a, true)] {
            let r = try NotabilityImporter.import(paths: [notePath], into: vault, device: device, clock: &clock,
                                                  options: .init(overwrite: overwrite))
            XCTAssertEqual(r.imported, 1, "\(device) \(r.notes.map(\.status))")
            let state = try vault.reconstruct(noteId: try XCTUnwrap(r.notes.first?.noteId))
            XCTAssertEqual(state.pages.count, 1)
            XCTAssertEqual(state.pages.first?.strokes.count, 4)
            XCTAssertTrue(pageIds.insert(try XCTUnwrap(state.pages.first?.id)).inserted, "page id re-minted")
        }
    }

    /// An overwrite re-sets tags and notebook even when they are now empty.
    func testOverwriteClearsTagsAndNotebook() throws {
        let identity = try NativeIdentity.generate(.postQuantum)
        let vault = try Vault.create(at: tmp.appendingPathComponent("C.inkvault"), recipients: [identity.recipient],
                                     identities: [identity])
        var clock = HybridClock()
        let first = tmp.appendingPathComponent("one.note"), second = tmp.appendingPathComponent("two.note")
        try SyntheticNote.package().write(to: first)
        try SyntheticNote.package(subject: "unsortedNotesKey", tags: "").write(to: second)
        let device = DeviceID("0a0b0c0d")!
        let r = try NotabilityImporter.import(paths: [first], into: vault, device: device, clock: &clock)
        let id = try XCTUnwrap(r.notes.first?.noteId)
        XCTAssertEqual(try vault.reconstruct(noteId: id).meta.notebook, "Fixtures")
        _ = try NotabilityImporter.import(paths: [second], into: vault, device: device, clock: &clock,
                                          options: .init(overwrite: true))
        let state = try vault.reconstruct(noteId: id)
        XCTAssertEqual(state.meta.tags, [])
        XCTAssertNil(state.meta.notebook)
    }

    /// An unzipped `.note` package directory imports like the zip.
    func testPackageDirectory() throws {
        let dir = tmp.appendingPathComponent("Notability/Research/Unzipped.note")
        try SyntheticNote.writeDirectory(dir)
        let note = try NotabilityNote.parse(package: NotePackage(directory: dir))
        XCTAssertEqual(note.curves.count, 4)
        XCTAssertEqual(note.recognition.count, 2)
        let identity = try NativeIdentity.generate(.postQuantum)
        let vault = try Vault.create(at: tmp.appendingPathComponent("D.inkvault"), recipients: [identity.recipient],
                                     identities: [identity])
        var clock = HybridClock()
        for input in [dir, tmp.appendingPathComponent("Notability")] {
            let r = try NotabilityImporter.import(paths: [input], into: vault, device: DeviceID("0a0b0c0d")!,
                                                  clock: &clock)
            XCTAssertEqual(r.notes.count, 1, "\(input.path)")   // the package is not searched inside
            XCTAssertEqual(r.notes.first?.notebook, "Research")
        }
    }

    /// A curve whose point count is not 3k + 1 is read as a polyline; the rest stay Bézier.
    func testNonConformingCurveIsPolyline() throws {
        var cs = SyntheticNote.curves
        cs.append(.init(points: [(10, 10), (20, 10), (30, 20), (40, 20), (50, 30)], fw: [1, 1, 1, 1, 1],
                        width: 1.4, rgba: [0, 0, 0, 255], style: 3))
        let note = try NotabilityNote.parse(data: SyntheticNote.package(curves: cs))
        XCTAssertEqual(note.curves.count, 5)
        XCTAssertEqual(note.curves[0].points.count, 4)              // Bézier untouched
        XCTAssertEqual(note.curves[4].points.count, 3 * 4 + 1)      // polyline as degenerate Béziers
        XCTAssertEqual(note.curves[4].fractionalWidths.count, 5)
        XCTAssertEqual(note.curves[4].points[3], .init(x: 20, y: 10))
        let state = NotabilityImporter.convert(note, scaleToLetterWidth: false)
        XCTAssertEqual(state.pages[0].strokes.count, 5)
    }

    /// Corrupt coordinates fail the note with a report row, never trap.
    func testHugeCoordinatesFailCleanly() throws {
        var cs = SyntheticNote.curves
        cs[0].points[2] = (3e38, 3e38)
        let data = SyntheticNote.package(curves: cs)
        XCTAssertThrowsError(try NotabilityNote.parse(data: data)) { e in
            guard case ImportError.notability = e else { return XCTFail("\(e)") }
        }
        // The sampler itself clamps rather than trapping.
        let curve = NotabilityNote.Curve(points: [.init(x: 0, y: 0), .init(x: 3e38, y: 0), .init(x: -3e38, y: 0),
                                                  .init(x: 1, y: 0)],
                                         fractionalWidths: [1, 1], width: 1, color: .black, style: 3)
        XCTAssertLessThanOrEqual(BezierToBSpline.samples(of: curve).count, 1 + BezierToBSpline.maxSamplesPerSegment)

        let path = tmp.appendingPathComponent("bad.note")
        try data.write(to: path)
        let identity = try NativeIdentity.generate(.postQuantum)
        let vault = try Vault.create(at: tmp.appendingPathComponent("H.inkvault"), recipients: [identity.recipient],
                                     identities: [identity])
        var clock = HybridClock()
        let r = try NotabilityImporter.import(paths: [path], into: vault, device: DeviceID("0a0b0c0d")!, clock: &clock)
        XCTAssertEqual(r.failed, 1)
    }

    func testPaperStyles() {
        let w = 716.8
        func style(_ s: String?, _ legacy: Int? = nil) -> (PaperKind, Double?) {
            NotabilityNote.paperStyle(lineStyle2: s, lineStyle: legacy, width: w, size: "letter")
        }
        XCTAssertEqual(style("No Lines").0, .blank)
        XCTAssertEqual(style("Dots:0.5").0, .dot)
        XCTAssertEqual(style("Dots:0.5").1 ?? 0, 18.8, accuracy: 1e-9)
        XCTAssertEqual(style("Lines:0.5").0, .ruled)
        XCTAssertEqual(style("Dots:false:true:0.25").1 ?? 0, 0.25 * w / 8.5, accuracy: 1e-9)
        XCTAssertEqual(style("Grid:false:true:0.25").0, .grid)
        XCTAssertEqual(style(nil, 9).0, .dot)
        XCTAssertEqual(style(nil, 1).0, .ruled)
        XCTAssertEqual(style(nil, 0).0, .blank)
        XCTAssertEqual(style("Something new:1").0, .blank)
    }

    func testHalfFloat() {
        XCTAssertEqual(NotabilityNote.half(0x3C00), 1)
        XCTAssertEqual(NotabilityNote.half(0xC000), -2)
        XCTAssertEqual(NotabilityNote.half(0x7C00), .infinity)
        XCTAssertEqual(NotabilityNote.half(0x0001), pow(2, -24))
        XCTAssertEqual(NotabilityNote.half(Float16Bits.encode(21.625)), 21.625)
    }

    func testInterpolationHitsSamples() {
        let q: [(x: Double, y: Double)] = [(0, 0), (1, 2), (3, 3), (4, 1), (6, 0)]
        let p = BezierToBSpline.interpolate(q)
        let pts = p.map { StrokePoint(x: $0.x, y: $0.y, w: 1, h: 1) }
        for (i, s) in q.enumerated() {
            let v = BSpline.location(of: pts, at: Double(i))
            XCTAssertEqual(v.x, s.x, accuracy: 1e-9)
            XCTAssertEqual(v.y, s.y, accuracy: 1e-9)
        }
    }

    func testInconsistentArraysFail() throws {
        // A package without Session.plist.
        let bad = ZipWriter.write([.init(path: "x/metadata.plist", data: SyntheticNote.metadata())])
        XCTAssertThrowsError(try NotabilityNote.parse(data: bad)) { e in
            guard case ImportError.notability = e else { return XCTFail("\(e)") }
        }
    }
}
