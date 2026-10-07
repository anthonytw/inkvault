import Age
import Foundation
import FuzzSupport
import XCTest
@testable import Sempere

/// Quick capture without unlocking (format.md §11, docs/quick-capture.md).
final class CaptureInboxTests: VaultTestCase {
    let audio = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    let started = Date(timeIntervalSince1970: 1_800_000_000)

    func deviceState() -> URL { tmp.appendingPathComponent("device-\(UUID().uuidString).json") }

    /// A profile made while unlocked, then the vault reopened with no identity.
    func setUp(notebook: String = "Inbox") throws -> (identity: NativeIdentity, profile: CaptureProfile, locked: Vault) {
        try XCTSkipUnless(postQuantumAvailable)
        let id = pqIdentity()
        let vault = try makeVault(id)
        let profile = try vault.captureProfile(device: DeviceID("0badf00d")!, notebook: notebook)
        return (id, profile, try Vault.open(at: vault.url))
    }

    func transcript(_ capture: UUID) -> Transcript {
        TranscriptBuilder.transcript(recording: CaptureAdoption.ids(for: capture).recording, engine: "apple-speechtranscriber-26.7",
                                     language: "en-US", created: started,
                                     segments: [.init(start: 0, end: 1, text: "Buy milk.", confidence: 0.9,
                                                      words: [.init("Buy", start: 0, end: 0.4), .init("milk.", start: 0.4, end: 1)])])
    }

    /// The profile holds only public recipients and the capture key, never
    /// the secret; captures are written with the vault locked and read back
    /// with the identity.
    func testCaptureWithoutUnlockingIsAdoptedWithTheIdentity() throws {
        let (identity, profile, locked) = try setUp()
        XCTAssertTrue(locked.isLocked)
        XCTAssertNotEqual(profile.key, try Vault.open(at: locked.url, identities: [identity]).requireSecret().bytes)
        let writer = try CaptureWriter(profile: profile)
        let id = UUID()
        let sealed = try writer.seal(audio: audio, started: started, title: nil, id: id, created: started)
        XCTAssertNil(sealed.data.range(of: audio.prefix(64)), "nothing in the clear")
        try CaptureWriter.store(sealed, in: locked.inboxURL)
        XCTAssertEqual(try locked.inboxEntries().map(\.id), [id])
        XCTAssertThrowsError(try locked.readCapture(id), "a locked vault cannot read captures")

        // Stock age decrypts it with the identity, as every vault file.
        let plain = try AgeFile.decrypt(sealed.data, with: [identity])
        let line = plain[plain.startIndex + 37..<plain.firstIndex(of: 0x0A)!]
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(line)))
        XCTAssertEqual(plain.suffix(audio.count), audio)

        let vault = try Vault.open(at: locked.url, identities: [identity])
        let r = vault.adoptCapture(id, deviceState: deviceState(), app: "test/1")
        XCTAssertNil(r.error)
        XCTAssertTrue(r.created)
        let ids = CaptureAdoption.ids(for: id)
        let state = try vault.reconstruct(noteId: ids.note)
        XCTAssertEqual(state.meta.title, CaptureWriter.defaultTitle(started))
        XCTAssertEqual(state.meta.notebook, "Inbox")
        XCTAssertEqual(state.pages.map(\.id), [ids.page])
        let rec = try XCTUnwrap(state.recordings.first)
        XCTAssertEqual(rec.id, ids.recording)
        XCTAssertEqual(rec.started, started)
        XCTAssertNil(rec.transcript)
        XCTAssertEqual(try vault.readBlob(note: ids.note, rec.blob), audio)
        XCTAssertEqual(try vault.inboxEntries().count, 0, "the inbox file is deleted once adopted")
        XCTAssertEqual(try vault.loadNote(ids.note).revisions.count, 1, "one delta")
    }

    /// A transcript made later (background transcription, or the next time
    /// the app runs) is added to the adopted recording.
    func testTranscriptAddedLater() throws {
        let (identity, profile, locked) = try setUp()
        let writer = try CaptureWriter(profile: profile)
        let id = UUID()
        try CaptureWriter.store(try writer.seal(audio: audio, started: started, id: id), in: locked.inboxURL)
        let vault = try Vault.open(at: locked.url, identities: [identity])
        XCTAssertNil(vault.adoptCapture(id, deviceState: deviceState(), app: "test/1").error)

        try CaptureWriter.store(try writer.seal(transcript: transcript(id), capture: id), in: locked.inboxURL)
        let r = vault.adoptCapture(id, deviceState: deviceState(), app: "test/1")
        XCTAssertNil(r.error)
        XCTAssertFalse(r.created)
        XCTAssertTrue(r.transcript)
        let ids = CaptureAdoption.ids(for: id)
        let rec = try XCTUnwrap(try vault.reconstruct(noteId: ids.note).recordings.first)
        let t = try Transcript.decode(try vault.readBlob(note: ids.note, try XCTUnwrap(rec.transcript)))
        XCTAssertEqual(t.segments.first?.text, "Buy milk.")
        XCTAssertEqual(try vault.inboxEntries().count, 0)
    }

    func testTranscriptBeforeItsCaptureWaitsAndBothTogetherAreOneDelta() throws {
        let (identity, profile, locked) = try setUp(notebook: "Voice/Quick")
        let writer = try CaptureWriter(profile: profile)
        let id = UUID()
        try CaptureWriter.store(try writer.seal(transcript: transcript(id), capture: id), in: locked.inboxURL)
        let vault = try Vault.open(at: locked.url, identities: [identity])
        let early = vault.adoptCapture(id, deviceState: deviceState(), app: "test/1")
        XCTAssertNil(early.error)
        XCTAssertNil(early.file)
        XCTAssertEqual(try vault.inboxEntries().first?.kinds, [.transcript], "kept until its capture arrives")

        try CaptureWriter.store(try writer.seal(audio: audio, started: started, title: "Groceries", id: id), in: locked.inboxURL)
        let r = vault.adoptCapture(id, deviceState: deviceState(), app: "test/1")
        XCTAssertNil(r.error)
        let ids = CaptureAdoption.ids(for: id)
        let state = try vault.reconstruct(noteId: ids.note)
        XCTAssertEqual(state.meta.title, "Groceries")
        XCTAssertEqual(state.meta.notebook, "Voice/Quick")
        XCTAssertNotNil(state.recordings.first?.transcript)
        XCTAssertEqual(try vault.loadNote(ids.note).revisions.count, 1)
        XCTAssertTrue(try vault.inboxEntries().isEmpty)
    }

    /// Two devices adopting the same capture write the same note; adopting
    /// twice (the inbox file not deleted yet) adds nothing.
    func testAdoptionIsIdempotentAcrossDevices() throws {
        let (identity, profile, locked) = try setUp()
        let writer = try CaptureWriter(profile: profile)
        let id = UUID()
        let sealed = try writer.seal(audio: audio, started: started, id: id)
        try CaptureWriter.store(sealed, in: locked.inboxURL)
        let vault = try Vault.open(at: locked.url, identities: [identity])
        XCTAssertNil(vault.adoptCapture(id, deviceState: deviceState(), app: "a").error)
        try CaptureWriter.store(sealed, in: locked.inboxURL)   // the other device's copy, still in its inbox
        let again = vault.adoptCapture(id, deviceState: deviceState(), app: "b")
        XCTAssertNil(again.error)
        XCTAssertNil(again.file, "nothing new to write")
        let state = try vault.reconstruct(noteId: CaptureAdoption.ids(for: id).note)
        XCTAssertEqual(state.recordings.count, 1)
        XCTAssertEqual(state.pages.count, 1)
    }

    /// Anyone can encrypt to the public recipients; without the capture key
    /// (a holder of the vault secret) a capture does not verify and is kept,
    /// never adopted. A capture renamed to another id fails too.
    func testForgedOrRenamedCapturesAreRefused() throws {
        let (identity, profile, locked) = try setUp()
        var forger = profile
        forger.key = Data(repeating: 7, count: 32)
        let id = UUID()
        try CaptureWriter.store(try CaptureWriter(profile: forger).seal(audio: audio, started: started, id: id), in: locked.inboxURL)
        let vault = try Vault.open(at: locked.url, identities: [identity])
        let r = vault.adoptCapture(id, deviceState: deviceState(), app: "test/1")
        XCTAssertEqual(r.error, CaptureError.badTag.description)
        XCTAssertFalse(try vault.noteIDs().contains(CaptureAdoption.ids(for: id).note))
        XCTAssertEqual(try vault.inboxEntries().count, 1, "kept and reported")

        let good = try CaptureWriter(profile: profile).seal(audio: audio, started: started, id: UUID())
        let other = UUID()
        try good.data.write(to: locked.inboxURL.appendingPathComponent(CaptureFile.name(other, .capture)))
        XCTAssertEqual(vault.adoptCapture(other, deviceState: deviceState(), app: "test/1").error, CaptureError.badTag.description)
    }

    /// Removing a recipient rotates the secret and with it the capture key:
    /// a profile from before no longer verifies.
    func testKeyRotationRevokesOldProfiles() throws {
        let (identity, profile, _) = try setUp()
        var vault = try Vault.open(at: vaultURL(), identities: [identity])
        let second = pqIdentity()
        _ = try vault.addRecipient(second.recipient, label: "second")
        _ = try vault.removeRecipient(second.recipient)
        XCTAssertNotEqual(try vault.captureKey().bytes, profile.key)
        let id = UUID()
        try CaptureWriter.store(try CaptureWriter(profile: profile).seal(audio: audio, started: started, id: id), in: vault.inboxURL)
        XCTAssertEqual(vault.adoptCapture(id, deviceState: deviceState(), app: "t").error, CaptureError.badTag.description)
    }

    func testFileNamesAndFraming() throws {
        let id = UUID()
        XCTAssertEqual(CaptureFile.parse(name: CaptureFile.name(id, .capture))?.id, id)
        XCTAssertEqual(CaptureFile.parse(name: CaptureFile.name(id, .transcript))?.kind, .transcript)
        for bad in ["x.capture.age", "\(id.uuidString).capture.age", "\(id.uuidString.lowercased()).audio.age", ".tmp", "a.b.c.d"] {
            XCTAssertNil(CaptureFile.parse(name: bad), bad)
        }
        let key = try CaptureKey(bytes: Data(repeating: 1, count: 32))
        let framed = try CaptureFile.frame(line: Data("{}".utf8), payload: Data([0x0A, 1, 2]), filename: "f", key: key)
        let (line, payload) = try CaptureFile.unframe(framed, filename: "f", key: key)
        XCTAssertEqual(line, Data("{}".utf8))
        XCTAssertEqual(payload, Data([0x0A, 1, 2]), "newlines in the audio are kept")
        XCTAssertThrowsError(try CaptureFile.unframe(framed, filename: "g", key: key)) { XCTAssertEqual($0 as? CaptureError, .badTag) }
        XCTAssertThrowsError(try CaptureFile.frame(line: Data("{\n}".utf8), payload: Data(), filename: "f", key: key))
        XCTAssertThrowsError(try CaptureKey(bytes: Data(count: 31)))
        XCTAssertEqual(CaptureWriter.defaultTitle(started, timeZone: TimeZone(identifier: "UTC")!), "Voice note 2027-01-15 08:00")
    }
}

/// Inbox files come from storage: hostile bytes must fail with a typed error.
extension SempereFuzzTests {
    func testFuzzCaptureFraming() throws {
        let key = try CaptureKey(bytes: Data(repeating: 9, count: 32))
        let manifest = CaptureManifest(id: UUID(), device: "0badf00d", vault: UUID(), created: Date(timeIntervalSince1970: 0),
                                       started: Date(timeIntervalSince1970: 0), title: "t", notebook: "Inbox",
                                       audio: BlobRef(content: Data([1, 2, 3]), type: "audio/mp4"))
        let seed = try CaptureFile.frame(line: try InkJSON.encoder().encode(manifest), payload: Data([1, 2, 3]), filename: "f", key: key)
        assertClean(Fuzz.run("capture", seeds: [seed, try InkJSON.encoder().encode(manifest)], quick: 1500) { input in
            // The tag check comes first; parse the JSON line directly too (as if the tag had passed).
            do { _ = try CaptureFile.unframe(input, filename: "f", key: key) } catch is CaptureError {} catch {
                return "untyped unframe error \(type(of: error))"
            }
            do { _ = try InkJSON.decoder().decode(CaptureManifest.self, from: input) } catch is DecodingError {} catch {
                return "untyped manifest error \(type(of: error))"
            }
            return nil
        })
    }
}
