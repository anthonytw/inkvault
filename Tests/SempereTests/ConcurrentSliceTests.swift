import Foundation
import XCTest
@testable import Sempere

/// Concurrent replacements of one stroke (format.md §5.6.1): two devices
/// slice, move or recolour the same stroke without seeing each other's edit.
final class ConcurrentSliceTests: XCTestCase {
    let p1 = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!
    let p2 = UUID(uuidString: "00000000-0000-4000-8000-0000000000a2")!

    /// A stroke with distinct points, so overlapping copies are easy to tell apart.
    func ink(_ id: UUID = UUID(), parent: UUID? = nil, x: Double = 0, transform: Transform? = nil,
             color: Color = .black) -> Stroke {
        Stroke(id: id, ink: Ink(tool: .pen, color: color, width: 2),
               points: [StrokePoint(x: x, y: 2, w: 2, h: 2), StrokePoint(x: x + 10, y: 2, w: 2, h: 2)],
               transform: transform, parent: parent)
    }

    /// Every order of `revs` reconstructs to the same note; returns it.
    func reconstructAll(_ revs: [Revision], file: StaticString = #filePath, line: UInt = #line) throws -> NoteState {
        let reference = try NoteReducer.reconstruct(revs)
        var rng = SplitMix64(seed: 7)
        for _ in 0..<24 {
            XCTAssertEqual(try NoteReducer.reconstruct(revs.shuffled(using: &rng)), reference, file: file, line: line)
        }
        return reference
    }

    // MARK: Reproductions

    func testConcurrentSlicesKeepOneSetOfPieces() throws {
        var log = LogBuilder()
        let x = ink()
        let a1 = ink(parent: x.id, x: 0), a2 = ink(parent: x.id, x: 6)
        let b1 = ink(parent: x.id, x: 3)
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let sliceA = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: x.id),
                                           .addStroke(page: p1, stroke: a1), .addStroke(page: p1, stroke: a2)])
        let sliceB = log.delta(devB, 200, [.removeStroke(page: p1, strokeId: x.id),
                                           .addStroke(page: p1, stroke: b1)])
        // B's slice is the later replacement: A's pieces would overlap it and
        // bring back what B erased, and B's piece what A erased.
        XCTAssertEqual(try reconstructAll([d0, sliceA, sliceB]).allStrokeIds, [b1.id])
        // The other way round, A's pieces stay.
        var log2 = LogBuilder()
        let e0 = log2.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let lateA = log2.delta(devA, 300, [.removeStroke(page: p1, strokeId: x.id),
                                           .addStroke(page: p1, stroke: a1), .addStroke(page: p1, stroke: a2)])
        let earlyB = log2.delta(devB, 200, [.removeStroke(page: p1, strokeId: x.id),
                                            .addStroke(page: p1, stroke: b1)])
        XCTAssertEqual(try reconstructAll([e0, lateA, earlyB]).allStrokeIds, [a1.id, a2.id])
    }

    func testConcurrentSlicesWithEqualClocksResolveByDevice() throws {
        var log = LogBuilder()
        let x = ink()
        let a1 = ink(parent: x.id), b1 = ink(parent: x.id), b2 = ink(parent: x.id)
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let sliceA = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: a1)])
        let sliceB = log.delta(devB, 100, [.removeStroke(page: p1, strokeId: x.id),
                                           .addStroke(page: p1, stroke: b1), .addStroke(page: p1, stroke: b2)])
        // Same hlc: the greater device id wins, as for every LWW register.
        let state = try reconstructAll([sliceB, d0, sliceA])
        XCTAssertEqual(state.strokeIds, [[b1.id, b2.id]])
        XCTAssertNil(state.tombstones)
    }

    func testConcurrentSliceAndMove() throws {
        var log = LogBuilder()
        let x = ink()
        let piece = ink(parent: x.id)
        let moved = ink(parent: x.id, transform: Transform(a: 1, b: 0, c: 0, d: 1, tx: 40, ty: 0))
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let slice = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: piece)])
        let move = log.delta(devB, 200, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: moved)])
        // Not the moved stroke plus the sliced piece left where it was: the later edit.
        XCTAssertEqual(try reconstructAll([d0, slice, move]).allStrokeIds, [moved.id])
    }

    func testConcurrentSliceAndRecolour() throws {
        var log = LogBuilder()
        let x = ink()
        let piece = ink(parent: x.id)
        let red = ink(parent: x.id, color: Color(r: 255, g: 0, b: 0))
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let recolour = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: red)])
        let slice = log.delta(devB, 200, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: piece)])
        XCTAssertEqual(try reconstructAll([d0, recolour, slice]).allStrokeIds, [piece.id])
    }

    func testSliceOfASlicedStroke() throws {
        // Sequential: B saw A's slice and slices one of its pieces. Nothing competes.
        var log = LogBuilder()
        let x = ink()
        let a1 = ink(parent: x.id), a2 = ink(parent: x.id)
        let b1 = ink(parent: a1.id), b2 = ink(parent: a1.id)
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let sliceA = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: x.id),
                                           .addStroke(page: p1, stroke: a1), .addStroke(page: p1, stroke: a2)])
        let sliceB = log.delta(devB, 200, [.removeStroke(page: p1, strokeId: a1.id),
                                           .addStroke(page: p1, stroke: b1), .addStroke(page: p1, stroke: b2)])
        XCTAssertEqual(try reconstructAll([d0, sliceA, sliceB]).allStrokeIds, [a2.id, b1.id, b2.id])

        // Concurrent: both slice the same piece.
        let c1 = ink(parent: a1.id)
        let sliceC = log.delta(devC, 300, [.removeStroke(page: p1, strokeId: a1.id), .addStroke(page: p1, stroke: c1)])
        XCTAssertEqual(try reconstructAll([d0, sliceA, sliceB, sliceC]).allStrokeIds, [a2.id, c1.id])
    }

    func testTheLosingSideLosesWhatItDidToItsPiecesLater() throws {
        // A slices x, then (still without B's edit) slices one of its pieces
        // again; B's concurrent slice of x is later and wins: A's whole line
        // of pieces goes, not only the first set.
        var log = LogBuilder()
        let x = ink()
        let a1 = ink(parent: x.id), a2 = ink(parent: x.id), a11 = ink(parent: a1.id)
        let b1 = ink(parent: x.id)
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let sliceA = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: x.id),
                                           .addStroke(page: p1, stroke: a1), .addStroke(page: p1, stroke: a2)])
        let againA = log.delta(devA, 150, [.removeStroke(page: p1, strokeId: a1.id), .addStroke(page: p1, stroke: a11)])
        let sliceB = log.delta(devB, 200, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: b1)])
        XCTAssertEqual(try reconstructAll([d0, sliceA, againA, sliceB]).allStrokeIds, [b1.id])
    }
}
