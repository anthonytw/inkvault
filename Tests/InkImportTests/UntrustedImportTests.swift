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
}
