import Age
import Foundation
import XCTest
@testable import InkVault

/// Regression tests for hostile or corrupt input found by review and by the
/// fuzz harness (`InkVaultFuzzTests`): each must fail with a typed error,
/// never trap.
final class UntrustedInputTests: VaultTestCase {
    /// A snapshot whose `included` names `upTo == Int.max` trapped in
    /// `Included.Entry.normalize()` (`upTo + 1`).
    func testIncludedEntryAtIntMaxDoesNotTrap() throws {
        let top = Included.Entry(upTo: .max, extra: [5, .max])
        XCTAssertEqual(top, Included.Entry(upTo: .max, extra: []))
        XCTAssertTrue(top.covers(.max))
        var inc = Included([devA: top])
        inc.insert(device: devA, seq: .max)
        XCTAssertEqual(inc.union(Included([devA: .init(upTo: 3, extra: [.max])])).entries[devA], top)
        XCTAssertTrue(inc.isSuperset(of: Included([devA: .init(upTo: 3)])))
        XCTAssertEqual(Included.Entry(upTo: .max - 1, extra: [.max]), top)
    }

    /// Decoding refuses a seq above `RevisionName.maxSeq` in `included`, a
    /// revision or a file name, so `seq + 1` (`nextSeq`) cannot overflow.
    func testSeqAboveMaxSeqIsRejected() throws {
        let max = RevisionName.maxSeq
        let ok = try InkJSON.decoder().decode(Included.self, from: Data(#"{"aaaaaaaa":{"upTo":\#(max),"extra":[]}}"#.utf8))
        XCTAssertEqual(ok.entries[devA]?.upTo, max)
        for bad in [#"{"aaaaaaaa":{"upTo":9223372036854775807,"extra":[]}}"#,
                    #"{"aaaaaaaa":{"upTo":\#(max + 1),"extra":[]}}"#,
                    #"{"aaaaaaaa":{"upTo":1,"extra":[9223372036854775807]}}"#] {
            XCTAssertThrowsError(try InkJSON.decoder().decode(Included.self, from: Data(bad.utf8)), bad) { e in
                XCTAssertTrue(e is DecodingError, "\(e)")
            }
        }
        XCTAssertNotNil(RevisionName("17596320000000000-aaaaaaaa-\(max).delta.age"))
        XCTAssertNil(RevisionName("17596320000000000-aaaaaaaa-\(max + 1).delta.age"))
        XCTAssertNil(RevisionName("17596320000000000-aaaaaaaa-9223372036854775807.delta.age"))

        var log = LogBuilder()
        var rev = log.delta(devA, 0, [.deleteNote])
        rev.seq = max + 1
        let json = try InkJSON.encoder().encode(rev)
        XCTAssertThrowsError(try InkJSON.decoder().decode(Revision.self, from: json))
    }

    /// `nextSeq` after a snapshot covering `maxSeq` is `maxSeq + 1` (no
    /// overflow), and writing that revision is refused with a typed error.
    func testNextSeqAtTheLimitIsRefusedNotTrapped() throws {
        var log = LogBuilder()
        let d = log.delta(devA, 0, [.addPage(Page(order: "a"))])
        let snap = Revision(noteId: testNote, device: devB, seq: 1, hlc: HLC(millis: baseMillis + 1, counter: 0)!,
                            wall: wallAt(baseMillis + 1), app: "test/0",
                            body: .snapshot(included: Included([devA: .init(upTo: RevisionName.maxSeq)]),
                                            state: try NoteReducer.reconstruct([d])))
        XCTAssertEqual(Vault.nextSeq(from: [d, snap], device: devA), RevisionName.maxSeq + 1)

        let id = X25519Identity()
        let vault = try makeVault(id)
        var next = log.delta(devA, 5, [.deleteNote])
        next.seq = RevisionName.maxSeq + 1
        XCTAssertThrowsError(try vault.write(next)) { e in
            XCTAssertEqual(e as? VaultError, .seqOutOfRange(RevisionName.maxSeq + 1))
        }
    }
}
