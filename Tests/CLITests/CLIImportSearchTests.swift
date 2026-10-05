import Foundation
import InkVault
import XCTest

final class CLIImportSearchTests: CLITestCase {
    static let noteFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    static var zipNote: String { noteFixtures.appendingPathComponent("synthetic.note").path }
    static var packageNote: String { noteFixtures.appendingPathComponent("synthetic-package.note").path }

    func vaultArgs(_ vault: String) -> [String] { ["--vault", vault, "--identity", Self.fixtureKey] }

    /// Every file under `dir` with its size, for "did anything change" checks.
    func listing(_ dir: String) -> [String] {
        let walker = FileManager.default.enumerator(atPath: dir)
        return (walker?.allObjects as? [String] ?? []).sorted().map { rel in
            let size = (try? FileManager.default.attributesOfItem(atPath: dir + "/" + rel)[.size] as? Int) ?? 0
            return "\(rel):\(size ?? 0)"
        }
    }

    func testImportZipThenSearchAndShow() throws {
        let vault = try copyFixtureVault()
        let r = try cli(["import", "notability", Self.zipNote] + vaultArgs(vault))
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.out.contains("imported  Synthetic note"), r.out)
        XCTAssertTrue(r.out.contains("1 imported, 0 skipped, 0 failed; 4 strokes."), r.out)

        // Case-insensitive search, human output: title, page number, snippet.
        let s = try cli(["search", "CD"] + vaultArgs(vault))
        XCTAssertEqual(s.status, 0, s.err)
        XCTAssertTrue(s.out.contains("Synthetic note"), s.out)
        XCTAssertTrue(s.out.contains("ab cd x"), s.out)
        XCTAssertFalse(s.out.contains("Fixture lecture"), s.out)

        // JSON carries ids and word boxes.
        let j = try cli(["search", "cd", "--json"] + vaultArgs(vault))
        let hits = try XCTUnwrap(j.json as? [[String: Any]])
        XCTAssertEqual(hits.count, 1)
        let hit = hits[0]
        XCTAssertEqual(hit["title"] as? String, "Synthetic note")
        XCTAssertEqual(hit["page"] as? Int, 1)
        XCTAssertEqual(hit["matches"] as? Int, 1)
        XCTAssertNotNil(UUID(uuidString: hit["noteId"] as? String ?? ""))
        XCTAssertNotNil(UUID(uuidString: hit["pageId"] as? String ?? ""))
        let words = try XCTUnwrap(hit["words"] as? [[String: Any]])
        XCTAssertEqual(words.map { $0["text"] as? String }, ["cd"])
        XCTAssertEqual((words[0]["box"] as? [Double])?.count, 4)

        XCTAssertEqual(try cli(["search", "nothing-here"] + vaultArgs(vault)).out
                        .trimmingCharacters(in: .whitespacesAndNewlines), "No matches.")
        XCTAssertEqual((try cli(["search", "nothing-here", "--json"] + vaultArgs(vault)).json as? [Any])?.count, 0)
        XCTAssertEqual(try cli(["search", "  "] + vaultArgs(vault)).status, 2)

        // notes show reports pages with recognised text.
        let id = try XCTUnwrap(hit["noteId"] as? String)
        let show = try cli(["notes", "show", id] + vaultArgs(vault))
        XCTAssertTrue(show.out.contains("1 of 1 page(s) with recognised text"), show.out)
        let showJSON = try cli(["notes", "show", id, "--json"] + vaultArgs(vault))
        XCTAssertEqual(((showJSON.json as? [String: Any])?["note"] as? [String: Any])?["recognizedPages"] as? Int, 1)
        // The sample note has none.
        let lecture = try cli(["notes", "show", Self.lecture] + vaultArgs(vault))
        XCTAssertTrue(lecture.out.contains("0 of 2 page(s) with recognised text"), lecture.out)
        XCTAssertEqual(try cli(["vault", "verify", "--vault", vault, "--identity", Self.fixtureKey]).status, 0)
    }

    func testReimportSkipsUnlessOverwrite() throws {
        let vault = try copyFixtureVault()
        let args = ["import", "notability", Self.zipNote] + vaultArgs(vault)
        XCTAssertEqual(try cli(args).status, 0)
        let again = try cli(args + ["--json"])
        XCTAssertEqual(again.status, 0, again.err)
        let top = try XCTUnwrap(again.json as? [String: Any])
        XCTAssertEqual((top["summary"] as? [String: Any])?["skipped"] as? Int, 1)
        XCTAssertEqual(((top["notes"] as? [[String: Any]])?.first)?["status"] as? String, "skipped")
        let over = try cli(args + ["--overwrite", "--json"])
        XCTAssertEqual(over.status, 0, over.err)
        XCTAssertEqual(((over.json as? [String: Any])?["summary"] as? [String: Any])?["imported"] as? Int, 1)
        // Still exactly one hit after the overwrite.
        XCTAssertEqual((try cli(["search", "cd", "--json"] + vaultArgs(vault)).json as? [Any])?.count, 1)
    }

    func testDryRunTouchesNeitherVaultNorDeviceState() throws {
        let vault = try copyFixtureVault()
        let before = listing(vault)
        let r = try cli(["import", "notability", Self.packageNote, "--dry-run"] + vaultArgs(vault))
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.out.contains("would import"), r.out)
        XCTAssertTrue(r.out.contains("Dry run: 1 would be imported"), r.out)
        XCTAssertEqual(listing(vault), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("state")), "dry run created device state")
        XCTAssertEqual((try cli(["search", "cd", "--json"] + vaultArgs(vault)).json as? [Any])?.count, 0)
        // A real import does create it.
        XCTAssertEqual(try cli(["import", "notability", Self.packageNote] + vaultArgs(vault)).status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("state/inkvault/device.json")))
    }

    func testDryRunReportsAlreadyImported() throws {
        let vault = try copyFixtureVault()
        XCTAssertEqual(try cli(["import", "notability", Self.zipNote] + vaultArgs(vault)).status, 0)
        let before = listing(vault)
        let r = try cli(["import", "notability", Self.zipNote, "--dry-run", "--json"] + vaultArgs(vault))
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(((r.json as? [String: Any])?["summary"] as? [String: Any])?["skipped"] as? Int, 1)
        XCTAssertEqual(listing(vault), before)
    }

    func testFolderSearchNotebookAndNoScale() throws {
        let vault = try copyFixtureVault()
        let tree = tmp.appendingPathComponent("Notability/Research")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: Self.zipNote), to: tree.appendingPathComponent("a.note"))
        let r = try cli(["import", "notability", tmp.appendingPathComponent("Notability").path, "--json"] + vaultArgs(vault))
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(((r.json as? [String: Any])?["notes"] as? [[String: Any]])?.first?["notebook"] as? String, "Research")

        let other = try copyFixtureVault(as: "other.inkvault")
        let n = try cli(["import", "notability", Self.zipNote, "--notebook", "Mine", "--no-scale"] + vaultArgs(other))
        XCTAssertEqual(n.status, 0, n.err)
        let list = try cli(["notes", "list", "--notebook", "Mine", "--json"] + vaultArgs(other))
        XCTAssertEqual((list.json as? [[String: Any]])?.count, 1)
        // Unscaled: Notability's 716.8 wide page, so word boxes are not scaled by 612/716.8.
        let unscaled = try cli(["search", "ab", "--json"] + vaultArgs(other))
        let scaled = try cli(["search", "ab", "--json"] + vaultArgs(vault))
        func firstX(_ r: CLIResult) -> Double? {
            (((r.json as? [[String: Any]])?.first?["words"] as? [[String: Any]])?.first?["box"] as? [Double])?.first
        }
        let ux = try XCTUnwrap(firstX(unscaled)), sx = try XCTUnwrap(firstX(scaled))
        XCTAssertEqual(sx, ux * 612 / 716.8, accuracy: 0.01)
    }

    func testFailedNoteGivesNonZeroExit() throws {
        let vault = try copyFixtureVault()
        let bad = path("broken.note")
        try Data("not a zip".utf8).write(to: URL(fileURLWithPath: bad))
        let r = try cli(["import", "notability", bad, Self.zipNote] + vaultArgs(vault))
        XCTAssertEqual(r.status, 1, r.out + r.err)
        XCTAssertTrue(r.out.contains("FAILED"), r.out)
        XCTAssertTrue(r.out.contains("1 imported, 0 skipped, 1 failed"), r.out)
        XCTAssertTrue(r.err.contains("1 note(s) failed"), r.err)
        // The good note still went in.
        XCTAssertEqual((try cli(["search", "cd", "--json"] + vaultArgs(vault)).json as? [Any])?.count, 1)
    }

    func testImportInputErrors() throws {
        let vault = try copyFixtureVault()
        let missing = try cli(["import", "notability", path("nope.note")] + vaultArgs(vault))
        XCTAssertEqual(missing.status, 1)
        XCTAssertTrue(missing.err.contains("no such file"), missing.err)
        try FileManager.default.createDirectory(atPath: path("empty"), withIntermediateDirectories: true)
        let empty = try cli(["import", "notability", path("empty")] + vaultArgs(vault))
        XCTAssertEqual(empty.status, 1)
        XCTAssertTrue(empty.err.contains("no .note or .ntb files"), empty.err)
        XCTAssertEqual(try cli(["import", "notability"] + vaultArgs(vault)).status, 2)
    }
}
