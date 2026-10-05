import Age
import Foundation
import XCTest
@testable import InkVault

final class EditTests: VaultTestCase {
    var stateURL: URL { tmp.appendingPathComponent("device.json") }

    func testNewNoteThenMetaEditsReconstruct() throws {
        let vault = try makeVault(X25519Identity())
        let id = UUID()
        try vault.apply(NoteOps.newNote(title: "Physics", notebook: " Uni ", tags: ["a", " a ", ""]), to: id,
                        deviceState: stateURL, app: "test")
        var s = try vault.summary(of: id)
        XCTAssertEqual(s.title, "Physics")
        XCTAssertEqual(s.notebook, "Uni")
        XCTAssertEqual(s.tags, ["a"])
        XCTAssertEqual(s.pages, 1)

        try vault.apply([.setMeta(.notebook("Work")), .setMeta(.tags(["a", "b"]))], to: id,
                        deviceState: stateURL, app: "test")
        try vault.apply([.deleteNote], to: id, deviceState: stateURL, app: "test")
        s = try vault.summary(of: id)
        XCTAssertEqual(s.notebook, "Work")
        XCTAssertEqual(s.tags, ["a", "b"])
        XCTAssertTrue(s.deleted)

        try vault.apply([.restoreNote], to: id, deviceState: stateURL, app: "test")
        XCTAssertFalse(try vault.summary(of: id).deleted)
        XCTAssertEqual(try vault.revisionNames(of: id).map(\.seq), [1, 2, 3, 4])
    }

    func testClockSurvivesRestartAndBeatsEarlierRevisions() throws {
        let vault = try makeVault(X25519Identity())
        let id = UUID()
        // A revision from another device stamped in the future (within drift).
        let future = Date().addingTimeInterval(3600)
        let other = DeviceID.random()
        let hlc = try XCTUnwrap(HLC(millis: Int64(future.timeIntervalSince1970 * 1000), counter: 0))
        try vault.write(Revision(noteId: id, device: other, seq: 1, hlc: hlc, wall: future, app: "x",
                                 body: .delta(ops: [.setMeta(.title("remote"))])))
        try vault.apply([.setMeta(.title("local"))], to: id, deviceState: stateURL, app: "test")
        XCTAssertEqual(try vault.summary(of: id).title, "local")
        let saved = try DeviceState.loadOrCreate(at: stateURL)
        XCTAssertGreaterThan(saved.millis, hlc.millis - 1)
    }

    func testRefusesLockedAndWriteOnlyVaults() throws {
        let id = X25519Identity()
        let vault = try makeVault(id)
        let locked = try Vault.open(at: vault.url)
        XCTAssertThrowsError(try locked.apply([.deleteNote], to: UUID(), deviceState: stateURL, app: "t"))
        let writeOnly = try Vault.create(at: vaultURL("W"), recipients: [id.recipient])
        XCTAssertThrowsError(try writeOnly.apply([.deleteNote], to: UUID(), deviceState: stateURL, app: "t"))
    }

    func testNormalizers() {
        XCTAssertEqual(NoteOps.normalizedTags([" x", "x", "y ", "  "]), ["x", "y"])
        XCTAssertNil(NoteOps.normalizedNotebook("  "))
        XCTAssertEqual(NoteOps.normalizedNotebook(" A "), "A")
    }
}
