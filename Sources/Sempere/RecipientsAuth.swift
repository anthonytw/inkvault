import Crypto
import Foundation

// Authenticated recipients (format.md §2.1).
//
// `vault.json` is plaintext, and every writer encrypts to the keys it lists.
// `recipientsTag` authenticates those keys under a key derived from the vault
// secret, and `secretLink` authenticates a secret rotation under the outgoing
// secret, so that a forged `vault.json` carrying a secret of the attacker's
// own (and a tag that verifies under it) is caught by every device that knew
// the real one. Each device keeps a `RecipientsTrustRecord` outside the vault.

/// The keys, tags and checks of format.md §2.1.
public enum RecipientsAuth {
    static let recipientsInfo = "sempere/1 recipients key"
    static let linkInfo = "sempere/1 secret link key"
    static let secretIdInfo = "sempere/1 secret id"

    /// The most entries deleted when looking for the last verified list
    /// inside a tampered one (format.md §2.1, §9).
    public static let maxSearchDeletions = 3
    /// Lists longer than this are not searched: C(16, ≤3) = 696 HMACs over at
    /// most 16 post-quantum keys (about 32 KB each) is the bound on the work.
    public static let maxSearchKeys = 16

    static func derive(_ secret: VaultSecret, _ info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: secret.key, info: Data(info.utf8), outputByteCount: 32)
    }

    static func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    /// `linkKey` of a secret: what a trust record keeps.
    public static func linkKey(_ secret: VaultSecret) -> Data { bytes(derive(secret, linkInfo)) }

    /// `secretId` of a secret.
    static func secretId(_ secret: VaultSecret) -> Data { bytes(derive(secret, secretIdInfo)) }

    /// `"sempere/1" ‖ 0 ‖ "recipients" ‖ 0 ‖ vaultId (‖ 0 ‖ key)*`.
    static func tagMessage(vaultId: UUID, keys: [String]) -> Data {
        var m = Data("sempere/1".utf8)
        m.append(0); m.append(contentsOf: "recipients".utf8)
        m.append(0); m.append(contentsOf: vaultId.uuidString.lowercased().utf8)
        for k in keys { m.append(0); m.append(contentsOf: k.utf8) }
        return m
    }

    /// The raw tag of `keys` (in order) under `secret`.
    static func tagBytes(vaultId: UUID, keys: [String], secret: VaultSecret) -> Data {
        tagBytes(vaultId: vaultId, keys: keys, key: derive(secret, recipientsInfo))
    }

    static func tagBytes(vaultId: UUID, keys: [String], key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: tagMessage(vaultId: vaultId, keys: keys), using: key))
    }

    /// `recipientsTag` (lowercase hex) of `keys`, in order, under `secret`.
    public static func tag(vaultId: UUID, keys: [String], secret: VaultSecret) -> String {
        hex(tagBytes(vaultId: vaultId, keys: keys, secret: secret))
    }

    /// `secretLink` (lowercase hex) from the outgoing secret to the new one.
    public static func link(from old: VaultSecret, to new: VaultSecret, vaultId: UUID) -> String {
        hex(linkBytes(linkKey: linkKey(old), to: new, vaultId: vaultId))
    }

    static func linkBytes(linkKey: Data, to new: VaultSecret, vaultId: UUID) -> Data {
        var m = Data("sempere/1".utf8)
        m.append(0); m.append(contentsOf: "secret link".utf8)
        m.append(0); m.append(contentsOf: vaultId.uuidString.lowercased().utf8)
        m.append(0); m.append(secretId(new))
        return Data(HMAC<SHA256>.authenticationCode(for: m, using: SymmetricKey(data: linkKey)))
    }

    /// True when `tag` is 64 lowercase hex digits and verifies over `keys`.
    public static func verifyTag(_ tag: String, vaultId: UUID, keys: [String], secret: VaultSecret) -> Bool {
        guard let given = unhex(tag) else { return false }
        return constantTimeEqual(given, tagBytes(vaultId: vaultId, keys: keys, secret: secret))
    }

    /// True when `link` is 64 lowercase hex digits and verifies a rotation
    /// from the secret whose `linkKey` is `linkKey` to `new`.
    public static func verifyLink(_ link: String?, linkKey: Data, to new: VaultSecret, vaultId: UUID) -> Bool {
        guard let link, let given = unhex(link), linkKey.count == 32 else { return false }
        return constantTimeEqual(given, linkBytes(linkKey: linkKey, to: new, vaultId: vaultId))
    }

    /// The longest list obtained from `keys` by deleting at most
    /// `maxSearchDeletions` entries (order kept) whose tag is `tag` under
    /// `secret`, and the deleted entries; nil when none (or the list is
    /// longer than `maxSearchKeys`). Fewer deletions are tried first.
    static func verifiedSubset(of keys: [String], tag: String, vaultId: UUID,
                               secret: VaultSecret) -> (kept: [String], deleted: [String])? {
        guard keys.count <= maxSearchKeys, let given = unhex(tag) else { return nil }
        let key = derive(secret, recipientsInfo)
        var result: (kept: [String], deleted: [String])?
        func search(_ deletions: Int, from start: Int, removed: [Int]) {
            guard result == nil else { return }
            if deletions == 0 {
                let drop = Set(removed)
                let kept = keys.indices.filter { !drop.contains($0) }.map { keys[$0] }
                guard !kept.isEmpty else { return }
                if constantTimeEqual(given, tagBytes(vaultId: vaultId, keys: kept, key: key)) {
                    result = (kept, removed.map { keys[$0] })
                }
                return
            }
            guard start < keys.count else { return }
            for i in start..<keys.count { search(deletions - 1, from: i + 1, removed: removed + [i]) }
        }
        for d in 1...maxSearchDeletions where d < keys.count {
            search(d, from: 0, removed: [])
            if result != nil { break }
        }
        return result
    }

    /// Classifies `manifest`'s list (format.md §2.1 "Checking") for a reader
    /// holding `secret`, with this device's trust record (ignored when it is
    /// another vault's).
    public static func evaluate(_ manifest: VaultManifest, secret: VaultSecret,
                                record: RecipientsTrustRecord?) -> RecipientsStatus {
        let record = record?.vaultId == manifest.vaultId ? record : nil
        let keys = manifest.recipients.map(\.key)
        let id = manifest.vaultId
        guard let tag = manifest.recipientsTag else {
            let featured = manifest.features.contains(VaultManifest.recipientsTagFeature)
            guard featured || record != nil else { return .untagged }
            return .tampered(.init(reason: .tagRemoved, current: keys, restore: record.map { r in keys.filter(r.recipients.contains) },
                                   record: record))
        }
        guard verifyTag(tag, vaultId: id, keys: keys, secret: secret) else {
            if let found = verifiedSubset(of: keys, tag: tag, vaultId: id, secret: secret) {
                return .tampered(.init(reason: .tagMismatch, current: keys, restore: found.kept, record: record))
            }
            return .tampered(.init(reason: .tagMismatch, current: keys, restore: record.map { r in keys.filter(r.recipients.contains) },
                                   record: record))
        }
        guard let record else { return .verified(.firstUse) }
        if constantTimeEqual(linkKey(secret), record.linkKey) { return .verified(.unchanged) }
        if verifyLink(manifest.secretLink, linkKey: record.linkKey, to: secret, vaultId: id) { return .verified(.rotated) }
        let known = Set(record.recipients)
        if keys.allSatisfy(known.contains) { return .verified(.onlyKnownKeys) }
        return .tampered(.init(reason: .secretUnconfirmed, current: keys, restore: keys.filter(known.contains), record: record))
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// 32 bytes from exactly 64 lowercase hex digits, else nil.
    static func unhex(_ s: String) -> Data? {
        let u = Array(s.utf8)
        guard u.count == 64 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            default: return nil
            }
        }
        var out = Data(capacity: 32)
        var i = 0
        while i < 64 {
            guard let hi = nibble(u[i]), let lo = nibble(u[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}

/// How a reader classified `vault.json`'s recipients (format.md §2.1).
public enum RecipientsStatus: Hashable, Sendable {
    /// The vault is locked: nothing was checked.
    case notChecked
    /// No tag and no sign there ever was one: written before §2.1. Writers
    /// upgrade it (`Vault.upgradeRecipientsTag`).
    case untagged
    /// The tag verifies, and the secret is the one this device knew (or a
    /// confirmed successor of it).
    case verified(Verification)
    /// Refused for writing (`VaultError.untrustedRecipients`).
    case tampered(RecipientsProblem)

    /// Why a list counts as verified.
    public enum Verification: String, Hashable, Sendable, Codable {
        /// Same secret as this device's trust record.
        case unchanged
        /// No trust record yet: first use on this device.
        case firstUse
        /// The secret rotated and `secretLink` verifies under the record.
        case rotated
        /// The secret changed without a link this device can check, but the
        /// list holds only keys this device already trusted.
        case onlyKnownKeys
    }

    /// True when writers may encrypt to the list: verified or untagged.
    public var allowsWriting: Bool {
        switch self {
        case .tampered: return false
        case .notChecked, .untagged, .verified: return true
        }
    }

    /// The problem, when tampered.
    public var problem: RecipientsProblem? {
        if case .tampered(let p) = self { return p }
        return nil
    }

    /// `verified`, `untagged`, `tampered` or `not-checked`, for reports.
    public var name: String {
        switch self {
        case .notChecked: return "not-checked"
        case .untagged: return "untagged"
        case .verified: return "verified"
        case .tampered: return "tampered"
        }
    }
}

/// A recipients list refused for writing (format.md §2.1).
public struct RecipientsProblem: Hashable, Sendable {
    public enum Reason: String, Hashable, Sendable, Codable {
        /// `recipientsTag` does not verify (or is malformed).
        case tagMismatch
        /// The tag was removed from a vault that had one (a downgrade).
        case tagRemoved
        /// The secret changed without a `secretLink` this device can check,
        /// and the list holds keys it never verified.
        case secretUnconfirmed
    }

    public var reason: Reason
    /// Keys listed now that are not in the last verified list; when that list
    /// is not known, every listed key (none can be confirmed).
    public var unexpected: [String]
    /// Keys of the last verified list that are no longer listed.
    public var missing: [String]
    /// The last verified list (in the current order), which a repair writes;
    /// nil when this device cannot tell it.
    public var restore: [String]?

    init(reason: Reason, current: [String], restore: [String]?, record: RecipientsTrustRecord?) {
        self.reason = reason
        let restore = restore.flatMap { $0.isEmpty ? nil : $0 }
        self.restore = restore
        if let restore {
            let keep = Set(restore)
            unexpected = current.filter { !keep.contains($0) }
        } else {
            unexpected = current
        }
        let now = Set(current)
        var missing = (restore ?? []).filter { !now.contains($0) }
        for k in record?.recipients ?? [] where !now.contains(k) && !missing.contains(k) { missing.append(k) }
        self.missing = missing
    }

    public init(reason: Reason, unexpected: [String], missing: [String], restore: [String]?) {
        self.reason = reason; self.unexpected = unexpected; self.missing = missing; self.restore = restore
    }
}

/// What a device remembers about a vault's recipients (format.md §2.1
/// "Trust record"): never stored in the vault, and holding no secret.
public struct RecipientsTrustRecord: Codable, Hashable, Sendable {
    public static let formatName = "sempere-trust/1"

    public var format: String
    public var vaultId: UUID
    /// `linkKey` of the last verified secret (32 bytes).
    public var linkKey: Data
    /// The keys of the last verified list, in order.
    public var recipients: [String]

    public init(vaultId: UUID, linkKey: Data, recipients: [String]) {
        format = Self.formatName
        self.vaultId = vaultId; self.linkKey = linkKey; self.recipients = recipients
    }

    /// The record for a list verified under `secret`.
    public init(vaultId: UUID, secret: VaultSecret, recipients: [String]) {
        self.init(vaultId: vaultId, linkKey: RecipientsAuth.linkKey(secret), recipients: recipients)
    }

    enum CodingKeys: String, CodingKey { case format, vaultId, linkKey, recipients }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        guard format == Self.formatName else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: c, debugDescription: "not \(Self.formatName)")
        }
        vaultId = try c.decode(LowercaseUUID.self, forKey: .vaultId).uuid
        guard let key = RecipientsAuth.unhex(try c.decode(String.self, forKey: .linkKey)) else {
            throw DecodingError.dataCorruptedError(forKey: .linkKey, in: c, debugDescription: "not 64 hex digits")
        }
        linkKey = key
        recipients = try c.decode([String].self, forKey: .recipients)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(LowercaseUUID(vaultId), forKey: .vaultId)
        try c.encode(RecipientsAuth.hex(linkKey), forKey: .linkKey)
        try c.encode(recipients, forKey: .recipients)
    }
}

/// Where a device keeps its trust records.
public protocol RecipientsTrustStore: Sendable {
    /// The record of `vaultId`, nil when there is none (or it is unreadable).
    func record(for vaultId: UUID) -> RecipientsTrustRecord?
    /// Saves (replaces) the record of its vault.
    func save(_ record: RecipientsTrustRecord) throws
}

/// Trust records as files `<directory>/<vaultId>.json` (mode 0600).
public struct FileRecipientsTrustStore: RecipientsTrustStore {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// The largest record file read.
    static let maxFileBytes = 1 << 20

    /// `$XDG_STATE_HOME/sempere/trust`, else `~/.local/state/sempere/trust`.
    public static func cliDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        DeviceState.defaultURL(environment: environment, home: home).deletingLastPathComponent()
            .appendingPathComponent("trust", isDirectory: true)
    }

    func fileURL(_ vaultId: UUID) -> URL {
        directory.appendingPathComponent("\(vaultId.uuidString.lowercased()).json")
    }

    public func record(for vaultId: UUID) -> RecipientsTrustRecord? {
        let url = fileURL(vaultId)
        guard FileIO.exists(url),
              let data = try? BoundedRead.contents(of: url, maxBytes: Self.maxFileBytes),
              let r = try? JSONDecoder().decode(RecipientsTrustRecord.self, from: data),
              r.vaultId == vaultId else { return nil }
        return r
    }

    public func save(_ record: RecipientsTrustRecord) throws {
        try FileIO.createDirectory(directory)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = fileURL(record.vaultId)
        try FileIO.writeAtomically(try enc.encode(record), to: url, replacing: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Trust records in memory (tests, and readers that keep none on disk).
public final class MemoryRecipientsTrustStore: RecipientsTrustStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UUID: RecipientsTrustRecord] = [:]

    public init() {}

    public func record(for vaultId: UUID) -> RecipientsTrustRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[vaultId]
    }

    public func save(_ record: RecipientsTrustRecord) throws {
        lock.lock(); defer { lock.unlock() }
        records[record.vaultId] = record
    }

    /// Forgets every record.
    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        records = [:]
    }
}

extension Vault {
    /// Whether a `vault.json` received from elsewhere (a sync server) may
    /// replace the local one (format.md §2.1): nil when it may, else why not.
    ///
    /// It may when it lists the same keys as `local` (and keeps a tag `local`
    /// has), or when `vault` is unlocked and the incoming list verifies: its
    /// tag under the secret it carries, and that secret is the local one or
    /// a confirmed successor (`secretLink`). The anchor is this device's
    /// trust record when it has one, else the local vault's own secret and
    /// list. Without a key a changed list cannot be checked and is refused.
    ///
    /// - Parameters:
    ///   - data: the incoming bytes.
    ///   - local: the local `vault.json` bytes; nil on a first pull (accepted).
    ///   - vault: the local vault, opened with identities if possible.
    public static func incomingManifestProblem(_ data: Data, local: Data?, vault: Vault?) -> String? {
        let incoming: VaultManifest
        do { incoming = try readManifest(data) } catch { return "the incoming vault.json does not parse: \(error)" }
        guard let local else { return nil }
        guard let mine = try? readManifest(local) else { return nil }   // a damaged local copy: take the remote one
        guard incoming.vaultId == mine.vaultId else { return "the incoming vault.json belongs to another vault" }
        let sameKeys = incoming.recipients.map(\.key) == mine.recipients.map(\.key)
        if sameKeys, incoming.recipientsTag != nil || mine.recipientsTag == nil { return nil }
        guard let vault, vault.canRead, vault.vaultId == mine.vaultId else {
            return sameKeys ? "the incoming vault.json drops the device list's tag (format.md §2.1); unlock (--identity) to check it"
                : "the incoming vault.json changes the device list; unlock (--identity) so it can be checked (format.md §2.1)"
        }
        let secret: VaultSecret
        do { secret = try decryptSecret(incoming.vaultSecret, with: vault.identities) } catch {
            return "the incoming vault.json's secret does not open with this key: \(error)"
        }
        var anchor = vault.trustStore?.record(for: vault.vaultId)
        if anchor == nil, vault.recipientsStatus.allowsWriting, let own = vault.secret {
            anchor = RecipientsTrustRecord(vaultId: vault.vaultId, secret: own, recipients: vault.recipients.map(\.key))
        }
        switch RecipientsAuth.evaluate(incoming, secret: secret, record: anchor) {
        case .verified, .notChecked: return nil
        case .untagged:
            return sameKeys ? nil : "the incoming vault.json changes the device list without a tag (format.md §2.1)"
        case .tampered(let p): return "the incoming vault.json was not written with the vault's key: \(p.description)"
        }
    }
}
