import Foundation
import XCTest

final class CLIRecognizeTests: CLITestCase {
    func vaultArgs(_ vault: String) -> [String] { ["--vault", vault, "--identity", Self.fixtureKey] }

    func testDryRunListsNotesThatNeedReadingAndWritesNothing() throws {
        let vault = try copyFixtureVault()
        let before = try cli(["notes", "list", "--json"] + vaultArgs(vault)).out
        let r = try cli(["recognize", "--dry-run", "--json"] + vaultArgs(vault))
        XCTAssertEqual(r.status, 0, r.err)
        let obj = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual(obj["dryRun"] as? Bool, true)
        XCTAssertNil(obj["engine"])
        let notes = try XCTUnwrap(obj["recognized"] as? [[String: Any]])
        XCTAssertFalse(notes.isEmpty, "the fixture vault has ink without recognised text")
        for n in notes {
            XCTAssertNotNil(UUID(uuidString: n["note"] as? String ?? ""))
            XCTAssertNotNil(n["title"] as? String)
            XCTAssertGreaterThan(n["pagesRecognized"] as? Int ?? 0, 0)
            XCTAssertGreaterThanOrEqual(n["pages"] as? Int ?? 0, n["pagesRecognized"] as? Int ?? 1)
        }
        XCTAssertEqual(try cli(["notes", "list", "--json"] + vaultArgs(vault)).out, before)
        let human = try cli(["recognize", "--dry-run"] + vaultArgs(vault))
        XCTAssertTrue(human.out.contains("Would read \(notes.count) note"), human.out)
    }

    #if DEBUG
    // The fake recogniser stands in for Vision (debug builds only).
    func testRecognizeWritesTextReportsNotesAndSearchShowsBoxes() throws {
        let vault = try copyFixtureVault()
        let env = ["SEMPERE_FAKE_RECOGNIZER": "wombat eats roots"]
        let r = try cli(["recognize", "--json"] + vaultArgs(vault), env: env)
        XCTAssertEqual(r.status, 0, r.err)
        let obj = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual(obj["engine"] as? String, "fake-1")
        let done = try XCTUnwrap(obj["recognized"] as? [[String: Any]])
        XCTAssertFalse(done.isEmpty)
        XCTAssertEqual((obj["failed"] as? [Any])?.count, 0)

        // A second run has nothing left to read.
        let again = try cli(["recognize", "--json"] + vaultArgs(vault), env: env)
        XCTAssertEqual(((again.json as? [String: Any])?["recognized"] as? [Any])?.count, 0)
        XCTAssertTrue(try cli(["recognize"] + vaultArgs(vault), env: env).out.contains("Recognized 0 notes."))

        // Search: plain JSON has no `locations`; --show-boxes numbers the matches across the note.
        let plain = try cli(["search", "wombat", "--json"] + vaultArgs(vault))
        let plainHits = try XCTUnwrap(plain.json as? [[String: Any]])
        XCTAssertFalse(plainHits.isEmpty)
        XCTAssertNil(plainHits[0]["locations"])
        let boxed = try cli(["search", "wombat", "--show-boxes", "--json"] + vaultArgs(vault))
        let hits = try XCTUnwrap(boxed.json as? [[String: Any]])
        XCTAssertEqual(hits.count, plainHits.count)
        for hit in hits {
            let locations = try XCTUnwrap(hit["locations"] as? [[String: Any]])
            XCTAssertEqual(locations.count, 1, "one word per page matches")
            XCTAssertEqual(locations[0]["text"] as? String, "wombat")
            XCTAssertEqual((locations[0]["box"] as? [Double])?.count, 4)
            XCTAssertLessThanOrEqual(locations[0]["n"] as? Int ?? 99, locations[0]["of"] as? Int ?? 0)
        }
        let human = try cli(["search", "wombat", "--show-boxes"] + vaultArgs(vault))
        XCTAssertTrue(human.out.contains(" of ") && human.out.contains("wombat  ["), human.out)
    }

    func testNamedNoteOnly() throws {
        let vault = try copyFixtureVault()
        let r = try cli(["recognize", Self.lecture, "--json"] + vaultArgs(vault), env: ["SEMPERE_FAKE_RECOGNIZER": "hello"])
        XCTAssertEqual(r.status, 0, r.err)
        let done = try XCTUnwrap((r.json as? [String: Any])?["recognized"] as? [[String: Any]])
        XCTAssertEqual(done.map { $0["note"] as? String }, [Self.lecture])
    }

    #endif

    #if !canImport(Vision)
    func testRunWithoutVisionIsAClearError() throws {
        let vault = try copyFixtureVault()
        let r = try cli(["recognize"] + vaultArgs(vault))
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("Vision"), r.err)
    }
    #endif
}
