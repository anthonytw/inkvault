import Foundation
import Sempere
import XCTest

/// `sempere recognize`, `import notability --recognize missing` and
/// `notes search`. Reading handwriting needs Vision: on Linux the commands
/// must refuse (and change nothing); on macOS they run for real. Neither
/// asserts what Vision reads from synthetic strokes, only what is stored.
final class CLIRecognizeTests: CLITestCase {
    /// A vault from `makeVault` whose first note's page 1 carries Notability's
    /// recognition (no `basis`).
    func vaultWithImportedText() throws -> (vault: Vault, keyPath: String, note: UUID, pages: [UUID]) {
        let (vault, _, keyPath) = try makeVault()
        let note = UUID(uuidString: "aaaaaaaa-1111-4111-8111-000000000001")!
        let pages = try vault.reconstruct(noteId: note).pages.map(\.id)
        let other = DeviceID("0badf00d")!
        try vault.write(Revision(noteId: note, device: other, seq: 1, hlc: HLC(millis: 1_760_000_009_000, counter: 0)!,
                                 wall: Date(timeIntervalSince1970: 1_760_000_009), app: "cli-test/1",
                                 body: .delta(ops: [.setPageRecognition(pageId: pages[0],
                                                                        recognition: Recognition(engine: "notability-14.2",
                                                                                                 text: "Imported"))])))
        return (vault, keyPath, note, pages)
    }

    func args(_ vault: Vault, _ keyPath: String) -> [String] { ["--vault", vault.url.path, "--identity", keyPath] }

    func revisionCount(_ vault: Vault) throws -> Int {
        try vault.noteIDs().reduce(0) { $0 + (try vault.revisionNames(of: $1).count) }
    }

    /// `read` page numbers per note id, from `--json`.
    func readPages(_ r: CLIResult) throws -> [String: [Int]] {
        let notes = try XCTUnwrap((r.json as? [String: Any])?["notes"] as? [[String: Any]], r.out + r.err)
        return Dictionary(uniqueKeysWithValues: notes.map { ($0["note"] as! String, $0["read"] as! [Int]) })
    }

    func testDryRunListsThePagesEachModeReads() throws {
        let (vault, key, note, _) = try vaultWithImportedText()
        let before = try revisionCount(vault)
        let n1 = note.uuidString.lowercased(), n2 = "bbbbbbbb-2222-4222-8222-000000000002"

        let stale = try cli(["recognize", "--all", "--dry-run", "--json"] + args(vault, key))
        XCTAssertEqual(stale.status, 0, stale.err)
        XCTAssertEqual(try readPages(stale), [n1: [2], n2: [1]], "Notability's text on page 1 is kept")
        let missing = try cli(["recognize", "Physics / Week 3", "--missing-only", "--dry-run", "--json"] + args(vault, key))
        XCTAssertEqual(try readPages(missing), [n1: [2]])
        let force = try cli(["recognize", "aaaa", "--force", "--dry-run", "--json"] + args(vault, key))
        XCTAssertEqual(try readPages(force), [n1: [1, 2]])
        let text = try cli(["recognize", "--all", "--dry-run"] + args(vault, key))
        XCTAssertTrue(text.out.contains("would read page(s) 2"), text.out)
        XCTAssertEqual(try revisionCount(vault), before)
    }

    func testUsageErrors() throws {
        let (vault, key, _, _) = try vaultWithImportedText()
        for bad in [["recognize"], ["recognize", "--all", "Groceries"], ["recognize", "--all", "--force", "--missing-only"],
                    ["notes", "search", "  "]] {
            XCTAssertEqual(try cli(bad + args(vault, key)).status, 2, "\(bad)")
        }
    }

    func testNotesSearchRanksLikeTheApp() throws {
        let (vault, key, note, _) = try vaultWithImportedText()
        _ = try cli(["notes", "tag", "Groceries", "--add", "imported"] + args(vault, key))
        let r = try cli(["notes", "search", "imported", "--json"] + args(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        let hits = try XCTUnwrap(r.json as? [[String: Any]])
        // A tag match outranks a match in page text.
        XCTAssertEqual(hits.map { $0["title"] as? String }, ["Groceries", "Physics / Week 3"])
        XCTAssertEqual(hits.map { $0["fields"] as? [String] }, [["tag"], ["text"]])
        XCTAssertEqual((hits[1]["page"] as? [String: Any])?["number"] as? Int, 1)
        XCTAssertEqual(hits[1]["note"] as? String, note.uuidString.lowercased())
        XCTAssertEqual(hits[1]["snippet"] as? String, "Imported")

        let tagOnly = try cli(["notes", "search", "#imported", "--json"] + args(vault, key))
        XCTAssertEqual((tagOnly.json as? [[String: Any]])?.count, 1)
        let scoped = try cli(["notes", "search", "imported", "--tag", "IMPORTED", "--json"] + args(vault, key))
        XCTAssertEqual((scoped.json as? [[String: Any]])?.map { $0["title"] as? String }, ["Groceries"])
        XCTAssertEqual((try cli(["notes", "search", "imported", "--deleted", "--json"] + args(vault, key)).json
                        as? [[String: Any]])?.count, 0)
        _ = try cli(["notes", "delete", "Groceries"] + args(vault, key))
        XCTAssertEqual((try cli(["notes", "search", "imported", "--deleted", "--json"] + args(vault, key)).json
                        as? [[String: Any]])?.count, 1)
        let plain = try cli(["notes", "search", "week imported"] + args(vault, key))
        XCTAssertTrue(plain.out.contains("Physics / Week 3"), plain.out)
    }

    #if canImport(Vision)
    func testRecognizeStoresOneDeltaPerNoteWithABasis() throws {
        let (vault, key, note, pages) = try vaultWithImportedText()
        let r = try cli(["recognize", "--all", "--json"] + args(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        let notes = try XCTUnwrap((r.json as? [String: Any])?["notes"] as? [[String: Any]])
        XCTAssertEqual(notes.count, 2)
        XCTAssertTrue(notes.allSatisfy { ($0["file"] as? String)?.hasSuffix(".delta.age") == true }, "\(notes)")

        var state = try vault.reconstruct(noteId: note)
        XCTAssertEqual(state.pages[0].recognition?.text, "Imported", "Notability's text is kept")
        let read = try XCTUnwrap(state.pages[1].recognition)
        XCTAssertTrue(read.engine.hasPrefix("vision-"), read.engine)
        XCTAssertEqual(read.basis, RecognitionBasis.digest(of: state.pages[1].strokes.map(\.id)))

        // Everything is current: a second pass writes nothing.
        let before = try revisionCount(vault)
        let again = try cli(["recognize", "--all", "--json"] + args(vault, key))
        XCTAssertEqual(again.status, 0, again.err)
        XCTAssertEqual(try revisionCount(vault), before)

        // --force replaces Notability's text too.
        let forced = try cli(["recognize", note.uuidString, "--force"] + args(vault, key))
        XCTAssertEqual(forced.status, 0, forced.err)
        state = try vault.reconstruct(noteId: note)
        XCTAssertEqual(state.pages.first { $0.id == pages[0] }?.recognition?.basis,
                       RecognitionBasis.digest(of: state.pages[0].strokes.map(\.id)))
    }

    func testImportRecognizesOnlyPagesNotabilityNeverIndexed() throws {
        let (vault, key, _, _) = try vaultWithImportedText()
        let r = try cli(["import", "notability", CLIImportSearchTests.zipNote, "--recognize", "missing", "--json"]
                        + args(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        let out = try XCTUnwrap(r.json as? [String: Any])
        let recognized = try XCTUnwrap(out["recognized"] as? [[String: Any]])
        XCTAssertEqual(recognized.count, (out["summary"] as? [String: Any])?["imported"] as? Int)
        XCTAssertTrue(recognized.allSatisfy { $0["error"] == nil }, "\(recognized)")
        for entry in recognized {
            let state = try vault.reconstruct(noteId: try XCTUnwrap(UUID(uuidString: entry["note"] as! String)))
            for (i, page) in state.pages.enumerated() where (entry["read"] as? [Int])?.contains(i + 1) == true {
                XCTAssertEqual(page.recognition?.basis, RecognitionBasis.digest(of: page.strokes.map(\.id)))
            }
            // Pages Notability indexed keep its recognition (no basis).
            for page in state.pages where page.recognition != nil && page.recognition?.basis == nil {
                XCTAssertFalse(page.recognition?.engine.hasPrefix("vision-") ?? true)
            }
        }
    }
    #else
    func testRecognizeIsRefusedWithoutVision() throws {
        let (vault, key, _, _) = try vaultWithImportedText()
        let before = try revisionCount(vault)
        let r = try cli(["recognize", "--all"] + args(vault, key))
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("Vision") && r.err.contains("macOS"), r.err)
        XCTAssertEqual(try revisionCount(vault), before)

        // The import is refused before anything is imported.
        let notes = try vault.noteIDs()
        let i = try cli(["import", "notability", CLIImportSearchTests.zipNote, "--recognize", "missing"] + args(vault, key))
        XCTAssertEqual(i.status, 1)
        XCTAssertTrue(i.err.contains("Vision"), i.err)
        XCTAssertEqual(try vault.noteIDs(), notes)
        // Without --recognize, or as a dry run, the import works.
        let dry = try cli(["import", "notability", CLIImportSearchTests.zipNote, "--recognize", "missing", "--dry-run",
                           "--json"] + args(vault, key))
        XCTAssertEqual(dry.status, 0, dry.err)
        XCTAssertNotNil((dry.json as? [String: Any])?["recognized"] as? [[String: Any]])
        XCTAssertEqual(try vault.noteIDs(), notes)
    }
    #endif
}
