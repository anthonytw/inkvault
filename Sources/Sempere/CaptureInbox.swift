import Age
import Crypto
import Foundation

// Quick capture without unlocking (format.md §11, docs/quick-capture.md).
//
// A device that may capture keeps a `CaptureProfile`: the vault's public
// recipients and a capture key derived from the vault secret (never the
// secret itself, never an identity). With it, a voice note is sealed into
// `inbox/<id>.capture.age`: encrypted to the recipients like every vault
// file, and authenticated with the capture key so that nobody without the
// vault secret can plant one. The next device that unlocks the vault adopts
// it: the audio becomes a blob of a new note in the inbox notebook, with a
// title from the date, in one delta; a transcript sealed later the same way
// (`inbox/<id>.transcript.age`) is added to that recording.

/// Why a capture cannot be written or adopted.
public enum CaptureError: Error, Hashable, Sendable, CustomStringConvertible {
    /// Not a capture file: wrong magic, version, length or layout.
    case notCapture(String)
    /// The tag does not verify: forged, damaged, or sealed under another
    /// vault secret (one rotated since, format.md §3.3).
    case badTag
    /// The manifest or transcript inside does not parse or breaks a rule.
    case invalidContent(String)
    /// The audio's size or hash differs from the manifest.
    case audioMismatch
    /// Larger than `CaptureFile.maxBytes`.
    case tooLarge(Int)
    /// The capture names another vault.
    case wrongVault
    /// The profile has no usable recipient.
    case noRecipients
    /// A capture key that is not 32 bytes.
    case invalidKey

    public var description: String {
        switch self {
        case .notCapture(let why): return "not a capture file: \(why)"
        case .badTag: return "the capture does not verify (forged, damaged, or sealed before the vault's keys changed)"
        case .invalidContent(let why): return "invalid capture: \(why)"
        case .audioMismatch: return "the capture's audio does not match its manifest"
        case .tooLarge(let n): return "the capture is larger than \(n >> 20) MiB"
        case .wrongVault: return "the capture belongs to another vault"
        case .noRecipients: return "the capture profile has no usable recipient"
        case .invalidKey: return "a capture key must be 32 bytes"
        }
    }
}

/// The key that authenticates captures (format.md §11.1): HKDF-SHA256 of
/// the vault secret with `info` `sempere/1 capture key`. It cannot decrypt
/// anything, cannot tag revisions or name blobs, and reveals nothing about the
/// secret; it only lets its holder put captures in the inbox. It changes with
/// the secret, so removing a device's recipient also revokes its captures.
public struct CaptureKey: Hashable, Sendable {
    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == 32 else { throw CaptureError.invalidKey }
        self.bytes = bytes
    }

    static let info = "sempere/1 capture key"

    /// The capture key of a vault secret.
    public static func derive(from secret: VaultSecret) -> CaptureKey {
        let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: secret.key, info: Data(info.utf8), outputByteCount: 32)
        return CaptureKey(valid: k.withUnsafeBytes { Data($0) })
    }

    private init(valid: Data) { bytes = valid }
}

/// What a device keeps so it can capture while the vault is locked (and the
/// device itself may be): no identity and no vault secret. The app keeps it
/// in the Keychain (this device only, readable after the first unlock).
public struct CaptureProfile: Codable, Hashable, Sendable {
    public var vaultId: UUID
    /// The vault's recipients (`age1pq1…`), public.
    public var recipients: [String]
    /// `CaptureKey.bytes`.
    public var key: Data
    /// The capturing device's id (format.md §5), recorded in each capture.
    public var device: String
    /// The notebook adopted captures go to.
    public var notebook: String

    public init(vaultId: UUID, recipients: [String], key: Data, device: String, notebook: String) {
        self.vaultId = vaultId; self.recipients = recipients; self.key = key; self.device = device
        self.notebook = notebook
    }

    /// The default inbox notebook.
    public static let defaultNotebook = "Inbox"
}

extension Vault {
    /// The capture key (format.md §11.1). Needs the vault secret.
    public func captureKey() throws -> CaptureKey { CaptureKey.derive(from: try requireSecret()) }

    /// A capture profile for this device: the recipients and the capture
    /// key. Needs the vault unlocked once; afterwards captures need nothing else.
    ///
    /// - Throws: `VaultError.untrustedRecipients` when the recipients list
    ///   does not check (format.md §2.1).
    public func captureProfile(device: DeviceID, notebook: String = CaptureProfile.defaultNotebook) throws -> CaptureProfile {
        try requireMigrated()
        // A profile lets captures be written into inbox/ (format.md §7.3), and they are
        // sealed to these keys alone (§11.1): never to a list that does not check.
        try requireNotReadOnly()
        try requireTrustedRecipients()
        let nb = NoteOps.normalizedNotebook(notebook) ?? CaptureProfile.defaultNotebook
        return CaptureProfile(vaultId: vaultId, recipients: recipients.map(\.key), key: try captureKey().bytes,
                              device: device.rawValue, notebook: nb)
    }

    /// The vault's inbox folder (format.md §1).
    public var inboxURL: URL { url.appendingPathComponent(CaptureFile.folderName, isDirectory: true) }
}

/// A capture's manifest (format.md §11.2): one line of JSON before the audio.
public struct CaptureManifest: Codable, Hashable, Sendable {
    public static let formatName = "sempere-capture/1"

    public var id: UUID
    /// The capturing device (8 lowercase hex digits).
    public var device: String
    public var vault: UUID
    /// When the capture was sealed.
    public var created: Date
    /// Wall time of the first sample.
    public var started: Date
    /// The note's title.
    public var title: String
    /// The notebook to adopt into; absent means `Inbox`.
    public var notebook: String?
    /// The audio that follows the manifest: its media type, size and SHA-256.
    public var audio: BlobRef
    /// Informational, as on recordings (format.md §8.3.1).
    public var duration: Double?
    public var codec: String?
    public var sampleRate: Int?
    public var channels: Int?
    public var bitRate: Int?

    public init(id: UUID, device: String, vault: UUID, created: Date, started: Date, title: String, notebook: String?,
                audio: BlobRef, info: AudioInfo? = nil) {
        self.id = id; self.device = device; self.vault = vault; self.created = created; self.started = started
        self.title = title; self.notebook = notebook; self.audio = audio
        duration = info?.duration; codec = info?.codec; sampleRate = info?.sampleRate; channels = info?.channels
        bitRate = info?.bitRate
    }

    /// The recording's informational fields.
    public var info: AudioInfo {
        var i = AudioInfo()
        i.duration = duration; i.codec = codec; i.sampleRate = sampleRate; i.channels = channels; i.bitRate = bitRate
        return i
    }

    enum CodingKeys: String, CodingKey {
        case format, id, device, vault, created, started, title, notebook, audio, duration, codec, sampleRate, channels, bitRate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .format) == Self.formatName else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: c, debugDescription: "unknown capture format")
        }
        id = try c.decode(LowercaseUUID.self, forKey: .id).uuid
        device = try c.decode(String.self, forKey: .device)
        guard DeviceID(device) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .device, in: c, debugDescription: "bad device id")
        }
        vault = try c.decode(LowercaseUUID.self, forKey: .vault).uuid
        created = try c.decode(Date.self, forKey: .created)
        started = try c.decode(Date.self, forKey: .started)
        title = try c.decode(String.self, forKey: .title)
        notebook = try c.decodeIfPresent(String.self, forKey: .notebook)
        audio = try c.decode(BlobRef.self, forKey: .audio)
        guard audio.isValid, audio.type.lowercased().hasPrefix("audio/") else {
            throw DecodingError.dataCorruptedError(forKey: .audio, in: c, debugDescription: "bad audio reference")
        }
        duration = try c.decodeIfPresent(Double.self, forKey: .duration).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        codec = try c.decodeIfPresent(String.self, forKey: .codec)
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate).flatMap { $0 > 0 ? $0 : nil }
        channels = try c.decodeIfPresent(Int.self, forKey: .channels).flatMap { $0 > 0 ? $0 : nil }
        bitRate = try c.decodeIfPresent(Int.self, forKey: .bitRate).flatMap { $0 > 0 ? $0 : nil }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatName, forKey: .format)
        try c.encode(LowercaseUUID(id), forKey: .id)
        try c.encode(device, forKey: .device)
        try c.encode(LowercaseUUID(vault), forKey: .vault)
        try c.encode(created, forKey: .created)
        try c.encode(started, forKey: .started)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(notebook, forKey: .notebook)
        try c.encode(audio, forKey: .audio)
        try c.encodeIfPresent(duration.map(InkJSON.round3), forKey: .duration)
        try c.encodeIfPresent(codec, forKey: .codec)
        try c.encodeIfPresent(sampleRate, forKey: .sampleRate)
        try c.encodeIfPresent(channels, forKey: .channels)
        try c.encodeIfPresent(bitRate, forKey: .bitRate)
    }
}

/// The plaintext layout of inbox files (format.md §11.2):
///
/// | Offset | Size | Content |
/// | --- | --- | --- |
/// | 0 | 4 | ASCII `SMPC` |
/// | 4 | 1 | version `0x01` |
/// | 5 | 32 | HMAC-SHA256(capture key, `"sempere/1" ‖ 0x00 ‖ "capture" ‖ 0x00 ‖ filename ‖ 0x00 ‖ rest`) |
/// | 37 | rest | one line of JSON (no raw newline), `0x0A`, then the payload |
///
/// so `age -d -i key F | tail -c +38 | head -n 1 | jq .` reads the manifest and
/// `… | tail -c +38 | tail -n +2 > audio.m4a` the audio.
public enum CaptureFile {
    /// The vault folder that holds captures (format.md §1).
    public static let folderName = "inbox"
    static let magic: [UInt8] = Array("SMPC".utf8)
    static let version: UInt8 = 1
    public static let headerSize = 37
    /// Largest plaintext an inbox file may have (the audio of a few hours).
    public static let maxBytes = 256 << 20
    /// Largest JSON line.
    public static let maxLineBytes = Transcript.maxSize

    public enum Kind: String, Sendable, CaseIterable {
        case capture, transcript
    }

    /// `<id>.<kind>.age`.
    public static func name(_ id: UUID, _ kind: Kind) -> String { "\(id.uuidString.lowercased()).\(kind.rawValue).age" }

    /// The id and kind of an inbox file name; nil for anything else (an unknown file, ignored).
    public static func parse(name: String) -> (id: UUID, kind: Kind)? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "age", let kind = Kind(rawValue: String(parts[1])),
              parts[0].count == 36, parts[0] == parts[0].lowercased(), let id = UUID(uuidString: String(parts[0])) else { return nil }
        return (id, kind)
    }

    /// Computed incrementally: `rest` (up to `maxBytes`) is never copied.
    static func tag<D: DataProtocol>(_ key: CaptureKey, filename: String, rest: D) -> Data {
        var m = Data("sempere/1".utf8)
        m.append(0); m.append(contentsOf: "capture".utf8); m.append(0); m.append(contentsOf: filename.utf8); m.append(0)
        var hmac = HMAC<SHA256>(key: SymmetricKey(data: key.bytes))
        hmac.update(data: m)
        hmac.update(data: rest)
        return Data(hmac.finalize())
    }

    /// The plaintext of an inbox file named `filename`.
    public static func frame(line: Data, payload: Data, filename: String, key: CaptureKey) throws -> Data {
        guard !line.contains(0x0A), line.count <= maxLineBytes else { throw CaptureError.invalidContent("the JSON is not one line") }
        var rest = line
        rest.append(0x0A)
        rest.append(payload)
        guard headerSize + rest.count <= maxBytes else { throw CaptureError.tooLarge(maxBytes) }
        var out = Data(magic)
        out.append(version)
        out.append(tag(key, filename: filename, rest: rest))
        out.append(rest)
        return out
    }

    /// The JSON line and payload of an inbox file's plaintext, once its tag
    /// verifies under `key` for `filename`.
    public static func unframe(_ plaintext: Data, filename: String, key: CaptureKey) throws -> (line: Data, payload: Data) {
        guard plaintext.count <= maxBytes else { throw CaptureError.tooLarge(maxBytes) }
        guard plaintext.count > headerSize else { throw CaptureError.notCapture("too short") }
        let b = plaintext.startIndex
        guard Array(plaintext[b..<b + 4]) == magic else { throw CaptureError.notCapture("bad magic") }
        guard plaintext[b + 4] == version else { throw CaptureError.notCapture("unknown version \(plaintext[b + 4])") }
        let stored = plaintext[b + 5..<b + headerSize]
        let rest = plaintext[(b + headerSize)...]
        let expected = tag(key, filename: filename, rest: rest)
        guard constantTimeEqual(Data(stored), expected) else { throw CaptureError.badTag }
        guard let nl = rest.prefix(maxLineBytes + 1).firstIndex(of: 0x0A) else {
            throw CaptureError.notCapture("no JSON line")
        }
        return (Data(rest[rest.startIndex..<nl]), Data(rest[(nl + 1)...]))
    }

    /// The plaintext of inbox file `filename` tagged under `key` instead: the
    /// same bytes after the tag, once the old tag verifies under one of
    /// `keys` (format.md §11.1, a recipient change). Nil when it verifies
    /// under none of them (forged, or sealed under a key revoked earlier).
    static func retag(_ plaintext: Data, filename: String, verifiedBy keys: [CaptureKey], to key: CaptureKey) -> Data? {
        guard keys.contains(where: { (try? unframe(plaintext, filename: filename, key: $0)) != nil }) else { return nil }
        let rest = plaintext[(plaintext.startIndex + headerSize)...]
        var out = Data(magic)
        out.append(version)
        out.append(tag(key, filename: filename, rest: rest))
        out.append(rest)
        return out
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}

/// A sealed inbox file: its name and its bytes (an age file).
public struct SealedCapture: Hashable, Sendable {
    public var name: String
    public var data: Data

    /// A sealed file as read back, e.g. from a device-local queue.
    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

/// Seals captures with a `CaptureProfile` alone: no identity, no vault
/// secret (format.md §11.2). What it writes is age-encrypted to the vault's
/// recipients before it touches a disk.
public struct CaptureWriter: Sendable {
    public let profile: CaptureProfile
    let key: CaptureKey
    let recipients: [NativeRecipient]

    public init(profile: CaptureProfile) throws {
        self.profile = profile
        key = try CaptureKey(bytes: profile.key)
        recipients = profile.recipients.compactMap { try? NativeRecipient(string: $0) }
        guard !recipients.isEmpty, recipients.count == profile.recipients.count else { throw CaptureError.noRecipients }
    }

    /// A title from the start time, e.g. `Voice note 2026-10-07 14:32`
    /// (in `timeZone`); the app passes a localized one.
    public static func defaultTitle(_ started: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: started)
        return String(format: "Voice note %04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// Seals `audio` (an `audio/mp4` recording by default) as capture `id`.
    public func seal(audio: Data, type: String = "audio/mp4", started: Date, info: AudioInfo? = nil, title: String? = nil,
                     id: UUID = UUID(), created: Date = Date()) throws -> SealedCapture {
        let manifest = CaptureManifest(id: id, device: profile.device, vault: profile.vaultId, created: created, started: started,
                                       title: title ?? Self.defaultTitle(started), notebook: profile.notebook,
                                       audio: BlobRef(content: audio, type: type), info: info)
        let name = CaptureFile.name(id, .capture)
        let plain = try CaptureFile.frame(line: try InkJSON.encoder().encode(manifest), payload: audio, filename: name, key: key)
        return SealedCapture(name: name, data: try Vault.encrypt(plain, to: recipients))
    }

    /// Seals the transcript of capture `id` (its `recording` must be the
    /// capture's recording id, `CaptureAdoption.ids(for:)`), bound to the
    /// capture's `audio` (the manifest's reference): the payload is its
    /// SHA-256, which only whoever had the audio knows (format.md §11.2), so
    /// another holder of the capture key cannot attach a transcript of its
    /// own to the voice note.
    public func seal(transcript: Transcript, capture id: UUID, audio: BlobRef) throws -> SealedCapture {
        guard transcript.recording == CaptureAdoption.ids(for: id).recording else {
            throw CaptureError.invalidContent("the transcript names another recording")
        }
        guard audio.isValid else { throw CaptureError.invalidContent("bad audio reference") }
        let name = CaptureFile.name(id, .transcript)
        let plain = try CaptureFile.frame(line: try transcript.encoded(), payload: Data(audio.sha256.utf8), filename: name,
                                          key: key)
        return SealedCapture(name: name, data: try Vault.encrypt(plain, to: recipients))
    }

    /// Writes `sealed` into the folder `inbox` (created if missing) under its
    /// name, atomically, never over an existing file (inbox files are
    /// written once).
    public static func store(_ sealed: SealedCapture, in inbox: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let final = inbox.appendingPathComponent(sealed.name)
        guard !fm.fileExists(atPath: final.path) else { return }
        let tmp = inbox.appendingPathComponent(".\(sealed.name).\(UUID().uuidString.lowercased()).tmp")
        try sealed.data.write(to: tmp)
        do { try fm.moveItem(at: tmp, to: final) } catch {
            try? fm.removeItem(at: tmp)
            if !fm.fileExists(atPath: final.path) { throw error }
        }
    }
}

/// An inbox entry read and verified: the capture (if its file is there) and
/// its transcript (if one was sealed).
public struct PendingCapture: Sendable {
    public var id: UUID
    public var manifest: CaptureManifest?
    public var audio: Data?
    public var transcript: Transcript?
    /// Transcript content as stored (for the blob).
    public var transcriptContent: Data?
    /// The SHA-256 (lowercase hex) of the audio the transcript is bound to
    /// (format.md §11.2); nil when there is no usable transcript.
    public var transcriptAudio: String?
    /// The inbox files read.
    public var files: [String]
}

/// Turning captures into notes (format.md §11.3).
public enum CaptureAdoption {
    /// The note, page and recording ids of capture `id`: derived from it, so
    /// two devices that adopt the same capture write the same note, and an
    /// adoption interrupted before the inbox file was deleted is not doubled.
    public static func ids(for id: UUID) -> (note: UUID, page: UUID, recording: UUID) {
        let base = "sempere-capture/1 " + id.uuidString.lowercased()
        return (UUID.derived(from: base + " note"), UUID.derived(from: base + " page"), UUID.derived(from: base + " recording"))
    }

    /// The inbox files of `pending` that may be deleted once its note is
    /// `after` (nil: no note): the capture once the note exists; the
    /// transcript once the recording has one (or is gone: removed by the user).
    public static func consumed(_ pending: PendingCapture, after: NoteState?) -> [String] {
        guard let after, !after.pages.isEmpty || !after.recordings.isEmpty else { return [] }
        var done = pending.files.filter { CaptureFile.parse(name: $0)?.kind == .capture }
        let rec = after.recordings.first { $0.id == ids(for: pending.id).recording }
        // A transcript that is not bound to this recording's audio is never adopted.
        if rec == nil || rec?.transcript != nil || rec?.blob.sha256 != pending.transcriptAudio {
            done += pending.files.filter { CaptureFile.parse(name: $0)?.kind == .transcript }
        }
        return done
    }

    /// The ops that adopt `pending` into its note, whose current state is
    /// `current` (nil: no revision yet). A new note gets its title, notebook,
    /// one page, the recording (`audio` is its blob) and the transcript when
    /// there is one, in one delta. A note that exists only gets the
    /// transcript, if its recording is there without one. Nothing when there
    /// is nothing to add (a transcript whose capture has not arrived yet waits).
    /// A transcript is only added to the recording whose audio it is bound to
    /// (`PendingCapture.transcriptAudio`, format.md §11.2).
    public static func ops(_ pending: PendingCapture, audio: BlobRef?, transcript: BlobRef?, current: NoteState?,
                           paper: Paper = .ruled, pageSize: PageSize = .letter) -> [Op] {
        let ids = ids(for: pending.id)
        if let current, !current.recordings.isEmpty || !current.pages.isEmpty || !current.meta.title.isEmpty {
            guard let transcript, let r = current.recordings.first(where: { $0.id == ids.recording }), r.transcript == nil,
                  r.blob.sha256 == pending.transcriptAudio
            else { return [] }
            return [.setRecording(recordingId: ids.recording, change: .transcript(transcript))]
        }
        guard let m = pending.manifest, let audio else { return [] }
        let transcript = m.audio.sha256 == pending.transcriptAudio ? transcript : nil
        var ops = NoteOps.newNote(title: m.title, paper: paper, pageSize: pageSize,
                                  notebook: m.notebook ?? CaptureProfile.defaultNotebook, pageId: ids.page)
        var recording = NoteOps.recording(blob: audio, started: m.started, info: m.info, id: ids.recording)
        recording.transcript = transcript
        ops.append(.addRecording(recording))
        return ops
    }
}

extension Vault {
    /// The inbox's capture ids, with the kinds of file each has, sorted.
    /// Unknown files are ignored (format.md §1).
    public func inboxEntries() throws -> [(id: UUID, kinds: Set<CaptureFile.Kind>)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: inboxURL.path)) ?? []
        var byID: [UUID: Set<CaptureFile.Kind>] = [:]
        for n in names { if let p = CaptureFile.parse(name: n) { byID[p.id, default: []].insert(p.kind) } }
        return byID.map { ($0.key, $0.value) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Reads and verifies the inbox files of capture `id` (format.md §11.2):
    /// decrypted with the vault's identities, the tag checked under the
    /// capture key (the current vault secret's, or the previous one during a
    /// rewrap), the manifest and the audio's hash and size, the transcript
    /// against format.md §8.3.2 and the capture's recording id.
    public func readCapture(_ id: UUID) throws -> PendingCapture {
        try requireMigrated()
        guard canRead else { throw isLocked ? VaultError.locked : VaultError.noIdentities }
        var keys = [try captureKey()]
        if let previousSecret { keys.append(CaptureKey.derive(from: previousSecret)) }
        var pending = PendingCapture(id: id, files: [])
        for kind in CaptureFile.Kind.allCases {
            let name = CaptureFile.name(id, kind)
            let url = inboxURL.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let sealed = try FileIO.read(url, maxBytes: CaptureFile.maxBytes + (1 << 20))
            let plain: Data
            do { plain = try AgeFile.decrypt(sealed, with: identities) } catch {
                throw CaptureError.notCapture("cannot decrypt: \(error)")
            }
            var opened: (line: Data, payload: Data)?
            var lastError: Error = CaptureError.badTag
            for key in keys {
                do { opened = try CaptureFile.unframe(plain, filename: name, key: key); break } catch { lastError = error }
            }
            guard let (line, payload) = opened else { throw lastError }
            switch kind {
            case .capture:
                let m: CaptureManifest
                do { m = try InkJSON.decoder().decode(CaptureManifest.self, from: line) } catch {
                    throw CaptureError.invalidContent("\(error)")
                }
                guard m.id == id else { throw CaptureError.invalidContent("the manifest names another capture") }
                guard m.vault == vaultId else { throw CaptureError.wrongVault }
                guard BlobRef(content: payload, type: m.audio.type) == m.audio else { throw CaptureError.audioMismatch }
                pending.manifest = m
                pending.audio = payload
            case .transcript:
                let t: Transcript
                do { t = try Transcript.decode(line) } catch { throw CaptureError.invalidContent("\(error)") }
                guard t.recording == CaptureAdoption.ids(for: id).recording else {
                    throw CaptureError.invalidContent("the transcript names another recording")
                }
                // Bound to the capture's audio (format.md §11.2). One that is
                // not (an empty payload, written before the binding, or another
                // audio's hash) is never adopted, and is deleted with the
                // capture: the app transcribes the recording itself then.
                let bound = String(decoding: payload, as: UTF8.self)
                if SHA256Hex.bytes(bound) != nil, pending.manifest.map({ $0.audio.sha256 == bound }) ?? true {
                    pending.transcript = t
                    pending.transcriptContent = line
                    pending.transcriptAudio = bound
                }
            }
            pending.files.append(name)
        }
        return pending
    }

    /// Writes the blobs `pending` brings into its note (format.md §8.1.4:
    /// before the delta): the audio and the transcript.
    public func writeCaptureBlobs(_ pending: PendingCapture) throws -> (audio: BlobRef?, transcript: BlobRef?) {
        let note = CaptureAdoption.ids(for: pending.id).note
        var audioRef: BlobRef?
        if let audio = pending.audio, let m = pending.manifest {
            audioRef = try writeBlob(note: note, audio, type: m.audio.type)
        }
        var transcriptRef: BlobRef?
        if let content = pending.transcriptContent {
            transcriptRef = try writeBlob(note: note, content, type: BlobRef.transcriptType)
        }
        return (audioRef, transcriptRef)
    }

    /// Deletes inbox files once what they hold is in the vault.
    public func removeInboxFiles(_ names: [String]) {
        guard !isReadOnly else { return }   // format.md §7.3
        for n in names where CaptureFile.parse(name: n) != nil {
            try? FileManager.default.removeItem(at: inboxURL.appendingPathComponent(n))
        }
    }

    /// What adopting one capture did.
    public struct CaptureAdoptionResult: Sendable, Encodable {
        public var capture: String
        public var note: String
        public var title: String?
        /// The note was created by this adoption.
        public var created: Bool
        public var transcript: Bool
        /// The delta written (a file name in the note's folder); nil when none was needed.
        public var file: String?
        /// The inbox files deleted.
        public var removed: [String]
        public var error: String?
    }

    /// Adopts capture `id` as this device (the CLI's `inbox import`): reads
    /// and verifies it, writes its blobs, then one delta (format.md §11.3),
    /// then deletes the inbox files it consumed. A transcript whose capture
    /// is neither in the inbox nor adopted yet stays. With `dryRun` only the
    /// reading and verifying are done.
    public func adoptCapture(_ id: UUID, deviceState: URL, app: String, dryRun: Bool = false) -> CaptureAdoptionResult {
        let ids = CaptureAdoption.ids(for: id)
        var result = CaptureAdoptionResult(capture: id.uuidString.lowercased(), note: ids.note.uuidString.lowercased(),
                                           created: false, transcript: false, removed: [])
        do {
            let pending = try readCapture(id)
            result.title = pending.manifest?.title
            // A note exists once it has a revision: a folder holding only the
            // blobs of an adoption interrupted before its delta is still new.
            let exists = try !revisionNames(of: ids.note).isEmpty
            let current = exists ? try reconstruct(try loadNote(ids.note)) : nil
            let planned = CaptureAdoption.ops(pending, audio: pending.manifest?.audio,
                                              transcript: pending.transcriptContent.map { BlobRef(content: $0, type: BlobRef.transcriptType) },
                                              current: current)
            result.created = !exists && pending.manifest != nil
            result.transcript = planned.contains { if case .setRecording = $0 { return true }
                                                   if case .addRecording(let r) = $0 { return r.transcript != nil }
                                                   return false }
            if dryRun { return result }
            try requireWritable()
            if !planned.isEmpty {
                let refs = try writeCaptureBlobs(pending)
                let revision: Revision?
                if exists {
                    revision = try apply(to: ids.note, deviceState: deviceState, app: app) { state in
                        CaptureAdoption.ops(pending, audio: refs.audio, transcript: refs.transcript, current: state)
                    }
                } else {
                    revision = try apply(CaptureAdoption.ops(pending, audio: refs.audio, transcript: refs.transcript, current: nil),
                                         to: ids.note, deviceState: deviceState, app: app)
                }
                result.file = revision?.name.filename
            }
            let after = try revisionNames(of: ids.note).isEmpty ? nil : try reconstruct(try loadNote(ids.note))
            let done = CaptureAdoption.consumed(pending, after: after)
            removeInboxFiles(done)
            result.removed = done
        } catch {
            result.error = (error as? CaptureError)?.description ?? "\(error)"
        }
        return result
    }
}

extension Vault {
    /// Step 3 of a recipient change (format.md §3.3.1) for `inbox/` (§11.1):
    /// a capture still waiting there was sealed with the capture key of the
    /// outgoing secret, so once the change finishes (and the journal with
    /// that secret is gone) nothing could adopt it. Each inbox file that
    /// verifies under the current or the outgoing capture key is re-tagged
    /// under the current one and re-encrypted to the current recipients (a
    /// new device can then adopt it too); one already current is skipped.
    /// Files that verify under neither key, or that this device cannot
    /// decrypt, are left untouched and listed in `inboxSkipped`: they are
    /// never adopted anyway, and must not keep the journal (and the
    /// outgoing secret) alive. Only a file that cannot be read keeps it.
    func rewrapInbox(recipients: [NativeRecipient], report: inout RewrapReport, stopAfter: Int?) throws {
        let dir = inboxURL
        guard FileIO.isDirectory(dir) else { return }
        let current = CaptureKey.derive(from: try requireSecret())
        let keys = [current] + (previousSecret.map { [CaptureKey.derive(from: $0)] } ?? [])
        let expected = Self.expectedStanzas(recipients)
        for name in try FileIO.entries(dir) where CaptureFile.parse(name: name) != nil {
            let path = "\(CaptureFile.folderName)/\(name)"
            let file = dir.appendingPathComponent(name)
            guard !FileIO.isDirectory(file) else { continue }
            let data: Data
            do { data = try FileIO.read(file, maxBytes: CaptureFile.maxBytes + (1 << 20)) } catch {
                report.failures[path] = .unreadable("\(error)"); continue
            }
            let stanzas: [String: Int]
            let plain: Data
            do {
                stanzas = try Self.stanzaCounts(data)
                plain = try AgeFile.decrypt(data, with: identities)
            } catch {
                report.inboxSkipped.append(path); continue
            }
            if stanzas == expected, (try? CaptureFile.unframe(plain, filename: name, key: current)) != nil {
                report.alreadyCurrent.append(path); continue
            }
            guard let retagged = CaptureFile.retag(plain, filename: name, verifiedBy: keys, to: current) else {
                report.inboxSkipped.append(path); continue
            }
            if let stopAfter, report.rewrapped.count >= stopAfter { throw VaultError.interrupted }
            try FileIO.writeAtomically(try Self.encrypt(retagged, to: recipients), to: file, replacing: true)
            report.rewrapped.append(path)
        }
    }
}
