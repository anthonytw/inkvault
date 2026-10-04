import Age
import Foundation

/// Errors from the vault directory layer.
public enum VaultError: Error, Hashable, Sendable {
    /// `create` needs a directory name ending in `.inkvault` (format.md §1).
    case invalidVaultName(String)
    /// The path (a vault, a revision file, an identity file) already exists.
    case alreadyExists(String)
    /// No `vault.json` at the given location.
    case notAVault(String)
    /// `vault.json` does not parse or breaks a rule of format.md §2.
    case manifestCorrupt(String)
    /// `vault.json` names a format other than `inkvault/1`.
    case unsupportedFormat(String)
    /// A vault needs at least one recipient.
    case noRecipients
    /// Not a Bech32 `age1...` X25519 recipient.
    case invalidRecipient(String)
    /// The recipient is already listed.
    case duplicateRecipient(String)
    /// The recipient is not listed.
    case unknownRecipient(String)
    /// Removing the only recipient would leave the vault unreadable.
    case lastRecipient
    /// `labels` must be empty or match `recipients` one to one.
    case labelCountMismatch
    /// None of the identities decrypts `vaultSecret`.
    case vaultSecretUndecryptable(String)
    /// `vaultSecret` decrypts but is not 32 bytes.
    case invalidVaultSecret
    /// The operation needs the vault secret; the vault was opened without
    /// identities (read-only, names only).
    case locked
    /// The operation reads note files, but the vault holds no identities
    /// (created write-only: it has the secret but cannot decrypt).
    case noIdentities
    /// A recipient change is still unfinished because these files (as
    /// `<noteId>/<file>`) could not be rewrapped; fix or remove them and call
    /// `resumeRewrap()` before starting another change.
    case rewrapIncomplete([String])
    /// Not a lowercase hyphenated UUID note directory name.
    case invalidNoteId(String)
    /// Another revision of this note already uses `(device, seq)`.
    case seqInUse(device: String, seq: Int)
    /// A revision could not be read; `name` is its file name.
    case revision(name: String, RevisionReadError)
    /// Writers use scrypt work factors 15...18 (format.md §3.2).
    case workFactorOutOfRange(Int)
    /// The identity file's scrypt work factor exceeds the reader's cap.
    case workFactorTooHigh
    /// No `keys/<recipient>.key.age`.
    case identityFileMissing(String)
    /// The passphrase does not decrypt the identity file.
    case wrongPassphrase
    /// The identity file decrypts but holds no `AGE-SECRET-KEY-1...` line, or
    /// is not a single-scrypt-recipient age file.
    case identityFileMalformed
    /// The identity in the file does not match the recipient in its name.
    case identityMismatch(String)
    /// The recipient-change journal exists but cannot be read.
    case rewrapJournalUnreadable(String)
    /// Test hook: a rewrap stopped after the requested number of files.
    case interrupted
    /// A filesystem operation failed.
    case io(String)
}

/// Why one revision file could not be read, by stage. (Vault-level
/// preconditions, such as a locked vault, are `VaultError`s.)
public enum RevisionReadError: Error, Hashable, Sendable {
    /// The file could not be read from disk.
    case unreadable(String)
    /// age decryption failed (no matching identity, bad header, corrupt payload).
    case undecryptable(String)
    /// The inner HMAC tag does not match (format.md §4): tampered, replayed
    /// under another note or name, or written under another vault secret.
    case tagMismatch
    /// The tag does not match the current secret while a recipient change
    /// is pending whose journal (holding the outgoing secret) could not be
    /// read; the detail says why. The file may be fine once the journal is.
    case tagMismatchJournalUnreadable(String)
    /// The plaintext is not a valid framed gzip body.
    case corruptBody(String)
    /// The JSON does not decode as a revision, or names another note or file.
    case undecodable(String)
}

/// A vault directory (`*.inkvault`, format.md §1) opened with zero or more
/// age identities.
///
/// Opened with identities that decrypt `vaultSecret`, the vault can read,
/// verify and write revisions and change recipients. Opened without
/// identities it is locked: it lists notes, revision names and identity
/// files only.
public struct Vault: Sendable {
    /// The `.inkvault` directory.
    public let url: URL
    /// The manifest as last read or written.
    public private(set) var manifest: VaultManifest
    let identities: [any AgeIdentity]
    /// The vault secret; nil when locked.
    private(set) var secret: VaultSecret?
    /// During an unfinished secret-rotating rewrap: the secret files not yet
    /// rewrapped are still tagged with.
    private(set) var previousSecret: VaultSecret?
    /// Why a pending rewrap journal could not be read when the vault was
    /// opened (nil when there is none, it read fine, or the vault is locked).
    public private(set) var journalProblem: String?

    static let manifestName = "vault.json"
    static let keysName = "keys"
    static let notesName = "notes"
    /// Recipient-change journal (docs/io.md). An unknown file to other readers.
    static let journalName = "rewrap-journal.json"

    var manifestURL: URL { url.appendingPathComponent(Self.manifestName) }
    var keysURL: URL { url.appendingPathComponent(Self.keysName) }
    var notesURL: URL { url.appendingPathComponent(Self.notesName) }
    var journalURL: URL { url.appendingPathComponent(Self.journalName) }

    /// The recipients every file is encrypted to.
    public var recipients: [VaultManifest.Recipient] { manifest.recipients }
    /// `vaultId` from the manifest.
    public var vaultId: UUID { manifest.vaultId }
    /// True when opened without identities: no vault secret, names only.
    public var isLocked: Bool { secret == nil }
    /// True when note files can be decrypted and verified: the vault secret
    /// is known and at least one identity is held. A vault created with
    /// `identities: []` is unlocked (it can write) but cannot read.
    public var canRead: Bool { secret != nil && !identities.isEmpty }
    /// True when a recipient change was interrupted; `resumeRewrap()` (or
    /// repeating the same `addRecipient`/`removeRecipient`) finishes it.
    public var pendingRewrap: Bool { FileIO.exists(journalURL) }

    // MARK: - Create and open

    /// Creates a vault: `vault.json` with a fresh `vaultId` and a fresh
    /// 32-byte vault secret encrypted (armored) to `recipients`, plus empty
    /// `keys/` and `notes/`.
    ///
    /// - Parameters:
    ///   - url: a directory whose name ends in `.inkvault`; it may exist but
    ///     must not hold a `vault.json`.
    ///   - labels: empty, or one label per recipient.
    ///   - identities: kept for reading; may be empty (write-only use).
    ///   - vaultId, created: fixed values for reproducible fixtures.
    public static func create(at url: URL, recipients: [X25519Recipient], labels: [String] = [],
                              identities: [any AgeIdentity] = [], vaultId: UUID = UUID(),
                              created: Date = Date()) throws -> Vault {
        guard url.lastPathComponent.hasSuffix(".inkvault"), url.lastPathComponent.count > ".inkvault".count else {
            throw VaultError.invalidVaultName(url.lastPathComponent)
        }
        guard !recipients.isEmpty else { throw VaultError.noRecipients }
        guard labels.isEmpty || labels.count == recipients.count else { throw VaultError.labelCountMismatch }
        let keys = recipients.map(\.string)
        if let dup = firstDuplicate(keys) { throw VaultError.duplicateRecipient(dup) }
        let manifestURL = url.appendingPathComponent(manifestName)
        guard !FileIO.exists(manifestURL) else { throw VaultError.alreadyExists(manifestURL.path) }

        let secret = VaultSecret.random()
        let entries = keys.enumerated().map { i, k in
            VaultManifest.Recipient(key: k, label: labels.isEmpty ? "" : labels[i], added: created)
        }
        let manifest = VaultManifest(vaultId: vaultId, created: created, recipients: entries,
                                     vaultSecret: try encryptSecret(secret, to: recipients))
        try FileIO.createDirectory(url)
        try FileIO.createDirectory(url.appendingPathComponent(keysName))
        try FileIO.createDirectory(url.appendingPathComponent(notesName))
        let written = try writeManifest(manifest, to: manifestURL, replacing: false)
        return Vault(url: url, manifest: written, identities: identities, secret: secret, previousSecret: nil,
                     journalProblem: nil)
    }

    /// Opens a vault. With identities, decrypts the vault secret using the
    /// first that matches; with none, opens locked (names only).
    ///
    /// - Throws: `notAVault`, `manifestCorrupt`, `unsupportedFormat`,
    ///   `vaultSecretUndecryptable`, `invalidVaultSecret`.
    public static func open(at url: URL, identities: [any AgeIdentity] = []) throws -> Vault {
        let manifestURL = url.appendingPathComponent(manifestName)
        guard FileIO.exists(manifestURL) else { throw VaultError.notAVault(url.path) }
        let manifest = try readManifest(FileIO.read(manifestURL))
        var vault = Vault(url: url, manifest: manifest, identities: identities, secret: nil, previousSecret: nil,
                          journalProblem: nil)
        guard !identities.isEmpty else { return vault }
        vault.secret = try decryptSecret(manifest.vaultSecret, with: identities)
        if vault.pendingRewrap {
            // Recorded, not thrown: the vault stays usable, verify() and
            // tag mismatches surface it, and resumeRewrap() throws it.
            do { vault.previousSecret = try vault.readJournal().previous } catch {
                vault.journalProblem = "\(error)"
            }
        }
        return vault
    }

    /// Parses and validates manifest bytes (format, recipients).
    static func readManifest(_ data: Data) throws -> VaultManifest {
        let manifest: VaultManifest
        do { manifest = try VaultManifest.decode(data) } catch {
            throw VaultError.manifestCorrupt("\(error)")
        }
        guard manifest.format == InkVaultFormat.identifier else {
            throw VaultError.unsupportedFormat(manifest.format)
        }
        guard !manifest.recipients.isEmpty else { throw VaultError.manifestCorrupt("no recipients") }
        for r in manifest.recipients {
            guard (try? X25519Recipient(string: r.key)) != nil else {
                throw VaultError.manifestCorrupt("invalid recipient \(r.key)")
            }
        }
        if let dup = firstDuplicate(manifest.recipients.map(\.key)) {
            throw VaultError.manifestCorrupt("duplicate recipient \(dup)")
        }
        return manifest
    }

    /// Writes the manifest atomically and returns it as it will read back
    /// (dates at millisecond precision).
    static func writeManifest(_ m: VaultManifest, to url: URL, replacing: Bool) throws -> VaultManifest {
        let data = try m.encoded()
        try FileIO.writeAtomically(data, to: url, replacing: replacing)
        return try VaultManifest.decode(data)
    }

    static func encryptSecret(_ secret: VaultSecret, to recipients: [X25519Recipient]) throws -> String {
        String(decoding: try AgeFile.encrypt(secret.bytes, to: recipients, armor: true), as: UTF8.self)
    }

    static func decryptSecret(_ armored: String, with identities: [any AgeIdentity]) throws -> VaultSecret {
        let plain: Data
        do { plain = try AgeFile.decrypt(Data(armored.utf8), with: identities) } catch {
            throw VaultError.vaultSecretUndecryptable("\(error)")
        }
        guard let s = try? VaultSecret(bytes: plain) else { throw VaultError.invalidVaultSecret }
        return s
    }

    static func firstDuplicate(_ keys: [String]) -> String? {
        var seen = Set<String>()
        for k in keys where !seen.insert(k).inserted { return k }
        return nil
    }

    /// The manifest recipients as age recipients.
    func ageRecipients() throws -> [X25519Recipient] {
        try manifest.recipients.map { r in
            do { return try X25519Recipient(string: r.key) } catch { throw VaultError.invalidRecipient(r.key) }
        }
    }

    func requireSecret() throws -> VaultSecret {
        guard let secret else { throw VaultError.locked }
        return secret
    }

    /// The secret, for operations that also decrypt note files.
    func requireReadable() throws -> VaultSecret {
        let secret = try requireSecret()
        guard !identities.isEmpty else { throw VaultError.noIdentities }
        return secret
    }

    // MARK: - Recipients (format.md §3.3)

    /// What a recipient change did to the files under `notes/`.
    public struct RewrapReport: Hashable, Sendable {
        /// Files re-encrypted in this run, as `<noteId>/<file>`.
        public var rewrapped: [String] = []
        /// Files already encrypted to the current set (and tagged with the
        /// current secret); left untouched.
        public var alreadyCurrent: [String] = []
        /// Files left untouched because they could not be read or verified.
        /// While any remain the journal is kept (`pendingRewrap` stays true)
        /// and `resumeRewrap()` retries them.
        public var failures: [String: RevisionReadError] = [:]

        public init() {}

        /// True when every file is encrypted to the current recipients.
        public var isComplete: Bool { failures.isEmpty }

        mutating func merge(_ o: RewrapReport) {
            rewrapped += o.rewrapped
            alreadyCurrent += o.alreadyCurrent
            failures.merge(o.failures) { $1 }
        }
    }

    /// Adds a recipient: re-encrypts `vaultSecret` and then every revision
    /// to the new set (payload unchanged). Finishes an interrupted change
    /// first; repeating an interrupted `addRecipient` call completes it.
    @discardableResult
    public mutating func addRecipient(_ recipient: X25519Recipient, label: String,
                                      added: Date = Date()) throws -> RewrapReport {
        try addRecipient(recipient, label: label, added: added, stopAfter: nil)
    }

    /// Removes a recipient: rotates the vault secret, re-encrypts it to the
    /// remaining set, then re-encrypts and re-tags every revision (gzip bytes
    /// unchanged). Finishes an interrupted change first; repeating an
    /// interrupted `removeRecipient` call completes it.
    @discardableResult
    public mutating func removeRecipient(_ recipient: X25519Recipient) throws -> RewrapReport {
        try removeRecipient(recipient, stopAfter: nil)
    }

    /// Finishes an interrupted recipient change: rewraps every file not yet
    /// encrypted to the current recipients, then deletes the journal.
    @discardableResult
    public mutating func resumeRewrap() throws -> RewrapReport {
        try resumeRewrap(stopAfter: nil)
    }

    mutating func addRecipient(_ recipient: X25519Recipient, label: String, added: Date,
                               stopAfter: Int?) throws -> RewrapReport {
        _ = try requireSecret()
        let key = recipient.string
        var report = RewrapReport()
        let resumed = pendingRewrap
        if resumed {
            report = try resumeRewrap(stopAfter: stopAfter)
            guard report.isComplete else {
                // The earlier change is the one the caller repeated, or one
                // that must finish first; either way nothing new starts.
                if manifest.recipients.contains(where: { $0.key == key }) { return report }
                throw VaultError.rewrapIncomplete(report.failures.keys.sorted())
            }
        }
        if manifest.recipients.contains(where: { $0.key == key }) {
            guard resumed else { throw VaultError.duplicateRecipient(key) }
            return report
        }
        var next = manifest.recipients
        next.append(.init(key: key, label: label, added: added))
        report.merge(try changeRecipients(next, rotate: false, stopAfter: stopAfter))
        return report
    }

    mutating func removeRecipient(_ recipient: X25519Recipient, stopAfter: Int?) throws -> RewrapReport {
        _ = try requireSecret()
        let key = recipient.string
        var report = RewrapReport()
        let resumed = pendingRewrap
        if resumed {
            report = try resumeRewrap(stopAfter: stopAfter)
            guard report.isComplete else {
                if !manifest.recipients.contains(where: { $0.key == key }) { return report }
                throw VaultError.rewrapIncomplete(report.failures.keys.sorted())
            }
        }
        guard manifest.recipients.contains(where: { $0.key == key }) else {
            guard resumed else { throw VaultError.unknownRecipient(key) }
            return report
        }
        let next = manifest.recipients.filter { $0.key != key }
        guard !next.isEmpty else { throw VaultError.lastRecipient }
        report.merge(try changeRecipients(next, rotate: true, stopAfter: stopAfter))
        return report
    }

    mutating func resumeRewrap(stopAfter: Int?) throws -> RewrapReport {
        _ = try requireReadable()
        guard pendingRewrap else { return RewrapReport() }
        previousSecret = try readJournal().previous
        journalProblem = nil
        return try finishRewrap(stopAfter: stopAfter)
    }

    /// Rewraps, then removes the journal only if every file is complete.
    /// Otherwise the journal (and the outgoing secret in it) stays, so the
    /// files that failed can still be verified and rewrapped by a retry.
    mutating func finishRewrap(stopAfter: Int?) throws -> RewrapReport {
        let report = try rewrapNotes(stopAfter: stopAfter)
        guard report.isComplete else { return report }
        try FileIO.remove(journalURL)
        previousSecret = nil
        return report
    }

    /// Journal first (holding the outgoing secret when rotating; durable
    /// before vault.json changes, since the atomic write fsyncs the
    /// directory), then the manifest, then the files, then the journal is
    /// removed if every file is complete. See format.md §3.3.1, docs/io.md.
    mutating func changeRecipients(_ next: [VaultManifest.Recipient], rotate: Bool,
                                   stopAfter: Int?) throws -> RewrapReport {
        let current = try requireReadable()
        let ageNext = try next.map { r in
            do { return try X25519Recipient(string: r.key) } catch { throw VaultError.invalidRecipient(r.key) }
        }
        let newSecret = rotate ? VaultSecret.random() : current
        let journal = RewrapJournal(format: InkVaultFormat.identifier,
                                    previousVaultSecret: rotate ? try Self.encryptSecret(current, to: ageNext) : nil)
        try FileIO.writeAtomically(try InkJSON.encoder().encode(journal), to: journalURL, replacing: true)
        previousSecret = rotate ? current : nil

        var m = manifest
        m.recipients = next
        m.vaultSecret = try Self.encryptSecret(newSecret, to: ageNext)
        manifest = try Self.writeManifest(m, to: manifestURL, replacing: true)
        secret = newSecret

        return try finishRewrap(stopAfter: stopAfter)
    }

    struct RewrapJournal: Codable {
        var format: String
        /// Armored age file holding the secret that files not yet rewrapped
        /// are tagged with; absent when the change did not rotate the secret.
        var previousVaultSecret: String?
    }

    func readJournal() throws -> (journal: RewrapJournal, previous: VaultSecret?) {
        let j: RewrapJournal
        do { j = try InkJSON.decoder().decode(RewrapJournal.self, from: try FileIO.read(journalURL)) } catch {
            throw VaultError.rewrapJournalUnreadable("\(error)")
        }
        guard let armored = j.previousVaultSecret else { return (j, nil) }
        do { return (j, try Self.decryptSecret(armored, with: identities)) } catch {
            throw VaultError.rewrapJournalUnreadable("previous secret: \(error)")
        }
    }

    /// Re-encrypts every revision file not yet current (format.md §3.3.1).
    /// A file is current when its header has exactly one X25519 stanza per
    /// recipient (and no other stanzas) and its tag
    /// verifies under the current secret; such files are skipped, which is
    /// what makes a second run finish an interrupted one.
    func rewrapNotes(stopAfter: Int?) throws -> RewrapReport {
        let current = try requireSecret()
        let recips = try ageRecipients()
        var report = RewrapReport()
        for note in try noteDirectoryNames() {
            let dir = notesURL.appendingPathComponent(note)
            for name in try revisionFileNames(in: dir) {
                let path = "\(note)/\(name)"
                let file = dir.appendingPathComponent(name)
                let data: Data
                do { data = try FileIO.read(file) } catch {
                    report.failures[path] = .unreadable("\(error)"); continue
                }
                let stanzaCount: Int
                let plain: Data
                do {
                    stanzaCount = try Self.x25519StanzaCount(data)
                    plain = try AgeFile.decrypt(data, with: identities)
                } catch {
                    report.failures[path] = .undecryptable("\(error)"); continue
                }
                let body: Data
                do {
                    _ = try BodyFraming.unframe(plain, noteId: note, filename: name, secret: current)
                    if stanzaCount == recips.count {
                        report.alreadyCurrent.append(path); continue
                    }
                    body = plain
                } catch BodyFramingError.tagMismatch {
                    guard let previousSecret,
                          let old = try? BodyFraming.unframe(plain, noteId: note, filename: name, secret: previousSecret)
                    else { report.failures[path] = .tagMismatch; continue }
                    body = BodyFraming.retag(old, noteId: note, filename: name, secret: current)
                } catch {
                    report.failures[path] = .corruptBody("\(error)"); continue
                }
                if let stopAfter, report.rewrapped.count >= stopAfter { throw VaultError.interrupted }
                try FileIO.writeAtomically(try AgeFile.encrypt(body, to: recips), to: file, replacing: true)
                report.rewrapped.append(path)
            }
        }
        return report
    }

    /// One per X25519 stanza, or -1 when the header has any other stanza
    /// type (never "complete" under format.md §3.3.1).
    static func x25519StanzaCount(_ data: Data) throws -> Int {
        let stanzas = try AgeFile.parseHeader(data).header.stanzas
        return stanzas.allSatisfy { $0.type == "X25519" } ? stanzas.count : -1
    }

    // MARK: - Listing helpers

    /// Lowercase-UUID directory names under `notes/`, sorted.
    func noteDirectoryNames() throws -> [String] {
        try FileIO.entries(notesURL).filter { Self.isNoteDirectoryName($0) && FileIO.isDirectory(notesURL.appendingPathComponent($0)) }
    }

    static func isNoteDirectoryName(_ s: String) -> Bool {
        guard let u = UUID(uuidString: s) else { return false }
        return u.uuidString.lowercased() == s
    }

    /// Canonical revision file names in a note directory (regular files only).
    func revisionFileNames(in dir: URL) throws -> [String] {
        try FileIO.entries(dir).filter { n in
            guard let r = RevisionName(n), r.filename == n else { return false }
            return !FileIO.isDirectory(dir.appendingPathComponent(n))
        }
    }
}
