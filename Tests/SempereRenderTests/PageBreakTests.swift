import Foundation
import Sempere
@testable import SempereRender
import XCTest

/// Where pageless pages (and ink below finite pages) are cut into output
/// pages (format.md §5.4.3, "Exporting").
final class PageBreakTests: XCTestCase {
    private let pageless = PageSize(width: 200, height: 300, infinite: true, breakHeight: 300)

    /// A horizontal line of "handwriting" from `top` to `bottom` (control points; the outline adds half the nib).
    private func line(_ top: Double, _ bottom: Double, width: Double = 2) -> Stroke {
        T.stroke([T.pt(20, top, w: width), T.pt(100, (top + bottom) / 2, w: width), T.pt(180, bottom, w: width)],
                 width: width)
    }

    private func prepared(_ strokes: [Stroke], size: PageSize? = nil, paper: Paper = .ruled,
                          breaks: PageBreaks = .gaps) throws -> PreparedPage {
        try PreparedPage(page: Page(order: "a", strokes: strokes), meta: T.meta(paper: paper, size: size ?? pageless),
                         options: RenderOptions(breaks: breaks))
    }

    /// Strokes drawn on an output page (by their command count).
    private func drawn(_ p: PreparedPage, _ chunk: PageChunk) -> Int { p.layers(for: chunk).strokes.count }

    func testCutMovesUpToTheTopOfALineItWouldCross() throws {
        let a = line(20, 200), b = line(260, 340), c = line(400, 450)
        let p = try prepared([a, b, c])
        let bTop = p.strokes[1].minY
        XCTAssertEqual(p.chunks.count, 2)
        XCTAssertEqual(p.chunks[0].contentEnd, bTop)
        XCTAssertTrue(p.chunks[0].endsAtGap)
        XCTAssertEqual(p.chunks[1].yOffset, bTop)
        XCTAssertTrue(p.chunks[1].startsAtGap)
        // Every output page has the sheet's size; paper covers it all.
        for chunk in p.chunks { XCTAssertEqual(chunk.height, 300) }
        // Line b is only on the second page, unclipped.
        XCTAssertEqual(drawn(p, p.chunks[0]), 1)
        XCTAssertEqual(drawn(p, p.chunks[1]), 2)
    }

    func testCutStaysWhenNoGapInTheLastQuarter() throws {
        // One block of ink from 100 to 400: its top is above 3/4 of the sheet.
        let p = try prepared([line(100, 250), line(240, 400)])
        XCTAssertEqual(p.chunks[0].contentEnd, 300)
        XCTAssertFalse(p.chunks[0].endsAtGap)
        XCTAssertEqual(p.chunks[1].yOffset, 300)
        // Strokes crossing the cut are drawn (clipped) on both pages.
        XCTAssertEqual(drawn(p, p.chunks[0]), 2)
        XCTAssertEqual(drawn(p, p.chunks[1]), 1)
    }

    func testCutAtTheSheetWhenNoInkCrossesIt() throws {
        let p = try prepared([line(20, 200), line(320, 400)])
        XCTAssertEqual(p.chunks[0].contentEnd, 300)
        XCTAssertTrue(p.chunks[0].endsAtGap)
        XCTAssertEqual(p.chunks.map(\.yOffset), [0, 300])
    }

    func testFixedBreaksAndCornellCutAtEverySheet() throws {
        let strokes = [line(20, 200), line(260, 340), line(400, 450)]
        for p in [try prepared(strokes, breaks: .fixed), try prepared(strokes, paper: Paper(kind: .cornell))] {
            XCTAssertEqual(p.chunks.map(\.yOffset), [0, 300])
            XCTAssertEqual(p.chunks.map(\.contentEnd), [300, 600])
            XCTAssertFalse(p.chunks.contains(where: \.endsAtGap))
        }
    }

    func testFinitePageKeepsItsHeightAndOverflowPagesHoldInk() throws {
        let size = PageSize(width: 200, height: 300)
        // A line crossing the bottom edge (centre above it) is clipped, no extra page.
        let crossing = try prepared([line(250, 320)], size: size)
        XCTAssertEqual(crossing.chunks.count, 1)
        XCTAssertEqual(crossing.extent, 300)
        // Ink centred below the page: one more page of the same size, from the page's bottom.
        let below = try prepared([line(20, 100), line(1000, 1050)], size: size)
        XCTAssertEqual(below.chunks.count, 2)
        XCTAssertEqual(below.chunks[0].yOffset, 0)
        XCTAssertEqual(below.chunks[0].contentEnd, 300)
        XCTAssertEqual(below.chunks[1].height, 300)
        XCTAssertEqual(drawn(below, below.chunks[1]), 1)
    }

    /// Property: whatever the ink, output pages are contiguous, sheet-sized,
    /// advance by at least 3/4 of a sheet, cover the extent, and every
    /// stroke is drawn on at least one of them.
    func testRandomInkIsCoveredContiguously() throws {
        var seeded = Seeded(seed: 42)
        for _ in 0..<60 {
            var strokes: [Stroke] = []
            for _ in 0..<Int.random(in: 1...40, using: &seeded) {
                let top = Double.random(in: 0...3000, using: &seeded)
                strokes.append(line(top, top + Double.random(in: 1...120, using: &seeded),
                                    width: Double.random(in: 1...12, using: &seeded)))
            }
            let p = try prepared(strokes)
            var t = 0.0
            for (i, c) in p.chunks.enumerated() {
                XCTAssertEqual(c.yOffset, t)
                XCTAssertEqual(c.height, 300, accuracy: 1e-9)
                XCTAssertLessThanOrEqual(c.contentEnd, c.yEnd)
                if i < p.chunks.count - 1 { XCTAssertGreaterThanOrEqual(c.contentEnd - c.yOffset, 225) }
                t = c.contentEnd
            }
            XCTAssertGreaterThanOrEqual(p.chunks.last?.yEnd ?? 0, p.extent)
            var seen = 0
            for c in p.chunks { seen += drawn(p, c) }
            XCTAssertGreaterThanOrEqual(seen, strokes.count)
            for s in p.strokes {
                XCTAssertTrue(p.chunks.contains { s.maxY > $0.yOffset && s.minY < $0.contentEnd
                    || (s.minY == s.maxY && s.minY >= $0.yOffset && s.minY <= $0.contentEnd) })
            }
        }
    }

    func testPDFAndPNGFollowTheCuts() throws {
        let note = T.note(pages: [[line(20, 200), line(260, 340), line(400, 450)]], meta: T.meta(size: pageless))
        let pdf = try PDFWriter.render(note: note, options: RenderOptions(compress: false))
        XCTAssertEqual(T.count(pdf, "/Type /Page /"), 2)
        XCTAssertEqual(try PNGWriter.render(note: note, png: PNGOptions(scale: 0.5)).count, 2)
    }
}

/// Small deterministic generator for the property test.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
