import Age
import Foundation
import FuzzSupport
import XCTest

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
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

    /// `vault.json` with a date whose fraction ran to 800 digits killed the
    /// process with SIGFPE inside ICU (ISO8601DateFormatter), found by the
    /// long fuzz run. Every date in the format is now parsed by `RFC3339`.
    func testLongFractionalSecondsAreRejectedNotCrashing() throws {
        let long = "2026-10-05T13:20:16." + String(repeating: "9", count: 800) + "22Z"
        XCTAssertNil(RFC3339.parse(long))
        let json = #"{"format":"inkvault/1","vaultId":"0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c","created":"\#(long)","#
            + #""recipients":[],"vaultSecret":""}"#
        XCTAssertThrowsError(try VaultManifest.decode(Data(json.utf8))) { XCTAssertTrue($0 is DecodingError, "\($0)") }
        for bad in ["2026-10-05T13:20:4.9e-324Z", "2026-10-05T13:20:255Z", "2026-02-30T00:00:00Z", "2026-10-04T24:00:00Z",
                    "2026-10-04T23:59:60Z", "0000-01-01T00:00:00Z", "2026-10-04 18:20:00Z", "2026-10-04T18:20:00",
                    "2026-10-04T18:20:00.Z", "2026-10-04T18:20:00.1234567890Z", "2026-10-04T18:20:00+24:00", ""] {
            XCTAssertNil(RFC3339.parse(bad), bad)
        }
        XCTAssertEqual(RFC3339.parse("2026-10-04T18:20:00+02:00"), RFC3339.parse("2026-10-04T16:20:00Z"))
        XCTAssertEqual(RFC3339.parse("2026-10-04T16:20:00.123456789Z"), RFC3339.parse("2026-10-04T16:20:00.123Z"))
        XCTAssertEqual(RFC3339.parse("2024-02-29T00:00:00Z").map(RFC3339.string), "2024-02-29T00:00:00.000Z")
    }

    /// A local time inside 0001...9999 whose offset puts the instant outside
    /// it was accepted: `0001-01-01T00:00:00+00:01` is year 0 in UTC, which
    /// `RFC3339.string` (every writer) refuses, so a note holding such a
    /// `created` decoded but could never be snapshotted or compacted again.
    func testOffsetsCannotLeaveTheWritableYears() throws {
        for s in ["0001-01-01T00:00:00+00:01", "0001-01-01T00:59:59.999+01:00", "9999-12-31T23:59:59-00:01",
                  "9999-12-31T23:00:00-01:00"] {
            XCTAssertNil(RFC3339.parse(s), s)
        }
        XCTAssertEqual(RFC3339.parse("0001-01-01T01:00:00+01:00").flatMap(RFC3339.string), "0001-01-01T00:00:00.000Z")
        XCTAssertEqual(RFC3339.parse("9999-12-31T22:59:59.999-01:00").flatMap(RFC3339.string), "9999-12-31T23:59:59.999Z")
        var log = LogBuilder()
        let rev = log.delta(devA, 0, [.deleteNote])
        let json = String(decoding: try InkJSON.encoder().encode(rev), as: UTF8.self)
        let wall = try XCTUnwrap(RFC3339.string(from: rev.wall))
        let hostile = json.replacingOccurrences(of: wall, with: "0001-01-01T00:00:00+00:01")
        XCTAssertNotEqual(hostile, json)
        XCTAssertThrowsError(try InkJSON.decoder().decode(Revision.self, from: Data(hostile.utf8))) {
            XCTAssertTrue($0 is DecodingError, "\($0)")
        }
    }

    /// The arithmetic codec agrees with ISO8601DateFormatter for every
    /// millisecond-precise date from 1583 on, so existing files read and
    /// re-encode exactly as before.
    func testRFC3339MatchesFoundationFormatter() throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var g = SplitMix64(seed: 3339)
        for _ in 0..<5000 {
            let ms = Int64.random(in: -12_000_000_000_000...253_000_000_000_000, using: &g)
            let date = Date(timeIntervalSince1970: Double(ms) / 1000)
            let ours = try XCTUnwrap(RFC3339.string(from: date))
            XCTAssertEqual(ours, iso.string(from: date))
            let back = try XCTUnwrap(RFC3339.parse(ours))
            XCTAssertEqual(back.timeIntervalSince1970, try XCTUnwrap(iso.date(from: ours)).timeIntervalSince1970, accuracy: 1e-6)
            XCTAssertEqual(RFC3339.string(from: back), ours)
        }
    }

    /// Dates no reader can decode (NaN, beyond year 9999) and coordinates that
    /// overflow when rounded are refused or kept, never written as garbage.
    func testWritersRefuseUnreadableDatesAndKeepHugeCoordinates() throws {
        for bad in [Date(timeIntervalSinceReferenceDate: .nan), Date(timeIntervalSinceReferenceDate: 1e300),
                    Date(timeIntervalSince1970: -62_135_596_801), RFC3339.end] {
            XCTAssertNil(RFC3339.string(from: bad))
            XCTAssertThrowsError(try InkJSON.encoder().encode([bad])) { XCTAssertTrue($0 is EncodingError, "\($0)") }
        }
        let vault = try makeVault(X25519Identity())
        var log = LogBuilder()
        var rev = log.delta(devA, 0, [.deleteNote])
        rev.wall = Date(timeIntervalSinceReferenceDate: .nan)
        XCTAssertThrowsError(try vault.write(rev)) { XCTAssertTrue($0 is EncodingError, "\($0)") }
        XCTAssertEqual(try vault.revisionNames(of: testNote), [])

        XCTAssertEqual(InkJSON.round3(1e306), 1e306)
        XCTAssertEqual(InkJSON.round3(1.23456), 1.235)
        let big = Stroke(ink: Ink(tool: .pen, color: .black, width: 1e306), points: [StrokePoint(x: 1e306, y: -1e306, w: 1, h: 1)])
        let decoded = try InkJSON.decoder().decode(Stroke.self, from: InkJSON.encoder().encode(big))
        XCTAssertEqual(decoded.points[0].x, 1e306)
    }

    /// A snapshot listing 100 000 `extra` seqs plus 500 deltas: restore points
    /// re-merged every snapshot and scanned every extra with a linear
    /// `covers` per point (cubic: 203 s for only 10 000 extras and 100 deltas).
    /// `covers` is now a binary search and `Completeness` one sweep.
    func testHistoryOfHugeIncludedIsFast() throws {
        var log = LogBuilder()
        let page = UUID()
        let first = log.delta(devA, 0, [.addPage(Page(id: page, order: "a"))])
        let strokes = (0..<2000).map { i in
            Stroke(id: UUID(), ink: Ink(tool: .pen, color: .black, width: 1), points: [StrokePoint(x: 1, y: 2, w: 1, h: 1)],
                   origin: "17596320000000000-bbbbbbbb-\(2 * i + 200_010)-0")
        }
        let snap = Revision(noteId: testNote, device: devC, seq: 1, hlc: HLC(millis: baseMillis + 5, counter: 0)!,
                            wall: wallAt(baseMillis + 5), app: "x",
                            body: .snapshot(included: Included([devB: .init(upTo: 1, extra: Array(stride(from: 3, to: 200_003, by: 2))),
                                                                devA: .init(upTo: 1)]),
                                            state: NoteState(meta: NoteMeta(created: wallAt(0)),
                                                             pages: [Page(id: page, order: "a", strokes: strokes)])))
        let deltas = (0..<500).map { i in log.delta(devA, Int64(10 + i), [.setMeta(.title("t\(i)"))]) }
        let t0 = Date()
        let points = NoteHistory.restorePoints([first, snap] + deltas)
        _ = try NoteReducer.reconstruct([first, snap] + deltas)
        XCTAssertEqual(points.count, 502)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 20)
    }

    /// The one-sweep `Completeness` agrees with the per-point definition it
    /// replaced, on adversarial logs with revisions dropped (compacted) and
    /// some marked unreadable.
    func testCompletenessMatchesReference() throws {
        var rng = FuzzRNG(seed: 99)
        for _ in 0..<300 {
            var revs = InkVaultFuzzTests.adversarialLog(&rng)
            // Unique (device, seq), as a vault directory holds them.
            var seen = Set<String>()
            revs = revs.filter { seen.insert("\($0.device)-\($0.seq)").inserted }
            var kept: [Revision] = [], unreadable: [RevisionName] = []
            for r in revs {
                switch rng.below(5) {
                case 0: continue                       // compacted away
                case 1: unreadable.append(r.name)
                default: kept.append(r)
                }
            }
            let points = kept.map(\.name).sorted()
            let fast = Completeness(kept, unreadable: unreadable).isComplete(at: points)
            let slow = points.map { Self.referenceIsComplete(kept, unreadable: unreadable, at: $0) }
            XCTAssertEqual(fast, slow, "\(revs.map(\.name))")
        }
    }

    /// The definition `Completeness` implemented before it became a sweep.
    static func referenceIsComplete(_ revisions: [Revision], unreadable: [RevisionName], at point: RevisionName) -> Bool {
        let listed = revisions.map(\.name) + unreadable
        var present: [DeviceID: Set<Int>] = [:]
        for n in listed { present[n.device, default: []].insert(n.seq) }
        var snapshots: [(name: RevisionName, included: Included)] = []
        var covered = Included()
        for r in revisions {
            guard case .snapshot(let included, _) = r.body else { continue }
            snapshots.append((r.name, included))
            covered = covered.union(included)
        }
        if unreadable.contains(where: { $0 <= point || $0.kind == .snapshot }) { return false }
        let before = snapshots.filter { $0.name <= point }.reduce(Included()) { $0.union($1.included) }
        var firstAtOrAfter: [DeviceID: Int] = [:]
        for n in listed where n >= point { firstAtOrAfter[n.device] = min(firstAtOrAfter[n.device] ?? .max, n.seq) }
        for (device, all) in covered.entries {
            let have = present[device] ?? []
            let known = before.entries[device] ?? Included.Entry()
            let limit = firstAtOrAfter[device] ?? .max
            func needs(_ seq: Int) -> Bool { seq < limit && !have.contains(seq) && !known.covers(seq) }
            if all.extra.contains(where: needs) { return false }
            let top = min(all.upTo, limit - 1)
            if known.upTo < top {
                let length = top - known.upTo
                let filled = have.count { $0 > known.upTo && $0 <= top }
                    + known.extra.count { $0 > known.upTo && $0 <= top && !have.contains($0) }
                if filled < length { return false }
            }
        }
        return true
    }

    /// Files from a shared folder or sync server can be any size or kind:
    /// readers refuse an oversized file before holding it, and refuse a FIFO
    /// (whose open would otherwise block forever) instead of hanging.
    func testBoundedReadsRefuseHugeFilesAndFIFOs() throws {
        let big = tmp.appendingPathComponent("big")
        try Data(count: 4097).write(to: big)
        XCTAssertEqual(try BoundedRead.contents(of: big, maxBytes: 4097).count, 4097)
        XCTAssertThrowsError(try BoundedRead.contents(of: big, maxBytes: 4096)) {
            XCTAssertEqual($0 as? VaultError, .fileTooLarge(big.path, limit: 4096))
        }
        let fifo = tmp.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let t0 = Date()
        XCTAssertThrowsError(try BoundedRead.contents(of: fifo, maxBytes: 10)) { XCTAssertTrue($0 is VaultError) }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)

        // Through the vault: an oversized vault.json and a revision that is a FIFO.
        let id = X25519Identity()
        let vault = try makeVault(id)
        let rev = sampleLog()[0]
        try vault.write(rev)
        let file = fileURL(vault, rev.noteId, rev.name)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertThrowsError(try vault.readRevision(noteId: rev.noteId, name: rev.name)) { e in
            guard case RevisionReadError.unreadable? = e as? RevisionReadError else { return XCTFail("\(e)") }
        }
        XCTAssertFalse(vault.verify().isHealthy)
        let manifest = vault.url.appendingPathComponent("vault.json")
        try (Data("{".utf8) + Data(repeating: 0x20, count: BoundedRead.maxManifestBytes)).write(to: manifest)
        XCTAssertThrowsError(try Vault.open(at: vault.url, identities: [id])) { e in
            guard case VaultError.fileTooLarge? = e as? VaultError else { return XCTFail("\(e)") }
        }
    }

    /// A notebook name of 200 000 levels made `NotebookNode.tree` recurse once
    /// per level (a stack overflow); the sidebar tree stops at `maxDepth`.
    func testDeepNotebookPathDoesNotRecurseWithoutBound() {
        let deep = String(repeating: "a/", count: 200_000)
        let t0 = Date()
        var nodes = NotebookNode.tree([deep, "a/b"])
        var depth = 0
        while let first = nodes.first { depth += 1; nodes = first.children }
        XCTAssertEqual(depth, NotebookNode.maxDepth)
        XCTAssertEqual(NotebookPath.components(deep).count, 200_000)
        XCTAssertTrue(NotebookPath.name(deep, isWithin: "a/a"))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 20)
    }
}
