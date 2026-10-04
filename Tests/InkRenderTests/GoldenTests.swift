import XCTest
import InkVault
@testable import InkRender

final class GoldenTests: XCTestCase {
    func testSamplePageOneMatchesGolden() throws {
        let note = try T.loadSampleNote()
        let svg = SVGWriter.render(page: note.pages[0], meta: note.meta)
        let url = T.fixtureDir.appendingPathComponent("sample-page-1.svg")
        if ProcessInfo.processInfo.environment["INKRENDER_UPDATE_GOLDEN"] == "1" {
            try Data(svg.utf8).write(to: url)
            return
        }
        let golden = try String(contentsOf: url, encoding: .utf8)
        if svg != golden {
            let a = svg.split(separator: "\n", omittingEmptySubsequences: false)
            let b = golden.split(separator: "\n", omittingEmptySubsequences: false)
            let firstDiff = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, b.count)
            XCTFail("""
                SVG differs from golden at line \(firstDiff + 1) (got \(a.count) lines, golden \(b.count)).
                Inspect, then regenerate with: INKRENDER_UPDATE_GOLDEN=1 swift test --filter GoldenTests
                """)
        }
        XCTAssertEqual(svg, golden)
    }

    func testSampleNoteRendersToPDFAndGridPage() throws {
        let note = try T.loadSampleNote()
        XCTAssertEqual(note.pages.count, 2)
        XCTAssertEqual(note.pages.reduce(0) { $0 + $1.strokes.count }, 20)
        // Page 2 is shown on grid paper (paper is per-note in the model).
        var grid = note.meta
        grid.paper = Paper(kind: .grid, spacing: 30)
        let svg = SVGWriter.render(page: note.pages[1], meta: grid)
        XCTAssertTrue(svg.contains("<line"))
        let pdf = try PDFWriter.render(note: note, options: RenderOptions())
        XCTAssertTrue(T.latin1(pdf).hasPrefix("%PDF-1.4"))
        if let dir = ProcessInfo.processInfo.environment["INKRENDER_WRITE_PDF"] {
            try pdf.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sample.pdf"))
        }
    }
}
