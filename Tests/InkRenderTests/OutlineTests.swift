import XCTest
import InkVault
@testable import InkRender

final class OutlineTests: XCTestCase {
    private func polygons(_ cmds: [DrawCommand]) -> [Subpath] {
        cmds.flatMap { c -> [Subpath] in
            if case let .path(s) = c.primitive { return s }
            return []
        }
    }

    func testConstantWidthRibbonHasThatDiameter() {
        let s = T.stroke([T.pt(0, 50, w: 4), T.pt(100, 50, w: 4)])
        let polys = polygons(StrokeOutline.commands(for: s))
        let ys = polys.flatMap(\.points).map(\.y)
        XCTAssertEqual((ys.max() ?? 0) - (ys.min() ?? 0), 4, accuracy: 0.05)
        // Round caps extend half a width past the ends.
        let xs = polys.flatMap(\.points).map(\.x)
        XCTAssertEqual(xs.min() ?? 0, -2, accuracy: 0.05)
        XCTAssertEqual(xs.max() ?? 0, 102, accuracy: 0.05)
    }

    func testOnePointStrokeIsDotOfExpectedDiameter() {
        let s = T.stroke([T.pt(20, 30, w: 6)])
        let polys = polygons(StrokeOutline.commands(for: s))
        XCTAssertEqual(polys.count, 1)
        let xs = polys[0].points.map(\.x), ys = polys[0].points.map(\.y)
        XCTAssertEqual((xs.max() ?? 0) - (xs.min() ?? 0), 6, accuracy: 0.05)
        XCTAssertEqual((ys.max() ?? 0) - (ys.min() ?? 0), 6, accuracy: 0.05)
        // Circle area ~ pi r^2.
        XCTAssertEqual(polys[0].signedArea, Double.pi * 9, accuracy: 0.3)
    }

    func testPolygonsHavePositiveAreaAndFiniteCoordinates() {
        for tool in InkTool.allCases {
            let pts = (0..<9).map { T.pt(Double($0) * 9, 30 * sin(Double($0) * 0.9), w: 1 + Double($0 % 3)) }
            let cmds = StrokeOutline.commands(for: T.stroke(pts, tool: tool, width: 3))
            XCTAssertFalse(cmds.isEmpty, "\(tool)")
            for c in cmds {
                guard case let .path(subs) = c.primitive else { return XCTFail() }
                for sp in subs {
                    XCTAssertTrue(sp.points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
                    if c.fill != nil {
                        XCTAssertGreaterThan(sp.signedArea, 0, "\(tool)")
                    }
                }
            }
        }
    }

    func testOpacityMultiplies() {
        let col = Color(r: 10, g: 20, b: 30, a: 128)
        let pts = [T.pt(0, 0, o: 0.5), T.pt(10, 0, o: 0.5), T.pt(20, 0, o: 0.5)]
        let pen = StrokeOutline.commands(for: T.stroke(pts, tool: .pen, color: col))
        XCTAssertEqual(pen[0].fill?.alpha ?? 0, 128.0 / 255 * 0.5, accuracy: 1e-9)
        let marker = StrokeOutline.commands(for: T.stroke(pts, tool: .marker, width: 8, color: col))
        XCTAssertEqual(marker[0].stroke?.alpha ?? 0, 128.0 / 255 * 0.5 * 0.5, accuracy: 1e-9)
        XCTAssertEqual(marker[0].lineWidth, 8, accuracy: 1e-9)
        let pencil = StrokeOutline.commands(for: T.stroke(pts, tool: .pencil, color: col))
        XCTAssertLessThan(pencil[0].fill?.alpha ?? 1, pen[0].fill?.alpha ?? 0)
    }

    func testMonolineIgnoresSampleWidth() {
        let pts = [T.pt(0, 0, w: 9), T.pt(30, 0, w: 1)]
        let c = StrokeOutline.commands(for: T.stroke(pts, tool: .monoline, width: 2.5))
        XCTAssertEqual(c[0].lineWidth, 2.5, accuracy: 1e-9)
        XCTAssertNil(c[0].fill)
        XCTAssertNotNil(c[0].stroke)
    }

    func testPaperCommands() {
        let ruled = PaperRenderer.commands(paper: .ruled, width: 100, height: 100)
        XCTAssertEqual(ruled.count, 1 + 4)   // background + lines at 24, 48, 72, 96
        let grid = PaperRenderer.commands(paper: Paper(kind: .grid, spacing: 25), width: 100, height: 100)
        XCTAssertEqual(grid.count, 1 + 3 + 3)
        let dot = PaperRenderer.commands(paper: Paper(kind: .dot, spacing: 25), width: 100, height: 100)
        XCTAssertEqual(dot.count, 1 + 9)
        XCTAssertEqual(PaperRenderer.commands(paper: .blank, width: 10, height: 10).count, 1)
        // Chunk offsets keep ruling continuous: global y=24k.
        let chunk = PaperRenderer.commands(paper: .ruled, width: 100, height: 100, yOffset: 100)
        guard case let .line(a, _) = chunk[1].primitive else { return XCTFail() }
        XCTAssertEqual(a.y, 120 - 100, accuracy: 1e-9)
    }
}
