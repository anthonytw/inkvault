import Foundation
import InkVault
import XCTest

@testable import InkRender

/// Regression tests for hostile geometry (see `RenderFuzzTests`).
final class UntrustedRenderTests: XCTestCase {
    /// A zig-zag of 400 control points 199 000 pt apart (12 KB of JSON) used
    /// to subdivide every segment 4096 times: 1.6 M samples, 6.5 M outline
    /// points, about 250 MB and seconds of work, growing without bound with
    /// the input. The per-stroke budget keeps it near 64 samples per point.
    func testLongSegmentsDoNotAmplify() throws {
        for n in [2, 10, 400] {
            let pts = (0..<n).map { i in T.pt(i % 2 == 0 ? 0 : 199_000, i % 4 < 2 ? 0 : 199_000) }
            let s = T.stroke(pts)
            let budget = RenderLimits.samplesPerPoint * n + RenderLimits.baseSamples
            XCTAssertLessThanOrEqual(StrokeSampler.samples(for: s).count, budget + 1, "n=\(n)")
            let points = StrokeOutline.commands(for: s).reduce(0) { $0 + $1.pointCount }
            XCTAssertLessThanOrEqual(points, 5 * (budget + 1), "n=\(n)")
        }
    }

    /// Ordinary handwriting is still sampled at full density.
    func testShortSegmentsKeepFullDensity() {
        let pts = (0..<50).map { i in T.pt(Double(i) * 3, 100 + 20 * sin(Double(i) / 3)) }
        XCTAssertGreaterThan(StrokeSampler.samples(for: T.stroke(pts)).count, 100)
    }

    /// A page whose outline would exceed the cap throws a typed error instead
    /// of allocating it (the cap is lowered here; the real one is 40 M points).
    func testOutlineCapThrows() throws {
        let strokes = (0..<20).map { k in T.stroke((0..<30).map { i in T.pt(Double(i) * 5, Double(k) * 10) }) }
        let note = T.note(pages: [strokes])
        XCTAssertNoThrow(try PreparedPage(page: note.pages[0], meta: note.meta, options: RenderOptions()))
        XCTAssertThrowsError(try PreparedPage(page: note.pages[0], meta: note.meta, options: RenderOptions(),
                                              maxOutlinePoints: 1000)) { e in
            XCTAssertEqual(e as? RenderError, .tooComplex)
        }
    }
}
