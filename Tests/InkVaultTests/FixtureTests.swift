import Age
import Foundation
import XCTest
@testable import InkVault

/// The committed sample vault under `Fixtures/sample.inkvault` (see
/// `Fixtures/README.md`). Everything except the age randomness is fixed, so
/// regenerating changes ciphertext bytes but never content.
///
/// Regenerate with:
///
///     INKVAULT_REGENERATE_FIXTURE=1 swift test --filter FixtureTests/testRegenerateFixture
enum SampleFixture {
    static let passphrase = "inkvault-test"
    static let vaultId = UUID(uuidString: "5a3b1e00-1000-4000-8000-000000000001")!
    static let baseMillis: Int64 = 1_791_130_800_000            // 2026-10-04T16:20:00Z
    static let devA = DeviceID("a1b2c3d4")!
    static let devB = DeviceID("99ee00ff")!
    static let lecture = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let deleted = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let app = "inkvault-fixture/1"

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "f1c70000-0000-4000-8000-%012ld", n))! }
    static func at(_ offset: Int64) -> Date { Date(timeIntervalSince1970: Double(baseMillis + offset) / 1000) }

    static func stroke(_ n: Int, tool: InkTool = .pen, color: Color = Color(r: 0x1A, g: 0x1A, b: 0x1A)) -> Stroke {
        let pts = (0..<4).map { (i: Int) -> StrokePoint in
            let x = Double(50 + 20 * n + 10 * i)
            let y = Double(100 + 15 * i)
            return StrokePoint(x: x, y: y, t: Double(i) * 0.016, w: 2.5, h: 2.5, o: 1, f: 0.5, az: 0.25, al: 1.25)
        }
        return Stroke(id: id(100 + n), ink: Ink(tool: tool, color: color, width: 2.5), points: pts)
    }

    static func delta(_ note: UUID, _ dev: DeviceID, _ seq: Int, _ offset: Int64, _ ops: [Op]) -> Revision {
        Revision(noteId: note, device: dev, seq: seq, hlc: HLC(millis: baseMillis + offset, counter: 0)!,
                 wall: at(offset), app: app, body: .delta(ops: ops))
    }

    /// Writes the fixture vault at `url` (which must not exist yet).
    static func generate(at url: URL, identity: X25519Identity) throws {
        let vault = try Vault.create(at: url, recipients: [identity.recipient],
                                     labels: ["InkVault test fixture (throwaway, test-only key)"],
                                     identities: [identity], vaultId: vaultId, created: at(0))
        let p1 = id(1), p2 = id(2), q1 = id(3)
        // Lecture: devices A and B, a snapshot by A, then one uncovered delta.
        try vault.write(delta(lecture, devA, 1, 1000, [
            .addPage(Page(id: p1, order: "a0")), .setMeta(.title("Fixture lecture")), .setMeta(.paper(.ruled)),
            .addStroke(page: p1, stroke: stroke(1)), .addStroke(page: p1, stroke: stroke(2)),
        ]))
        try vault.write(delta(lecture, devB, 1, 2000, [
            .addStroke(page: p1, stroke: stroke(3, tool: .marker, color: Color(r: 0xFF, g: 0xD6, b: 0x0A, a: 0x80))),
            .setMeta(.tags(["fixture"])),
        ]))
        try vault.write(delta(lecture, devB, 2, 3000, [
            .removeStroke(page: p1, strokeId: id(101)), .addPage(Page(id: p2, order: "a1")),
            .addStroke(page: p2, stroke: stroke(4)),
        ]))
        var clock = HybridClock()
        try vault.snapshot(noteId: lecture, device: devA, clock: &clock, wall: at(4000), app: app)
        try vault.write(delta(lecture, devA, 3, 5000, [.addStroke(page: p2, stroke: stroke(5))]))
        // Deleted note.
        try vault.write(delta(deleted, devA, 1, 6000, [
            .addPage(Page(id: q1, order: "a0")), .setMeta(.title("Fixture deleted")),
            .addStroke(page: q1, stroke: stroke(6)),
        ]))
        try vault.write(delta(deleted, devB, 1, 7000, [.deleteNote]))
        try vault.writeIdentityFile(identity, passphrase: passphrase, workFactor: 15, created: at(0))
    }
}

final class FixtureTests: XCTestCase {
    static var sourceFixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    static func bundled(_ name: String) throws -> URL {
        let url = Bundle.module.resourceURL?.appendingPathComponent("Fixtures").appendingPathComponent(name)
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name)"])
        }
        return url
    }

    func testFixtureOpensAndReconstructs() throws {
        let keyText = try String(contentsOf: Self.bundled("sample.key"), encoding: .utf8)
        let identity = try IdentityFile.parse(keyText)
        let vault = try Vault.open(at: Self.bundled("sample.inkvault"), identities: [identity])
        XCTAssertEqual(vault.vaultId, SampleFixture.vaultId)
        XCTAssertEqual(vault.recipients.map(\.key), [identity.recipient.string])
        XCTAssertEqual(try vault.noteIDs(), [SampleFixture.lecture, SampleFixture.deleted])
        XCTAssertEqual(try vault.revisionNames(of: SampleFixture.lecture).map(\.kind),
                       [.delta, .delta, .delta, .snapshot, .delta])

        let lecture = try vault.reconstruct(noteId: SampleFixture.lecture)
        XCTAssertEqual(lecture.meta.title, "Fixture lecture")
        XCTAssertEqual(lecture.meta.tags, ["fixture"])
        XCTAssertEqual(lecture.meta.paper.kind, .ruled)
        XCTAssertFalse(lecture.deleted)
        XCTAssertEqual(lecture.pages.map { $0.strokes.count }, [2, 2])
        XCTAssertEqual(lecture.pages.flatMap { $0.strokes.map(\.id) },
                       [102, 103, 104, 105].map(SampleFixture.id))

        let gone = try vault.reconstruct(noteId: SampleFixture.deleted)
        XCTAssertEqual(gone.meta.title, "Fixture deleted")
        XCTAssertTrue(gone.deleted)
        XCTAssertEqual(gone.pages.map { $0.strokes.count }, [1])

        let report = vault.verify()
        XCTAssertTrue(report.isHealthy, "\(report)")
        XCTAssertEqual(report.counts[.ok], 8)   // 7 revisions + 1 identity file

        // Same content as a fresh generation (only ciphertext is random).
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fresh = tmp.appendingPathComponent("sample.inkvault")
        try SampleFixture.generate(at: fresh, identity: identity)
        let regenerated = try Vault.open(at: fresh, identities: [identity])
        for note in try vault.noteIDs() {
            XCTAssertEqual(try regenerated.revisionNames(of: note), try vault.revisionNames(of: note))
            for name in try vault.revisionNames(of: note) {
                XCTAssertEqual(try Self.asWrittenBeforeTagSets(regenerated.readRevision(noteId: note, name: name)),
                               try vault.readRevision(noteId: note, name: name), "\(name)")
            }
        }
    }

    /// The committed fixture predates per-tag merging (format.md §5.4.1): its
    /// lecture snapshot has no `tagSet` and keeps the legacy `tags` register in
    /// `meta.tags` and `clocks.tags`, so it doubles as a legacy-vault test. A
    /// fresh snapshot differs only there; this maps it back.
    static func asWrittenBeforeTagSets(_ r: Revision) -> Revision {
        guard case .snapshot(let included, var state) = r.body, let set = state.tagSet else { return r }
        state.tagSet = nil
        state.meta.tags = set.legacy?.tags ?? []
        state.clocks?["tags"] = set.legacy?.clock
        var out = r
        out.body = .snapshot(included: included, state: state)
        return out
    }

    /// The legacy fixture reads with per-tag semantics: its `setMeta(tags)` is
    /// a baseline that a current writer's `removeTag` and `addTag` build on.
    func testLegacyFixtureTagsMergeWithPerTagOps() throws {
        let identity = try IdentityFile.parse(String(contentsOf: Self.bundled("sample.key"), encoding: .utf8))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let copy = tmp.appendingPathComponent("sample.inkvault")
        try FileManager.default.copyItem(at: Self.bundled("sample.inkvault"), to: copy)
        let vault = try Vault.open(at: copy, identities: [identity])
        let device = tmp.appendingPathComponent("device.json")
        let lecture = SampleFixture.lecture
        guard case .snapshot(_, let old)? = try vault.revisionNames(of: lecture).filter({ $0.kind == .snapshot })
            .first.map({ try vault.readRevision(noteId: lecture, name: $0).body }) else { return XCTFail("no snapshot") }
        XCTAssertNil(old.tagSet)
        var state = try vault.reconstruct(noteId: lecture)
        XCTAssertEqual(state.tagSet?.legacy?.tags, ["fixture"])
        try vault.apply([try XCTUnwrap(NoteOps.addTag("exam", to: state))], to: lecture, deviceState: device, app: "t")
        state = try vault.reconstruct(noteId: lecture)
        XCTAssertEqual(state.meta.tags, ["fixture", "exam"])
        try vault.apply([try XCTUnwrap(NoteOps.removeTag("Fixture", from: state))], to: lecture,
                        deviceState: device, app: "t")
        XCTAssertEqual(try vault.summary(of: lecture).tags, ["exam"])
        var clock = HybridClock()
        try vault.snapshot(noteId: lecture, device: DeviceID("0f0f0f0f")!, clock: &clock, wall: Date(), app: "t")
        XCTAssertEqual(try vault.summary(of: lecture).tags, ["exam"])
    }

    func testFixtureIdentityFileOpensWithPassphrase() throws {
        let identity = try IdentityFile.parse(String(contentsOf: Self.bundled("sample.key"), encoding: .utf8))
        let locked = try Vault.open(at: Self.bundled("sample.inkvault"))
        XCTAssertEqual(try locked.identityFiles(), [identity.recipient])
        let read = try locked.readIdentityFile(recipient: identity.recipient, passphrase: SampleFixture.passphrase)
        XCTAssertEqual(read.string, identity.string)
    }

    /// Rewrites Fixtures/sample.inkvault in the source tree, reusing
    /// Fixtures/sample.key (or creating it on first run).
    func testRegenerateFixture() throws {
        guard ProcessInfo.processInfo.environment["INKVAULT_REGENERATE_FIXTURE"] == "1" else {
            throw XCTSkip("set INKVAULT_REGENERATE_FIXTURE=1 to rewrite the fixture vault")
        }
        let dir = Self.sourceFixtures
        let keyURL = dir.appendingPathComponent("sample.key")
        let identity: X25519Identity
        if let text = try? String(contentsOf: keyURL, encoding: .utf8) {
            identity = try IdentityFile.parse(text)
        } else {
            identity = X25519Identity()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try ("# TEST-ONLY throwaway identity for Tests/InkVaultTests/Fixtures. Never use it for real notes.\n"
                + IdentityFile.render(identity, created: SampleFixture.at(0)))
                .write(to: keyURL, atomically: true, encoding: .utf8)
        }
        let vaultURL = dir.appendingPathComponent("sample.inkvault")
        try? FileManager.default.removeItem(at: vaultURL)
        try SampleFixture.generate(at: vaultURL, identity: identity)
    }
}
