import Foundation
import XCTest
@testable import InkVault

final class CompactionTests: XCTestCase {
    func testPlannerKeepsUncoveredDeltasAndNewestSnapshot() throws {
        var log = LogBuilder()
        let a1 = log.delta(devA, 0, [.setMeta(.title("a"))])
        let a2 = log.delta(devA, 10, [.setMeta(.title("b"))])
        let b1 = log.delta(devB, 20, [.setMeta(.title("c"))])        // never seen by the snapshots
        let old = try log.snapshot(devC, 30, from: [a1])              // C seq 1
        let a3 = log.delta(devA, 40, [.setMeta(.title("d"))])         // covered but recent
        let newest = try log.snapshot(devC, 50, from: [a1, a2, old, a3])   // C seq 2
        let lateA4 = log.delta(devA, 60, [.setMeta(.title("e"))])     // not covered

        let day: TimeInterval = 86_400
        let now = wallAt(baseMillis).addingTimeInterval(100 * day)
        var wall: [RevisionName: Date] = [:]
        for r in [a1, a2, b1, old, lateA4, newest] { wall[r.name] = r.wall }
        wall[a3.name] = now.addingTimeInterval(-day)                 // inside the window
        let names = [a1, a2, b1, old, a3, newest, lateA4].map(\.name)

        let del = CompactionPlanner.deletable(names: names, wall: wall, newestSnapshot: newest,
                                              retention: 30 * day, now: now)
        XCTAssertEqual(del, [a1.name, a2.name, old.name])
        XCTAssertFalse(del.contains(newest.name))

        // Missing wall → kept; newest snapshot never returned even if old enough.
        var partial = wall
        partial[a1.name] = nil
        XCTAssertEqual(CompactionPlanner.deletable(names: names, wall: partial, newestSnapshot: newest,
                                                   retention: 30 * day, now: now), [a2.name, old.name])
        XCTAssertEqual(CompactionPlanner.deletable(names: names, wall: wall, newestSnapshot: newest,
                                                   retention: 0, now: now.addingTimeInterval(1000 * day)),
                       [a1.name, a2.name, old.name, a3.name])
        // Compaction never changes the reconstructed note.
        let before = try NoteReducer.reconstruct([a1, a2, b1, old, a3, newest, lateA4])
        let kept = [a1, a2, b1, old, a3, newest, lateA4].filter { !del.contains($0.name) }
        XCTAssertEqual(try NoteReducer.reconstruct(kept), before)
    }
}
