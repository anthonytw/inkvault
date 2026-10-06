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
        // A finite page a fraction of a point tall, ink far below it (pages below a page, §5.4.3).
        states.append(T.note(pages: [strokes + [T.stroke([T.pt(20, 150_000, w: 2), T.pt(180, 150_010, w: 2)], width: 2)]],
                             meta: T.meta(size: PageSize(width: 300, height: 0.001))))
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
        let size = PageSize(width: rng.pick([1, 300, 199_999, 1e9]), height: rng.pick([0, 400, 199_999, 1e9, 1, 0.001, 1e-300]),
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
