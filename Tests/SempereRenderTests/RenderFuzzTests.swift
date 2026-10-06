import Foundation
import FuzzSupport
import Sempere
import XCTest

@testable import SempereRender

/// Seeded mutation fuzzing of the renderers with note state decoded from
/// untrusted JSON: PNG (with a pixel cap), SVG and PDF must either render or
/// throw `RenderError`, within bounded time and memory, never trap.
final class RenderFuzzTests: XCTestCase {
    static let png = PNGOptions(scale: 0.5, maxPixels: 1_000_000)

    static func typed(_ body: () throws -> Void) -> String? {
        do { try body() } catch is DecodingError {
        } catch is RenderError {
        } catch { return "untyped error \(type(of: error)): \(error)" }
        return nil
    }

    static func render(_ note: NoteState) throws {
        _ = try PNGWriter.render(note: note, png: png)
        _ = try SVGWriter.render(note: note)
        _ = try PDFWriter.render(note: note)
    }

    static func seeds() throws -> [Data] {
        var states = [try T.loadSampleNote()]
        let tools = InkTool.allCases
        var strokes: [Stroke] = []
        for (i, tool) in tools.enumerated() {
            var pts: [StrokePoint] = []
            for j in 0..<6 {
                let x = Double(10 + 20 * i + 3 * j), y = Double(10 + 7 * j)
                pts.append(T.pt(x, y, w: 1 + Double(j % 3), o: 0.8))
            }
            let xf: Transform? = i % 3 == 0 ? Transform(a: 1.5, b: 0.2, c: 0, d: 1, tx: 4, ty: 9) : nil
            strokes.append(T.stroke(pts, tool: tool, width: 3, transform: xf))
        }
        for paper in [Paper(kind: .ruled), Paper(kind: .grid, spacing: 10), Paper(kind: .dot, spacing: 5), .blank] {
            states.append(T.note(pages: [strokes, [strokes[0]]], meta: T.meta(paper: paper)))
        }
        states.append(T.note(pages: [strokes], meta: T.meta(size: PageSize(width: 300, height: 400, infinite: true,
                                                                             breakHeight: 150))))
        return try states.map { try InkJSON.encoder().encode($0) }
    }

    /// Hostile but well-formed geometry: long segments, many points, extreme
    /// transforms and widths, dense paper on tall infinite pages.
    static func generate(_ rng: inout FuzzRNG) -> Data {
        let big = [0.0, 1, 72, 1000, 199_999, 200_001, 1e9, 1e300, -1e300, 5e-324]
        var strokes: [Stroke] = []
        for _ in 0..<(1 + rng.below(6)) {
            let n = rng.pick([1, 2, 3, 50, 2000])
            let pts = (0..<n).map { _ in
                StrokePoint(x: rng.pick(big) * (rng.oneIn(2) ? 1 : -1), y: rng.pick(big), t: 0, w: rng.pick(big),
                            h: rng.pick(big), o: rng.pick([0, 0.5, 1, 1e300, -1e300]), f: 0)
            }
            let s = rng.pick(big)
            let xf = rng.oneIn(3) ? Transform(a: s, b: rng.pick(big), c: rng.pick(big), d: s, tx: rng.pick(big), ty: rng.pick(big))
                : nil
            strokes.append(T.stroke(pts, tool: rng.pick(InkTool.allCases), width: rng.pick(big), transform: xf))
        }
        let size = PageSize(width: rng.pick([1, 300, 199_999, 1e9]), height: rng.pick([0, 400, 199_999, 1e9]),
                            infinite: rng.oneIn(2), breakHeight: rng.oneIn(2) ? rng.pick([0, 72, 1, 1e300]) : nil)
        let paper = Paper(kind: rng.pick(PaperKind.allCases), spacing: rng.pick([0, 4, 4.0001, 1e-300, 24, 1e300]))
        let note = T.note(pages: [strokes], meta: T.meta(paper: paper, size: size))
        return (try? InkJSON.encoder().encode(note)) ?? Data()
    }

    func testFuzzRenderers() throws {
        let report = Fuzz.run("render", seeds: try Self.seeds(), quick: 400, text: true, maxSize: 512 << 10,
                              generate: Self.generate) { input in
            Self.typed {
                let note = try InkJSON.decoder().decode(NoteState.self, from: input)
                try Self.render(note)
            }
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }
}

/// Seeded mutation fuzzing of the image decoders and of image items in the
/// three writers (docs/attachments.md §14, C1): every input decodes, strips
/// or exports, or fails with `ImageError`; stripping metadata never changes
/// the decoded pixels; nothing traps, hangs or allocates past the budget.
final class ImageFuzzTests: XCTestCase {
    /// A small pixel cap keeps each case's memory far under the harness budget.
    static let maxPixels = 4_000_000

    static func typed(_ body: () throws -> String?) -> String? {
        do { return try body() } catch is ImageError {
        } catch { return "untyped error \(type(of: error)): \(error)" }
        return nil
    }

    static func fixtures(_ ext: String) throws -> [Data] {
        let dir = try T.fixtureURL("images")
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(ext) }.sorted()
            .map { try Data(contentsOf: dir.appendingPathComponent($0)) }
    }

    /// Headers that claim more than their bytes hold, and short hostile streams.
    static func generateJPEG(_ rng: inout FuzzRNG) -> Data {
        let w = rng.pick([1, 8, 9, 65535, 30000]), h = rng.pick([1, 8, 16, 65535, 30000])
        let n = rng.pick([1, 3, 4])
        var d: [UInt8] = [0xFF, 0xD8]
        if rng.oneIn(2) { d += [0xFF, 0xDD, 0, 4, 0, UInt8(rng.below(4))] }
        d += [0xFF, rng.pick([0xC0, 0xC1, 0xC2]), 0, UInt8(8 + 3 * n), 8, UInt8(h >> 8), UInt8(h & 255),
              UInt8(w >> 8), UInt8(w & 255), UInt8(n)]
        for i in 0..<n { d += [UInt8(i + 1), UInt8(rng.pick([0x11, 0x22, 0x41, 0x14, 0x44])), 0] }
        d += [0xFF, 0xDB, 0, 67, 0] + [UInt8](repeating: UInt8(1 + rng.below(255)), count: 64)
        d += [0xFF, 0xC4, 0, 20, UInt8(rng.pick([0x00, 0x10]))] + [1] + [UInt8](repeating: 0, count: 15) + [0]
        d += [0xFF, 0xDA, 0, UInt8(6 + 2 * n), UInt8(n)]
        for i in 0..<n { d += [UInt8(i + 1), 0] }
        d += [UInt8(rng.below(64)), UInt8(rng.below(64)), UInt8(rng.below(256))]
        d += (0..<rng.below(64)).map { _ in UInt8(rng.below(256)) }
        if rng.oneIn(2) { d += [0xFF, 0xD9] }
        return Data(d)
    }

    func testFuzzJPEG() throws {
        let report = Fuzz.run("jpeg", seeds: try Self.fixtures(".jpg"), quick: 300, maxSize: 64 << 10,
                              generate: Self.generateJPEG) { input in
            Self.typed {
                _ = try? JPEG.info(input)
                let full = try? JPEG.decode(input, maxPixels: Self.maxPixels)
                for s in [2, 8] { _ = try? JPEG.decode(input, scale: s, maxPixels: Self.maxPixels) }
                let stripped = try JPEG.stripMetadata(input)
                if let full {
                    let again = try JPEG.decode(stripped, maxPixels: Self.maxPixels)
                    if again != full { return "stripping metadata changed the decoded image" }
                }
                return nil
            }
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }

    func testFuzzPNG() throws {
        let report = Fuzz.run("png", seeds: try Self.fixtures(".png"), quick: 400, maxSize: 64 << 10) { input in
            Self.typed {
                let full = try? PNG.decode(input, maxPixels: Self.maxPixels)
                let stripped = try PNG.stripMetadata(input)
                if let full, try PNG.decode(stripped, maxPixels: Self.maxPixels) != full {
                    return "stripping metadata changed the decoded image"
                }
                return nil
            }
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }

    /// One mutated image blob placed by mutated items in all three writers.
    func testFuzzImageExport() throws {
        let seeds = try Array(Self.fixtures(".jpg").prefix(4)) + Array(Self.fixtures(".png").prefix(6))
        let report = Fuzz.run("image-export", seeds: seeds, quick: 120, maxSize: 64 << 10) { input in
            var rng = FuzzRNG(seed: UInt64(input.count) &* 0x9E37_79B9)
            let ref = BlobRef(content: input, type: rng.pick(["image/jpeg", "image/png", "image/heic", "image/gif"]))
            // Extreme magnification, slivers and turns. (Frames as tall as the
            // 200 000 pt extent limit are legal but make hundreds of output
            // images; UntrustedRenderTests covers that extent with strokes.)
            let frames = [Rect(x: 10, y: 10, w: 100, h: 80), Rect(x: -50, y: 290, w: 1e-3, h: 400),
                          Rect(x: 0, y: 0, w: 2_000, h: 3)]
            let items = (0..<3).map { _ in
                Item(kind: .image, layer: ItemLayer(rawValue: rng.pick([0, 100, 7])), frame: rng.pick(frames),
                     rotation: rng.pick([nil, 0, 45, 1e9, -0.001]), z: "a", blob: ref,
                     pixelSize: Size(w: 1, h: 1), orientation: rng.pick([nil, 1, 5, 8, 9]),
                     crop: rng.pick([nil, Rect(x: 1, y: 1, w: 2, h: 2), Rect(x: -1e9, y: 0, w: 1e-3, h: 1e12)]))
            }
            let note = NoteState(meta: NoteMeta(created: Date(timeIntervalSince1970: 0),
                                                pageSize: PageSize(width: 300, height: 300, infinite: rng.oneIn(2))),
                                 pages: [Page(order: "a", items: items)])
            let options = RenderOptions(blobs: MemoryBlobSource([input]), maxImagePixels: Self.maxPixels)
            do {
                var r = RenderReport()
                _ = try PNGWriter.render(note: note, options: options, png: PNGOptions(scale: 0.5, maxPixels: 1_000_000), report: &r)
                _ = try SVGWriter.export(note: note, options: options, report: &r)
                _ = try PDFWriter.render(note: note, options: options, report: &r)
            } catch is RenderError {
            } catch { return "untyped error \(type(of: error)): \(error)" }
            return nil
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }
}
