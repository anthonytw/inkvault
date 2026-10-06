import Foundation
import XCTest
@testable import Sempere
@testable import SempereRender

final class RecognitionImageTests: XCTestCase {
    private func stroke(_ tool: InkTool = .pen, color: Color = Color(r: 200, g: 0, b: 0), tx: Double = 0) -> Stroke {
        Stroke(ink: Ink(tool: tool, color: color, width: 3),
               points: (0..<20).map { StrokePoint(x: 100 + Double($0) * 5, y: 300 + sin(Double($0)) * 10, w: 3, h: 3) },
               transform: tx == 0 ? nil : Transform(a: 1, b: 0, c: 0, d: 1, tx: tx, ty: 0))
    }

    /// Width and height from the IHDR chunk.
    private func size(_ png: Data) -> (width: Int, height: Int) {
        let b = Array(png)
        func be(_ i: Int) -> Int { (Int(b[i]) << 24) | (Int(b[i + 1]) << 16) | (Int(b[i + 2]) << 8) | Int(b[i + 3]) }
        return (be(16), be(20))
    }

    func testRendersACroppedBlackOnWhitePNG() throws {
        let r = try XCTUnwrap(try RecognitionImage.render(strokes: [stroke()]))
        XCTAssertEqual(Array(r.png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        // Ink spans x 100...195, y about 290...310; the region adds the margin all round.
        XCTAssertEqual(r.region.x, 100 - 1.5 - RecognitionImage.margin, accuracy: 1)
        XCTAssertGreaterThan(r.region.w, 95 + 2 * RecognitionImage.margin - 5)
        XCTAssertLessThan(r.region.h, 80, "cropped to the ink, not the page")
        XCTAssertGreaterThan(size(r.png).width, 100)
    }

    func testTransformsMoveTheRegionAndMarkersAreLeftOut() throws {
        let moved = try XCTUnwrap(try RecognitionImage.render(strokes: [stroke(tx: 400)]))
        let plain = try XCTUnwrap(try RecognitionImage.render(strokes: [stroke()]))
        XCTAssertEqual(moved.region.x - plain.region.x, 400, accuracy: 0.01)
        // A marker is not drawn: with only markers there is nothing to read.
        XCTAssertNil(try RecognitionImage.render(strokes: [stroke(.marker)]))
        XCTAssertNil(try RecognitionImage.render(strokes: []))
        let both = try XCTUnwrap(try RecognitionImage.render(strokes: [stroke(), stroke(.marker, tx: 5000)]))
        XCTAssertEqual(both.region, plain.region, "the marker does not widen the image")
    }

    func testHugeInkIsScaledDownNotRejected() throws {
        var s = stroke()
        s.points[19].x = 20_000
        let r = try XCTUnwrap(try RecognitionImage.render(strokes: [s]))
        XCTAssertGreaterThan(r.region.w, 19_000)
        XCTAssertLessThanOrEqual(Double(max(size(r.png).width, size(r.png).height)), RecognitionImage.maxSide + 1)
    }
}
