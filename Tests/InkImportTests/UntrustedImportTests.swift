import Age
import Foundation
import InkRender
import InkVault
import XCTest

@testable import InkImport

/// Regression tests for corrupt or hostile Notability packages (see
/// `ImportFuzzTests`): each fails with `ImportError` or imports cleanly.
final class UntrustedImportTests: XCTestCase {
    func curve(width: Float, fw: [Float] = [1, 1]) -> SyntheticNote.CurveSpec {
        .init(points: [(10, 10), (20, 10), (30, 10), (40, 10)], fw: fw, width: width, rgba: [0, 0, 0, 255], style: 3)
    }

    /// Non-finite or absurd widths parsed fine and then failed much later as
    /// an `EncodingError` (JSON cannot hold NaN or infinity) or produced
    /// infinite geometry.
    func testNonFiniteOrHugeWidthsAreRejected() throws {
        for w: Float in [.nan, .infinity, -.infinity, 3e38] {
            XCTAssertThrowsError(try NotabilityNote.parse(data: SyntheticNote.package(curves: [curve(width: w)])), "\(w)") { e in
                XCTAssertTrue(e is ImportError, "\(e)")
            }
        }
        // Fractional widths: non-finite ones fall back to 1; huge products are rejected.
        let note = try NotabilityNote.parse(data: SyntheticNote.package(curves: [curve(width: 2, fw: [.nan, .infinity])]))
        let state = NotabilityImporter.convert(note)
        XCTAssertNoThrow(try InkJSON.encoder().encode(NotabilityImporter.ops(for: state)))
        XCTAssertThrowsError(try NotabilityNote.parse(data: SyntheticNote.package(curves: [curve(width: 2, fw: [3e38, 1])])))
    }

    /// A paper pitch that overflows to infinity, a NaN recognition origin and
    /// a page key near `Int.max` used to reach the vault as NaN / infinity
    /// (an `EncodingError` at write time) or as words 10¹⁸ pages down.
    func testPaperPitchAndRecognitionOriginAreSanitised() throws {
        let (kind, spacing) = NotabilityNote.paperStyle(lineStyle2: "Dots:1e308", lineStyle: nil, width: 716.8, size: nil)
        XCTAssertEqual(kind, .dot)
        XCTAssertNil(spacing)
        XCTAssertNil(NotabilityNote.paperStyle(lineStyle2: "Lines:a:b:1e306", lineStyle: nil, width: 716.8, size: nil).1)

        let page = BValue.dict([("text", .string("hi")), ("pageContentOrigin", .array([.real(.nan), .real(.infinity)])),
                                ("characterRects", .data(Data([0, 0x3C, 0, 0x3C, 0, 0x3C, 0, 0x3C])))])
        let index = BPlist.encode(.dict([("pages", .dict([("1", page), ("9223372036854775807", page)]))]))
        let rec = try NotabilityNote.parseRecognition(index)
        XCTAssertEqual(Array(rec.keys), [1])
        XCTAssertEqual(rec[1]?.origin, NotabilityNote.Point(x: 0, y: 0))
        var note = try NotabilityNote.parse(data: SyntheticNote.package())
        note.recognition = rec
        XCTAssertNoThrow(try InkJSON.encoder().encode(NotabilityImporter.ops(for: NotabilityImporter.convert(note))))
    }

    /// A package directory from a shared folder: a symlink to a file outside
    /// it is not followed, and a file over the size limit is refused before
    /// it is read into memory.
    func testPackageDirectoryIgnoresSymlinksAndCapsReads() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("untrusted-pkg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pkg = tmp.appendingPathComponent("Shared.note")
        try SyntheticNote.writeDirectory(pkg)
        let secret = tmp.appendingPathComponent("secret.txt")
        try Data("private".utf8).write(to: secret)
        let link = pkg.appendingPathComponent("Synthetic note/HandwritingIndex/leak.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let package = try NotePackage(directory: pkg)
        XCTAssertFalse(package.paths.contains { $0.hasSuffix("leak.plist") }, "\(package.paths)")
        XCTAssertNoThrow(try NotabilityNote.parse(package: package))

        let big = tmp.appendingPathComponent("big.bin")
        try Data(count: 4097).write(to: big)
        XCTAssertThrowsError(try NotePackage.readFile(big, maxSize: 4096)) { e in XCTAssertTrue(e is ImportError) }
        XCTAssertEqual(try NotePackage.readFile(big, maxSize: 4097).count, 4097)
    }

    /// A NaN or far-future creation date became the delta's `wall`, which was
    /// written as "" or a 7-digit year that no reader could decode. Such dates
    /// are dropped (the import falls back to another date, or now).
    func testUnwritableDatesAreDropped() throws {
        for t in [Double.nan, .infinity, 1e300, -1e18] {
            var b = KeyedArchiveBuilder()
            let d = b.dict([("noteName", b.string("n")), ("noteCreationDateKey", .date(Date(timeIntervalSinceReferenceDate: t))),
                            ("uuidKey", b.string(SyntheticNote.uuid))])
            var files = SyntheticNote.files()
            files = files.map { $0.0.hasSuffix("metadata.plist") ? ($0.0, b.archive(top: [("root", d)])) : $0 }
            let zip = ZipWriter.write(files.map { .init(path: $0.0, data: $0.1) })
            let note = try NotabilityNote.parse(data: zip)
            // Session.plist's creation date is the fallback.
            XCTAssertEqual(note.metadata.created, SyntheticNote.created, "\(t)")
        }
    }

    // MARK: Full-backup readers (merged from main, #31)

    /// An `.ntb` bundle whose creation time is `Int64.max` milliseconds:
    /// `NotabilityImporter.plan` turned it back into milliseconds with
    /// `Int64(Double)`, which traps at 2^63. Such dates are now dropped, as
    /// for a `.note`, and the bundle imports.
    func testBundleWithAbsurdCreationTimeImportsWithoutTrapping() throws {
        for ms in [Int64.max, Int64.min, 253_402_300_800_000] {
            let bundle = SyntheticBundle.noteBundle(strokes: [], createdMs: ms)
            let note = try NotabilityBundle.parse(bundle: bundle)
            XCTAssertNil(note.metadata.created, "\(ms)")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("untrusted-ntb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("x.ntb")
        try SyntheticBundle.package(SyntheticBundle.noteBundle(strokes: [], createdMs: .max)).write(to: file)
        let identity = X25519Identity()
        let vault = try Vault.create(at: tmp.appendingPathComponent("V.inkvault"), recipients: [identity.recipient],
                                     identities: [identity])
        var clock = HybridClock()
        let report = try NotabilityImporter.import(paths: [file], into: vault, device: DeviceID("0a0b0c0d")!, clock: &clock)
        XCTAssertEqual(report.notes.map(\.status), [.ok])
    }

    /// A `.note` rejects widths beyond ±10⁶; an `.ntb` stroke with a width of
    /// 3·10³⁸ was imported as it was (one fractional width away from an
    /// infinite point width). It is now an unsupported stroke.
    func testBundleWidthsAreBoundedLikeNotes() throws {
        var s = SyntheticBundle.strokesMatchingSyntheticNote()
        s[0].width = 3e38
        let note = try NotabilityBundle.parse(bundle: SyntheticBundle.noteBundle(strokes: s))
        XCTAssertEqual(note.unsupportedStrokes, 1)
        XCTAssertEqual(note.curves.count, 1)
        XCTAssertNoThrow(try InkJSON.encoder().encode(NotabilityImporter.ops(for: NotabilityImporter.convert(note))))
    }

    /// A bundle of 2 000 records all referencing one document record whose
    /// title is a 256 KiB string (FlatBuffers references can be shared):
    /// every record decoded the title again, 512 MB of work from 270 KB.
    /// Titles now count against the decode budget like geometry does.
    func testSharedBundleTitleIsCharged() throws {
        let bundle = Self.sharedTitleBundle(records: 2000, titleBytes: 256 << 10)
        XCTAssertThrowsError(try NotabilityBundle.parse(bundle: bundle)) { e in XCTAssertTrue(e is ImportError, "\(e)") }
        // The same layout with a few records is an ordinary bundle.
        XCTAssertEqual(try NotabilityBundle.parse(bundle: Self.sharedTitleBundle(records: 3, titleBytes: 100)).metadata.name,
                       String(repeating: "t", count: 100))
    }

    /// A hand-built FlatBuffers bundle: a record vector of `records`
    /// references to one document record with a `titleBytes`-long title.
    static func sharedTitleBundle(records: Int, titleBytes: Int) -> Data {
        var b = [UInt8](repeating: 0, count: 4)
        func u16(_ v: Int) { b += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: Int) { b += (0..<4).map { UInt8(v >> (8 * $0) & 0xFF) } }
        func patch(_ at: Int, _ v: Int) { for k in 0..<4 { b[at + k] = UInt8(v >> (8 * k) & 0xFF) } }
        // vtables: root (field 6 at 4), record (type at 4, payload at 8), one-field tables (field 0 at 4).
        let vtRoot = b.count; u16(18); u16(8); for f in 0..<7 { u16(f == 6 ? 4 : 0) }
        let vtRecord = b.count; u16(16); u16(12); for f in 0..<6 { u16(f == 4 ? 4 : f == 5 ? 8 : 0) }
        let vtOne = b.count; u16(6); u16(8); u16(4)
        let root = b.count; u32(root - vtRoot); let rootRef = b.count; u32(0)
        let vector = b.count; u32(records)
        let refs = b.count; for _ in 0..<records { u32(0) }
        let record = b.count; u32(record - vtRecord); b += [1, 0, 0, 0]; let payloadRef = b.count; u32(0)
        let doc = b.count; u32(doc - vtOne); let titleTableRef = b.count; u32(0)
        let titleTable = b.count; u32(titleTable - vtOne); let stringRef = b.count; u32(0)
        let string = b.count; u32(titleBytes); b += [UInt8](repeating: 0x74, count: titleBytes)
        patch(0, root); patch(rootRef, vector - rootRef)
        for i in 0..<records { patch(refs + 4 * i, record - (refs + 4 * i)) }
        patch(payloadRef, doc - payloadRef); patch(titleTableRef, titleTable - titleTableRef)
        patch(stringRef, string - stringRef)
        return Data(b)
    }
}
