import AVFoundation
import Foundation
import Observation
import Security
import Sempere
import UIKit
#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// What this device keeps for quick voice notes (docs/quick-capture.md):
/// the vault's capture profile (public recipients and the capture key, never
/// the identity or the vault secret), where the vault is, and whether voice
/// notes are transcribed here.
struct StoredCaptureProfile: Codable, Equatable, Sendable {
    var profile: CaptureProfile
    var vaultName: String
    /// Bookmark of the vault folder (`options: []`, as for recent vaults).
    var bookmark: Data
    /// Transcribe voice notes on this device when they stop.
    var transcribe: Bool
}

/// Where the profile lives: the Keychain in the app, memory in tests.
protocol CaptureProfileStore: Sendable {
    func load() throws -> StoredCaptureProfile?
    func save(_ profile: StoredCaptureProfile) throws
    func delete() throws
}

/// One generic-password item, readable after the device's first unlock and
/// on this device only (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`):
/// a voice note can start from the Lock Screen, and the item never leaves the
/// device. No biometry: the capture key cannot read anything (docs/quick-capture.md).
struct KeychainCaptureProfileStore: CaptureProfileStore {
    static let service = "io.github.anthonytw.sempere.quick-capture"
    static let account = "profile"

    enum Failure: Error, Equatable { case status(OSStatus) }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func load() throws -> StoredCaptureProfile? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw Failure.status(status) }
        return try JSONDecoder().decode(StoredCaptureProfile.self, from: data)
    }

    func save(_ profile: StoredCaptureProfile) throws {
        let data = try JSONEncoder().encode(profile)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                         kSecAttrLabel as String: "Sempere — quick voice notes"]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.status(status) }
    }
}

/// `CaptureProfileStore` in memory (tests).
final class MemoryCaptureProfileStore: CaptureProfileStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: StoredCaptureProfile?
    func load() throws -> StoredCaptureProfile? { lock.withLock { value } }
    func save(_ profile: StoredCaptureProfile) throws { lock.withLock { value = profile } }
    func delete() throws { lock.withLock { value = nil } }
}

enum QuickCaptureError: Error, Equatable, CustomStringConvertible, CustomLocalizedStringResourceConvertible {
    case notSetUp
    case microphoneDenied
    /// iOS ends a recording started by an intent (widget, Control Center, Action
    /// button) that shows no Live Activity, so none starts while they are off.
    case liveActivitiesOff
    case alreadyRecording
    case notRecording

    var description: String {
        switch self {
        case .notSetUp: return String(localized: "Quick Voice Notes is not set up: open Sempere, unlock the vault and turn it on in Settings.")
        case .microphoneDenied: return RecordingError.microphoneDenied.description
        case .liveActivitiesOff: return String(localized: "Live Activities are off for Sempere, and iOS needs one to record a voice note: turn them on in Settings → Sempere → Live Activities.")
        case .alreadyRecording: return String(localized: "A voice note is already being recorded.")
        case .notRecording: return String(localized: "No voice note is being recorded.")
        }
    }

    /// What Siri, Shortcuts and the widgets show when an intent fails.
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: description) }
}

/// Quick voice notes (docs/quick-capture.md): one tap (Siri, Shortcuts, the
/// Action button, a widget, Control Center) records; stopping seals the audio
/// with the capture profile alone (`CaptureWriter`: age-encrypted to the
/// vault's recipients and tagged with the capture key), so neither the vault
/// nor the device needs unlocking and no Face ID is asked. The sealed file goes
/// into the vault's `inbox/` (a coordinated write in iCloud Drive), or into a
/// local queue when the vault folder cannot be reached, moved into the vault
/// later. The plaintext audio exists only in a protected temporary file
/// (`completeUnlessOpen`, the one class that can be written with the screen
/// locked) and in memory, and is deleted as soon as the capture (and its
/// transcript, made on device from it) is sealed; leftovers from a crash are
/// sealed or deleted at the next launch (`sweep`). The app adopts inbox
/// captures as notes once the vault is unlocked (`AppModel+Inbox`).
@MainActor
@Observable
final class QuickCapture {
    static let shared = QuickCapture()

    enum State: Equatable { case idle, starting, recording, saving }

    enum Delivery: Equatable, Sendable { case vault, queued }

    /// What one capture did.
    struct Outcome: Equatable {
        var id: UUID
        var delivery: Delivery?
        var transcribed = false
        var error: String?
    }

    private(set) var state = State.idle
    /// The recording in progress.
    private(set) var session: RecordingSession?
    /// The last capture's outcome.
    private(set) var lastOutcome: Outcome?

    @ObservationIgnored var store: any CaptureProfileStore = KeychainCaptureProfileStore()
    @ObservationIgnored var backend: (@MainActor () -> AudioCaptureBackend)?
    @ObservationIgnored var transcriber: (any RecordingTranscribing)? = SpeechRecordingTranscriber()
    @ObservationIgnored var microphoneAllowed: @MainActor () async -> Bool = { await AVAudioCaptureBackend.requestMicrophone() }
    @ObservationIgnored var center: NotificationCenter = .default
    /// Where recordings in progress are (plaintext, protected, deleted once sealed).
    @ObservationIgnored var root = QuickCapture.defaultRoot
    /// Sealed captures waiting for the vault folder, per vault id.
    @ObservationIgnored var queueRoot = QuickCapture.defaultQueueRoot
    /// Starts a Live Activity while recording (off in tests).
    @ObservationIgnored var showsActivity = true
    #if os(iOS) && !targetEnvironment(macCatalyst)
    @ObservationIgnored private var activity: Activity<VoiceNoteAttributes>?
    #endif

    /// The Data Protection class of recordings in progress. Not `completeUnlessOpen`: its files
    /// cannot be reopened while the device is locked once closed, and a voice note started from
    /// the Lock Screen is assembled, read and sealed from closed segment files before any unlock.
    static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    nonisolated static var defaultRoot: URL { appSupport.appendingPathComponent("Sempere/QuickCapture", isDirectory: true) }
    nonisolated static var defaultQueueRoot: URL { appSupport.appendingPathComponent("Sempere/CaptureQueue", isDirectory: true) }
    nonisolated private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Hooks the intents (Siri, Shortcuts, widgets, Control Center) up to the shared instance.
    /// Also ends Live Activities left by an earlier process (killed, crashed or
    /// rebooted while recording): nothing of theirs is recording any more, and
    /// their Stop button would reach a process that knows nothing of them.
    static func register() {
        VoiceNoteActions.start = { try await QuickCapture.shared.start() }
        VoiceNoteActions.stop = {
            do { _ = try await QuickCapture.shared.stop() } catch QuickCaptureError.notRecording {
                // Stop on an orphaned Live Activity: it is gone now (stop ended it); nothing to report.
            }
        }
        let launched = Date()
        Task { await endActivities(startedBefore: launched) }
    }

    /// Whether quick voice notes are set up on this device.
    var isSetUp: Bool { ((try? store.load()) ?? nil) != nil }

    // MARK: - Recording

    /// Starts a voice note. Needs only the stored profile: no vault, no key.
    func start() async throws {
        guard state == .idle else { throw QuickCaptureError.alreadyRecording }
        // Claimed before the first suspension: a second tap (widget and Control Center at
        // once) used to pass the idle check too and start a second, unstoppable recording.
        state = .starting
        var started = false
        defer { if !started { state = .idle } }
        guard ((try? store.load()) ?? nil) != nil else { throw QuickCaptureError.notSetUp }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if showsActivity, !ActivityAuthorizationInfo().areActivitiesEnabled { throw QuickCaptureError.liveActivitiesOff }
        #endif
        guard await microphoneAllowed() else { throw QuickCaptureError.microphoneDenied }
        // Nothing records here yet, so any Live Activity still shown is an orphan.
        await Self.endActivities(startedBefore: .distantFuture)
        // Read back and sealed on stop, often with the device still locked: `completeUnlessOpen`
        // files cannot be reopened then once closed, so this class (readable after the first unlock).
        let s = RecordingSession(noteID: UUID(), format: RecordingPreference.format(), root: root,
                                 protection: Self.protection, backend: backend?(), center: center)
        // Ended by the system (media services reset, no new segment file): sealed as after Stop.
        s.onStoppedBySystem = { [weak self, weak s] in
            guard let self, let s, self.session === s else { return }
            Task { _ = try? await self.finish(s) }
        }
        try s.start()
        session = s
        state = .recording
        started = true
        startActivity(started: s.timeline.started ?? Date())
    }

    /// Stops the voice note and seals it (and its transcript, when that is on).
    @discardableResult
    func stop() async throws -> Outcome {
        guard let s = session, s.isActive else {
            // Stop pressed on a Live Activity this process did not start: end it.
            if state == .idle { await Self.endActivities(startedBefore: .distantFuture) }
            throw QuickCaptureError.notRecording
        }
        s.stop()
        return try await finish(s)
    }

    /// Seals a stopped session (`stop`, or the system ended it).
    private func finish(_ s: RecordingSession) async throws -> Outcome {
        guard session === s, state == .recording else { throw QuickCaptureError.notRecording }
        state = .saving
        endActivity()
        defer {
            session = nil
            state = .idle
        }
        guard let stored = (try? store.load()) ?? nil else {
            s.discardFiles()
            throw QuickCaptureError.notSetUp
        }
        let outcome = await seal(segments: s.segments, folder: s.folder, id: s.id, started: s.timeline.started ?? Date(),
                                 stored: stored)
        lastOutcome = outcome
        return outcome
    }

    /// "Voice note 7 Oct 2026 at 14:32" in this device's language.
    nonisolated static func title(_ started: Date) -> String {
        "Voice note " + started.formatted(date: .abbreviated, time: .shortened)
    }

    /// Seals the audio in `segments` as capture `id`, delivers it, transcribes
    /// it on device from the plaintext when the profile says so and delivers
    /// the transcript, then deletes `folder` (the plaintext) whatever happened.
    func seal(segments: [URL], folder: URL, id: UUID, started: Date, stored: StoredCaptureProfile) async -> Outcome {
        var outcome = Outcome(id: id)
        let background = BackgroundWork.begin(name: "Seal voice note") {
            // Out of time: the folder stays. If the app is resumed, this seal
            // finishes and deletes it; if it is terminated, `sweep()` seals it
            // at the next launch. Deleting it here lost a voice note whose
            // merge or seal had not finished.
        }
        defer {
            try? FileManager.default.removeItem(at: folder)
            background.end()
        }
        do {
            let writer = try CaptureWriter(profile: stored.profile)
            let out = folder.appendingPathComponent("capture.m4a")
            try await RecordingAssembly.merge(await RecordingAssembly.readable(segments), into: out)
            let sealed = try await Task.detached(priority: .userInitiated) { () throws -> SealedCapture in
                let audio = try BoundedRead.contents(of: out, maxBytes: CaptureFile.maxBytes - (1 << 20))
                return try writer.seal(audio: audio, started: started, info: try? AudioProbe.probe(audio),
                                       title: QuickCapture.title(started), id: id)
            }.value
            outcome.delivery = try deliver(sealed, stored)
            if stored.transcribe, let transcriber {
                do {
                    let transcript = try await transcriber.transcribe(file: out, recording: CaptureAdoption.ids(for: id).recording,
                                                                      noteLanguage: nil)
                    _ = try deliver(try writer.seal(transcript: transcript, capture: id), stored)
                    outcome.transcribed = true
                } catch {
                    // Transcribed later, once the vault is unlocked (AppModel+Inbox).
                }
            }
        } catch {
            outcome.error = "\(error)"
        }
        return outcome
    }

    // MARK: - Delivery

    /// Writes `sealed` into the vault's inbox, or into the local queue when
    /// the vault folder cannot be reached or is not the profile's vault.
    func deliver(_ sealed: SealedCapture, _ stored: StoredCaptureProfile) throws -> Delivery {
        if let url = Self.resolve(stored.bookmark) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if (try? Vault.open(at: url))?.vaultId == stored.profile.vaultId {
                let inbox = url.appendingPathComponent(CaptureFile.folderName, isDirectory: true)
                do {
                    try CloudVault.coordinatedWrite(CloudVault.isUbiquitous(url) ? inbox : nil) {
                        try CaptureWriter.store(sealed, in: inbox)
                    }
                    return .vault
                } catch {
                    // Not reachable now: queued below.
                }
            }
        }
        try CaptureWriter.store(sealed, in: queueFolder(stored.profile.vaultId))
        return .queued
    }

    func queueFolder(_ vault: UUID) -> URL { queueRoot.appendingPathComponent(vault.uuidString.lowercased(), isDirectory: true) }

    /// The vault folder a bookmark names (nil when it cannot be resolved).
    nonisolated static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Moves queued captures of `vaultId` into the vault at `vaultURL`
    /// (sealed already: plain file moves). Returns how many moved.
    @discardableResult
    func flushQueue(into vaultURL: URL, vaultId: UUID, coordinated: Bool) -> Int {
        let dir = queueFolder(vaultId)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { CaptureFile.parse(name: $0) != nil }
        let inbox = vaultURL.appendingPathComponent(CaptureFile.folderName, isDirectory: true)
        var moved = 0
        for name in names {
            let file = dir.appendingPathComponent(name)
            guard let data = try? BoundedRead.contents(of: file, maxBytes: CaptureFile.maxBytes + (1 << 20)) else { continue }
            do {
                try CloudVault.coordinatedWrite(coordinated ? inbox : nil) {
                    try CaptureWriter.store(SealedCapture(name: name, data: data), in: inbox)
                }
                try? FileManager.default.removeItem(at: file)
                moved += 1
            } catch {
                continue
            }
        }
        return moved
    }

    /// Moves queued captures into the stored profile's vault when its folder
    /// can be reached (the app became active).
    func flushStoredQueue() {
        guard let stored = (try? store.load()) ?? nil, let url = Self.resolve(stored.bookmark) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard (try? Vault.open(at: url))?.vaultId == stored.profile.vaultId else { return }
        flushQueue(into: url, vaultId: stored.profile.vaultId, coordinated: CloudVault.isUbiquitous(url))
    }

    /// Recordings a crash left in `root`: sealed from their readable segments
    /// when the profile is there (no transcript), then deleted either way.
    func sweep() async {
        guard session == nil else { return }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let stored = (try? store.load()) ?? nil
        for dir in dirs {
            guard let stored, let data = try? BoundedRead.contents(of: dir.appendingPathComponent(RecordingRecovery.manifestName), maxBytes: 1 << 20),
                  let m = try? JSONDecoder().decode(RecordingManifest.self, from: data) else {
                try? FileManager.default.removeItem(at: dir)
                continue
            }
            var noTranscript = stored
            noTranscript.transcribe = false
            _ = await seal(segments: m.segments.map { dir.appendingPathComponent($0) }, folder: dir, id: m.recording,
                           started: m.started ?? Date(), stored: noTranscript)
        }
    }

    // MARK: - Live Activity

    private func startActivity(started: Date) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard showsActivity, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(attributes: VoiceNoteAttributes(),
                                         content: .init(state: .init(started: started, paused: false), staleDate: nil))
        #endif
    }

    private func endActivity() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard let id = activity?.id else { return }
        activity = nil
        // `Activity` is not Sendable: end it by id from a nonisolated task.
        Task.detached {
            for a in Activity<VoiceNoteAttributes>.activities where a.id == id {
                await a.end(nil, dismissalPolicy: .immediate)
            }
        }
        #endif
    }

    /// Ends every voice note Live Activity that started before `cutoff`.
    nonisolated static func endActivities(startedBefore cutoff: Date) async {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        await Task.detached {
            for a in Activity<VoiceNoteAttributes>.activities where a.content.state.started < cutoff {
                await a.end(nil, dismissalPolicy: .immediate)
            }
        }.value
        #endif
    }
}

/// A background-time assertion while a voice note is sealed (the app may
/// have been launched by an intent, or sent to the background meanwhile).
@MainActor
final class BackgroundWork {
    private var id = UIBackgroundTaskIdentifier.invalid

    static func begin(name: String, expired: @escaping @MainActor @Sendable () -> Void) -> BackgroundWork {
        let work = BackgroundWork()
        work.id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak work] in
            MainActor.assumeIsolated {
                expired()
                work?.end()
            }
        }
        return work
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
