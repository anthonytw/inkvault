import Age
import Foundation
import XCTest
@testable import Sempere

/// `notes show` and `notes restore` on a note with placed items and a
/// recording (attachments A1, `docs/cli.md`).
final class CLIAttachmentNotesTests: CLITestCase {
    func testShowCountsItemsAndRestoreSaysWhatItSetsBack() throws {
        let path = try copyFixtureVault()
        let access = ["--vault", path, "--identity", Self.fixtureKey]
        let identity = try IdentityFile.parse(String(contentsOfFile: Self.fixtureKey, encoding: .utf8))
        let vault = try Vault.open(at: URL(fileURLWithPath: path), identities: [identity])
        let note = UUID(), pageId = UUID()
        let state = tmp.appendingPathComponent("device.json")
        let audio = try vault.writeBlob(note: note, Data("synthetic audio".utf8), type: "audio/mp4")
        let box = Item.text(TextContent(size: 12, color: .black, runs: [TextRun("synthetic")]),
                            frame: Rect(x: 10, y: 10, w: 200, h: 30), z: "a0")
        let rec = Recording(id: UUID(), blob: audio, started: Date(timeIntervalSince1970: 1_790_000_000),
                            duration: 1, codec: "aac", title: "Lecture")
        try vault.apply(NoteOps.newNote(title: "Typed", pageId: pageId) + [.addItem(page: pageId, item: box),
                                                                            .addRecording(rec)],
                        to: note, deviceState: state, app: "test")
        let id = note.uuidString.lowercased()

        func show() throws -> [String: Any] {
            let r = try cli(["notes", "show", id, "--json"] + access)
            XCTAssertEqual(r.status, 0, r.err)
            let obj = try XCTUnwrap(r.json as? [String: Any])
            return try XCTUnwrap(obj["note"] as? [String: Any])
        }
        var shown = try show()
        XCTAssertEqual(shown["items"] as? Int, 1)
        XCTAssertEqual(shown["textItems"] as? Int, 1)
        XCTAssertEqual(shown["recordings"] as? Int, 1)
        let text = try cli(["notes", "show", id] + access)
        XCTAssertTrue(text.out.contains("Items:    1 (1 text box(es))   Recordings: 1"), text.out)

        let history = try cli(["notes", "history", id, "--json"] + access)
        let point = try XCTUnwrap((history.json as? [[String: Any]])?.first?["revision"] as? String)
        try vault.apply([.removeItem(page: pageId, itemId: box.id),
                         .setRecording(recordingId: rec.id, change: .title("Renamed"))],
                        to: note, deviceState: state, app: "test")
        shown = try show()
        XCTAssertEqual(shown["items"] as? Int, 0)

        // A restore that changes only items and recordings says so.
        let dry = try cli(["notes", "restore", id, "--to", point, "--dry-run"] + access)
        XCTAssertEqual(dry.status, 0, dry.err)
        XCTAssertTrue(dry.out.contains("re-add 1 item(s)"), dry.out)
        XCTAssertTrue(dry.out.contains("set back 1 recording(s)"), dry.out)
        let done = try cli(["notes", "restore", id, "--to", point] + access)
        XCTAssertEqual(done.status, 0, done.err)
        shown = try show()
        XCTAssertEqual(shown["items"] as? Int, 1)
        let again = try cli(["notes", "restore", id, "--to", point] + access)
        XCTAssertTrue(again.out.contains("nothing to write") || again.err.contains("nothing to write"), again.out + again.err)
    }
}
