import Age
import AVFoundation
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Quick voice notes (docs/quick-capture.md): capture with only the stored
/// profile (no key, no unlock), delivery to the vault's inbox or the queue,
/// interruptions, transcripts now or later, adoption into notes.
@Suite(.serialized)
@MainActor
struct QuickCaptureTests {
    static func temp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    /// A fixture vault copy, its key, and a quick-capture instance whose
    /// stored profile was made from it while unlocked.
    static func setUp(transcribe: Bool = true, transcriber: (any RecordingTranscribing)? = FakeTranscriber())
        throws -> (url: URL, key: URL, identity: NativeIdentity, capture: QuickCapture, center: NotificationCenter) {
        let (url, key) = try AppModelTests.fixtureVault()
        let identity = try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))
        let vault = try Vault.open(at: url, identities: [identity])
        let profile = try vault.captureProfile(device: DeviceID("0badf00d")!)
        let store = MemoryCaptureProfileStore()
        try store.save(StoredCaptureProfile(profile: profile, vaultName: "sample",
                                            bookmark: try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
                                            transcribe: transcribe))
        let center = NotificationCenter()
        let qc = QuickCapture()
        qc.store = store
        qc.backend = { FakeCapture() }
        qc.microphoneAllowed = { true }
        qc.transcriber = transcriber
        qc.root = temp("qc-root")
        qc.queueRoot = temp("qc-queue")
        qc.center = center
        qc.showsActivity = false
        return (url, key, identity, qc, center)
    }

    static func inbox(_ vault: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: vault.appendingPathComponent("inbox").path)) ?? []).sorted()
    }

    static func leftovers(_ root: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    }

    /// The core promise: capture needs nothing but the profile. Nothing is
    /// unlocked here; the sealed files read back with the identity, and no
    /// plaintext audio is left on disk.
    @Test func captureWithoutUnlockingSealsAudioAndTranscriptIntoTheInbox() async throws {
        let (url, _, identity, qc, _) = try Self.setUp()
        try await qc.start()
        #expect(qc.state == .recording)
        let outcome = try await qc.stop()
        #expect(outcome.error == nil)
        #expect(outcome.delivery == .vault)
        #expect(outcome.transcribed)
        #expect(qc.state == .idle)
        #expect(Self.inbox(url) == [CaptureFile.name(outcome.id, .capture), CaptureFile.name(outcome.id, .transcript)].sorted())
        #expect(Self.leftovers(qc.root).isEmpty, "no plaintext audio is kept")
        // Encrypted on disk: the tone's bytes are not there.
        let tone = try Data(contentsOf: RecordingTests.tone)
        let sealed = try Data(contentsOf: url.appendingPathComponent("inbox/\(CaptureFile.name(outcome.id, .capture))"))
        #expect(sealed.range(of: tone.prefix(256)) == nil)
        // Readable later with the key.
        let vault = try Vault.open(at: url, identities: [identity])
        let pending = try vault.readCapture(outcome.id)
        #expect(pending.audio == tone)
        #expect(pending.manifest?.notebook == "Inbox")
        #expect(pending.manifest?.title.hasPrefix("Voice note ") == true)
        #expect(pending.transcript?.segments.first?.words?.map(\.t) == ["Linear", "maps."])
    }

    /// A voice note started and stopped on the Lock Screen is assembled and
    /// read back from closed files before any unlock: its files must use a
    /// class that is readable while locked (after the first unlock), not
    /// `completeUnlessOpen`, under which sealing would fail and the note be
    /// lost. In-note recordings keep `completeUnlessOpen`. (The simulator has
    /// no Data Protection, so the class itself is what is checked.)
    @Test func voiceNotesAreRecordedInAClassReadableWhileLocked() async throws {
        let (_, _, _, qc, _) = try Self.setUp(transcribe: false)
        try await qc.start()
        let session = try #require(qc.session)
        #expect(session.protection == .completeUntilFirstUserAuthentication)
        _ = try await qc.stop()
        let inNote = RecordingSession(noteID: UUID(), format: .default, root: Self.temp("rec"), backend: FakeCapture())
        #expect(inNote.protection == .completeUnlessOpen)
        #expect(RecordingSession.writingOption(.completeUntilFirstUserAuthentication) == .completeFileProtectionUntilFirstUserAuthentication)
        #expect(RecordingSession.writingOption(.completeUnlessOpen) == .completeFileProtectionUnlessOpen)
    }

    /// A call during a voice note pauses it; it resumes and is sealed whole.
    @Test func interruptionDuringAVoiceNote() async throws {
        let (url, _, _, qc, center) = try Self.setUp(transcribe: false)
        try await qc.start()
        let session = try #require(qc.session)
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: RecordingTests.interruption(.began))
        #expect(await TS.waitUntil { session.state == .interrupted })
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: RecordingTests.interruption(.ended, resume: true))
        #expect(await TS.waitUntil { session.state == .recording })
        let outcome = try await qc.stop()
        #expect(outcome.delivery == .vault)
        #expect(Self.inbox(url) == [CaptureFile.name(outcome.id, .capture)])
    }

    /// When the vault folder cannot be reached the sealed capture waits in a
    /// local queue (encrypted) and moves into the vault later.
    @Test func unreachableVaultQueuesTheCapture() async throws {
        let (url, _, _, qc, _) = try Self.setUp(transcribe: false)
        // The bookmark now names a folder that is not the vault (gone, renamed, another vault).
        let other = Self.temp("not-the-vault")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        var stored = try #require(try qc.store.load())
        stored.bookmark = try other.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try qc.store.save(stored)
        try await qc.start()
        let outcome = try await qc.stop()
        #expect(outcome.delivery == .queued)
        let vaultID = stored.profile.vaultId
        #expect(Self.leftovers(qc.queueFolder(vaultID)) == [CaptureFile.name(outcome.id, .capture)])
        #expect(Self.inbox(url).isEmpty)
        #expect(qc.flushQueue(into: url, vaultId: vaultID, coordinated: false) == 1)
        #expect(Self.inbox(url) == [CaptureFile.name(outcome.id, .capture)])
        #expect(Self.leftovers(qc.queueFolder(vaultID)).isEmpty)
    }

    /// The widget and Control Center fired together: the second start used to
    /// pass the idle check during the first one's microphone prompt and start
    /// a second recording that nothing could stop.
    @Test func aSecondStartDuringTheFirstIsRefused() async throws {
        let (_, _, _, qc, _) = try Self.setUp()
        let gate = AsyncStream<Void>.makeStream()
        qc.microphoneAllowed = {
            for await _ in gate.stream { break }
            return true
        }
        let first = Task { try await qc.start() }
        #expect(await TS.waitUntil { qc.state == .starting })
        await #expect(throws: QuickCaptureError.alreadyRecording) { try await qc.start() }
        gate.continuation.yield()
        try await first.value
        #expect(qc.state == .recording)
        _ = try await qc.stop()
        #expect(qc.state == .idle)
    }

    @Test func nothingStartsWithoutAProfile() async throws {
        let qc = QuickCapture()
        qc.store = MemoryCaptureProfileStore()
        qc.showsActivity = false
        await #expect(throws: QuickCaptureError.notSetUp) { try await qc.start() }
        await #expect(throws: QuickCaptureError.notRecording) { try await qc.stop() }
        #expect(qc.state == .idle, "a refused start leaves nothing claimed")
    }

    /// The model adopts the inbox once the vault is unlocked; a voice note
    /// captured without a transcript is transcribed then (task: "transcript
    /// added later").
    @Test func unlockingAdoptsVoiceNotesAndTranscribesThoseWithout() async throws {
        let (url, key, _, qc, _) = try Self.setUp(transcribe: false)
        try await qc.start()
        let outcome = try await qc.stop()
        var stored = try #require(try qc.store.load())
        stored.transcribe = true   // transcribe on this device from now on
        try qc.store.save(stored)

        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
        model.blobCacheFolder = Self.temp("blobs")
        model.transcriber = FakeTranscriber()
        model.quickCapture = qc
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.inboxAdoption == nil && model.capturesAdopted == 1 })
        let ids = CaptureAdoption.ids(for: outcome.id)
        let vault = try #require(model.vault)
        #expect(await TS.waitUntil(timeout: .seconds(10)) {
            (try? vault.reconstruct(noteId: ids.note))?.recordings.first?.transcript != nil
        })
        let state = try vault.reconstruct(noteId: ids.note)
        #expect(state.meta.notebook == "Inbox")
        #expect(state.meta.title.hasPrefix("Voice note "))
        #expect(state.recordings.map(\.id) == [ids.recording])
        #expect(Self.inbox(url).isEmpty, "adopted captures leave the inbox")
        #expect(model.notes.contains { $0.id == ids.note })
        #expect(model.inboxProblem == nil)
    }

    /// iCloud Drive uploads files in any order, so a voice note's transcript
    /// can reach a device before its capture. The transcript waits and nothing
    /// is written: a transcript blob alone would make a note folder without
    /// revisions, which `requireLocal` refuses in iCloud Drive, so the capture
    /// could never be adopted there. Once the capture arrives, both are.
    @Test func aTranscriptBeforeItsCaptureWritesNothingUntilTheCaptureArrives() async throws {
        let (url, key, _, qc, _) = try Self.setUp(transcribe: false)
        let writer = try CaptureWriter(profile: try #require(try qc.store.load()).profile)
        let id = UUID()
        let ids = CaptureAdoption.ids(for: id)
        let inbox = url.appendingPathComponent(CaptureFile.folderName, isDirectory: true)
        let transcript = Transcript(recording: ids.recording, engine: "test", language: "en", created: Date(),
                                    segments: [.init(start: 0, end: 1, text: "Linear maps.")])
        try CaptureWriter.store(try writer.seal(transcript: transcript, capture: id), in: inbox)

        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
        model.blobCacheFolder = Self.temp("blobs")
        model.quickCapture = qc
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.inboxAdoption == nil })
        let folder = url.appendingPathComponent("notes/\(ids.note.uuidString.lowercased())")
        #expect(!FileManager.default.fileExists(atPath: folder.path), "nothing is written while the transcript waits")
        #expect(Self.inbox(url) == [CaptureFile.name(id, .transcript)])
        #expect(model.inboxProblem == nil)

        let tone = try Data(contentsOf: RecordingTests.tone)
        try CaptureWriter.store(try writer.seal(audio: tone, started: Date(), id: id), in: inbox)
        #expect(await model.adoptInbox() == 1)
        let state = try #require(model.vault).reconstruct(noteId: ids.note)
        #expect(state.recordings.map(\.id) == [ids.recording])
        #expect(state.recordings.first?.transcript != nil)
        #expect(Self.inbox(url).isEmpty)
        #expect(model.inboxProblem == nil)
    }

    @Test func enablingStoresAProfileWithoutTheIdentityAndRefreshFollowsKeyChanges() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let qc = QuickCapture()
        qc.store = MemoryCaptureProfileStore()
        qc.showsActivity = false
        model.quickCapture = qc
        try await model.openVault(at: url)
        let keyText = try String(contentsOf: key, encoding: .utf8)
        try await model.unlock(identityText: keyText)
        try model.enableQuickCapture(notebook: "Voice/Inbox", transcribe: true)
        let stored = try #require(try qc.store.load())
        #expect(model.quickCaptureIsForOpenVault)
        #expect(stored.profile.notebook == "Voice/Inbox")
        #expect(stored.profile.recipients == model.vault?.recipients.map(\.key))
        let data = try JSONEncoder().encode(stored)
        #expect(String(decoding: data, as: UTF8.self).contains("AGE-SECRET-KEY") == false, "never the identity")
        // A stale key in the profile is replaced on the next unlock.
        var old = stored
        old.profile.key = Data(repeating: 0, count: 32)
        try qc.store.save(old)
        model.refreshQuickCaptureProfile()
        #expect(try qc.store.load()?.profile.key == stored.profile.key)
        try model.disableQuickCapture()
        #expect(try qc.store.load() == nil)
    }

    /// Removing a device key in the key window rotates the capture key; the
    /// stored profile follows at once, not at the next unlock, so a voice note
    /// recorded in between is still adopted.
    @Test func removingADeviceKeyRefreshesTheProfileAtOnce() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let qc = QuickCapture()
        qc.store = MemoryCaptureProfileStore()
        qc.showsActivity = false
        model.quickCapture = qc
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        try model.enableQuickCapture()
        let other = try NativeIdentity.generate(.postQuantum)
        try await model.addDeviceKey(recipient: other.recipient.string, label: "Old iPad")
        #expect(try qc.store.load()?.profile.recipients.contains(other.recipient.string) == true, "added: the new key reads captures too")
        let before = try #require(try qc.store.load()).profile.key
        try await model.removeDeviceKey(other.recipient.string)
        let after = try #require(try qc.store.load()).profile
        #expect(after.key != before)
        let vault = try #require(model.vault)
        #expect(after.key == (try vault.captureKey()).bytes)
        #expect(!after.recipients.contains(other.recipient.string))
    }

    /// A voice note interrupted by a crash is sealed from its finished
    /// segments at the next launch, and its plaintext deleted.
    @Test func sweepSealsWhatACrashLeft() async throws {
        let (url, _, _, qc, _) = try Self.setUp(transcribe: false)
        let id = UUID()
        let folder = qc.root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: RecordingTests.tone, to: folder.appendingPathComponent("segment-001.m4a"))
        let manifest = RecordingManifest(note: UUID(), recording: id, started: Date(), codec: "aac",
                                         segments: ["segment-001.m4a"], finished: 1)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(RecordingRecovery.manifestName))
        await qc.sweep()
        #expect(Self.inbox(url) == [CaptureFile.name(id, .capture)])
        #expect(Self.leftovers(qc.root).isEmpty)
    }
}
