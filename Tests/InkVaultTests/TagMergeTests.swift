import Age
import Foundation
import XCTest
@testable import InkVault

/// Case-insensitive tags (format.md §5.4) against the merge rules: `tags` is
/// one LWW register holding the whole array, so case only matters to
/// writers (`NoteOps.normalizedTags`) and to matching (`NoteOps.tagKey`),
/// never to which write wins.
final class TagMergeTests: VaultTestCase {
    private func tags(_ revisions: [Revision]) throws -> [String] {
        try NoteReducer.reconstruct(revisions).meta.tags
    }

    /// Two devices tag the same note "Math" and "math" without seeing each
    /// other: every device converges on one spelling, whatever the order the
    /// files arrive in, and the note has the tag exactly once.
    func testConcurrentSpellingsConvergeOnOne() throws {
        var log = LogBuilder()
        let a = log.delta(devA, 100, [.setMeta(.tags(NoteOps.normalizedTags(["Math"])))])
        let b = log.delta(devB, 100, [.setMeta(.tags(NoteOps.normalizedTags(["math"])))])
        let ab = try tags([a, b])
        XCTAssertEqual(ab, try tags([b, a]))
        XCTAssertEqual(ab.map(NoteOps.tagKey), ["math"])
        // Equal HLCs: the greater device id wins, as for every register.
        XCTAssertEqual(ab, ["math"])
        // Through a snapshot that saw only one of them, the result is the same.
        let snapA = try log.snapshot(devC, 50, from: [a])
        XCTAssertEqual(try tags([snapA, b]), ab)
    }

    /// Removing a tag (by any spelling) is a later write of the register: a
    /// concurrent or earlier add in another spelling does not bring it back.
    func testRemovedTagStaysRemovedWhateverTheSpelling() throws {
        var log = LogBuilder()
        let add = log.delta(devA, 100, [.setMeta(.tags(["Math", "x"]))])
        // B saw A's add and removes "MATH": every spelling of the key goes.
        let seen = try tags([add])
        let removed = seen.filter { NoteOps.tagKey($0) != NoteOps.tagKey("MATH") }
        XCTAssertEqual(removed, ["x"])
        let rm = log.delta(devB, 200, [.setMeta(.tags(removed))])
        // A late, older write in another spelling arrives after the removal.
        let lateOld = log.delta(devC, 150, [.setMeta(.tags(["x", "math"]))])
        for order in [[add, rm, lateOld], [lateOld, rm, add], [rm, lateOld, add]] {
            XCTAssertEqual(try tags(order), ["x"])
        }
        let snap = try log.snapshot(devA, 300, from: [add, rm])
        XCTAssertEqual(try tags([snap, lateOld]), ["x"])
        XCTAssertEqual(try tags([lateOld, snap, add]), ["x"])
    }

    /// A later add in another spelling after a removal is a real re-add.
    func testReAddAfterRemovalWins() throws {
        var log = LogBuilder()
        let add = log.delta(devA, 100, [.setMeta(.tags(["Math"]))])
        let rm = log.delta(devB, 200, [.setMeta(.tags([]))])
        let reAdd = log.delta(devA, 300, [.setMeta(.tags(["math"]))])
        XCTAssertEqual(try tags([reAdd, rm, add]), ["math"])
    }

    /// Notes written before tags were case-insensitive may hold two
    /// spellings. Readers keep the stored array as it is; the next write by
    /// a current writer folds them, keeping the first spelling; removing by
    /// key removes every spelling, so neither comes back.
    func testOlderNotesWithTwoSpellingsReadUnchangedAndFoldOnWrite() throws {
        var log = LogBuilder()
        let old = log.delta(devA, 100, [.setMeta(.tags(["Math", "x", "math", "Fall  2026"]))])
        XCTAssertEqual(try tags([old]), ["Math", "x", "math", "Fall  2026"])
        // Matching sees one tag per key.
        XCTAssertEqual(Set(try tags([old]).map(NoteOps.tagKey)), ["math", "x", "fall 2026"])
        // A current writer adding a tag folds the duplicates.
        let folded = NoteOps.normalizedTags(try tags([old]) + ["y"])
        XCTAssertEqual(folded, ["Math", "x", "Fall 2026", "y"])
        let write = log.delta(devB, 200, [.setMeta(.tags(folded))])
        XCTAssertEqual(try tags([write, old]), folded)
        // Removing "MATH" removes both stored spellings.
        let removed = try tags([old]).filter { NoteOps.tagKey($0) != NoteOps.tagKey("MATH") }
        XCTAssertEqual(removed, ["x", "Fall  2026"])
    }

    /// Survives a real vault round trip: the stored spelling is what was written.
    func testVaultKeepsTheWrittenSpelling() throws {
        let vault = try makeVault(X25519Identity())
        let state = tmp.appendingPathComponent("device.json")
        let note = UUID()
        try vault.apply(NoteOps.newNote(title: "T", tags: ["Math", " math ", "Fall   Term"]), to: note,
                        deviceState: state, app: "t")
        XCTAssertEqual(try vault.summary(of: note).tags, ["Math", "Fall Term"])
    }
}
