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
}
