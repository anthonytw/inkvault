import Foundation
import Sempere
import XCTest

@testable import SempereRender

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

    /// 470 bytes of JSON (found by the long fuzz run): an infinite page
    /// 199 999 pt tall with 4 pt dot paper is 516 bands of ~7 000 dots, 3.7 M
    /// paper commands; PNG export took 138 s and SVG 44 s. Past the per-page
    /// budget the page renders on its plain background.
    func testTallDensePaperIsBounded() throws {
        let size = PageSize(width: 300, height: 199_999, infinite: true)
        let note = T.note(pages: [[T.stroke([T.pt(72, 0, w: 199_999)], tool: .marker, width: 72)]],
                          meta: T.meta(paper: Paper(kind: .dot, spacing: 4), size: size))
        let prepared = try PreparedPage(page: note.pages[0], meta: note.meta, options: RenderOptions())
        XCTAssertEqual(prepared.drawnPaper.kind, .blank)
        XCTAssertEqual(prepared.drawnPaper.background, note.meta.paper.background)
        XCTAssertLessThan(prepared.fullPagePaper().count, 1000)
        let t0 = Date()
        _ = try SVGWriter.render(note: note)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 20)

        // Ordinary pages keep their ruling: 25 letter pages of 4 pt dots fit.
        let normal = T.meta(paper: Paper(kind: .dot, spacing: 4), size: PageSize(width: 612, height: 792 * 25, infinite: true,
                                                                                  breakHeight: 792))
        XCTAssertEqual(try PreparedPage(page: Page(order: "a"), meta: normal, options: RenderOptions()).drawnPaper.kind, .dot)
    }

    /// 510 bytes (found by the long fuzz run): a two-point pencil stroke whose
    /// nib grows to 199 999 pt on a 300 pt wide infinite page. Every outline
    /// polygon covered every one of the 260 bands, so each band rasterized all
    /// of them: over a minute. Nibs are now drawn at most 1 000 pt wide.
    func testHugeNibIsClampedNotRasterizedEverywhere() throws {
        let stroke = T.stroke([StrokePoint(x: -1, y: 1000, w: 0, h: 1000, o: 1e300),
                               StrokePoint(x: 199_999, y: 0, w: 199_999, h: 1000, o: 0.5)], tool: .pencil, width: 1)
        let note = T.note(pages: [[stroke]], meta: T.meta(paper: .blank, size: PageSize(width: 300, height: 400, infinite: true)))
        let prepared = try PreparedPage(page: note.pages[0], meta: note.meta, options: RenderOptions())
        XCTAssertLessThanOrEqual(prepared.extent, 1000 + RenderLimits.maxNibWidth)
        for c in prepared.allStrokeCommands() {
            guard case .path(let subs) = c.primitive else { continue }
            for sp in subs {
                let ys = sp.points.map(\.y)
                XCTAssertLessThanOrEqual((ys.max() ?? 0) - (ys.min() ?? 0), 2 * RenderLimits.maxNibWidth + 400)
            }
        }
        let t0 = Date()
        _ = try PNGWriter.render(note: note, png: PNGOptions(scale: 0.5, maxPixels: 1_000_000))
        _ = try PDFWriter.render(note: note)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 20)
        // A normal marker is unaffected.
        let marker = T.stroke([T.pt(10, 10, w: 30), T.pt(200, 10, w: 30)], tool: .marker, width: 30)
        let r = StrokeOutline.ribbon(StrokeSampler.samples(for: marker), fallbackWidth: 30)
        XCTAssertEqual(r.flatMap(\.points).map(\.y).max() ?? 0, 25, accuracy: 0.01)
    }
}
