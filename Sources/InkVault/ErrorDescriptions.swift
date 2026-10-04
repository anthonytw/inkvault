import Foundation

extension VaultError: CustomStringConvertible {
    /// A human sentence for each case, for tools that show errors to people.
    public var description: String {
        switch self {
        case .invalidVaultName(let n): return "'\(n)' is not a vault name: a vault directory must end in .inkvault"
        case .alreadyExists(let p): return "\(p) already exists"
        case .notAVault(let p): return "\(p) is not a vault (no vault.json)"
        case .manifestCorrupt(let why): return "vault.json is damaged: \(why)"
        case .unsupportedFormat(let f): return "this vault uses format '\(f)', which this version cannot read"
        case .noRecipients: return "a vault needs at least one recipient"
        case .invalidRecipient(let r): return "'\(r)' is not an age recipient (age1...)"
        case .duplicateRecipient(let r): return "recipient \(r) is listed twice"
        case .unknownRecipient(let r): return "recipient \(r) is not part of this vault"
        case .lastRecipient: return "cannot remove the only recipient: the vault would become unreadable"
        case .labelCountMismatch: return "give no labels, or one label per recipient"
        case .vaultSecretUndecryptable: return "none of the given keys can decrypt this vault"
        case .invalidVaultSecret: return "the vault secret in vault.json is malformed"
        case .locked: return "the vault is locked: no key was given"
        case .noIdentities: return "no key was given, so notes cannot be decrypted"
        case .rewrapIncomplete(let files):
            return "a recipient change is unfinished (\(files.count) file(s) not rewrapped)"
        case .invalidNoteId(let n): return "'\(n)' is not a note id (lowercase UUID)"
        case .seqInUse(let device, let seq): return "device \(device) already has a revision with sequence number \(seq)"
        case .revision(let name, let inner): return "\(name): \(inner)"
        case .workFactorOutOfRange(let n): return "scrypt work factor \(n) is outside the allowed range 15...18"
        case .workFactorTooHigh: return "the key file needs more scrypt work than this reader allows"
        case .identityFileMissing(let n): return "no stored key file \(n)"
        case .wrongPassphrase: return "wrong passphrase for the stored key file"
        case .identityFileMalformed: return "the stored key file holds no AGE-SECRET-KEY identity"
        case .identityMismatch(let r): return "the stored key file does not belong to recipient \(r)"
        case .rewrapJournalUnreadable(let why): return "the rewrap journal cannot be read: \(why)"
        case .interrupted: return "interrupted (test hook)"
        case .io(let why): return why
        }
    }
}

extension RevisionReadError: CustomStringConvertible {
    /// A human sentence for each case.
    public var description: String {
        switch self {
        case .unreadable(let why): return "cannot read the file: \(why)"
        case .undecryptable(let why): return "cannot decrypt: \(why)"
        case .tagMismatch: return "tag mismatch: the file was altered, moved or written under another vault secret"
        case .tagMismatchJournalUnreadable(let why): return "tag mismatch (\(why))"
        case .corruptBody(let why): return "damaged body: \(why)"
        case .undecodable(let why): return "cannot decode the revision: \(why)"
        }
    }
}

extension NoteLogError: CustomStringConvertible {
    /// A human sentence for each case.
    public var description: String {
        switch self {
        case .noRevisions: return "the note has no revisions"
        case .mixedNotes(let a, let b): return "revisions of two notes were mixed (\(a), \(b))"
        case .conflictingRevisions(let device, let seq):
            return "device \(device) has two different revisions with sequence number \(seq)"
        case .notADelta(let n): return "\(n) is not a delta"
        }
    }
}

extension BodyFramingError: CustomStringConvertible {
    /// A human sentence for each case.
    public var description: String {
        switch self {
        case .tooShort: return "the decrypted body is too short to be an InkVault file"
        case .badMagic: return "the decrypted body is not an InkVault file (bad magic)"
        case .unsupportedVersion(let v): return "unsupported body version \(v)"
        case .tagMismatch: return "tag mismatch: the file was altered, moved or belongs to another vault"
        case .invalidSecret: return "the vault secret is not 32 bytes"
        }
    }
}

extension HistoryError: CustomStringConvertible {
    /// A human sentence for each case.
    public var description: String {
        switch self {
        case .unknownRevision(let q): return "no revision of this note matches '\(q)'"
        case .ambiguousRevision(let q, let names):
            return "'\(q)' matches several revisions: \(names.map(\.filename).joined(separator: ", "))"
        case .incompleteHistory(let n):
            return "the note as of \(n.filename) cannot be rebuilt: earlier revisions were compacted away or are unreadable"
        }
    }
}
