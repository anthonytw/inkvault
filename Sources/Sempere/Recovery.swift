import Age
import Foundation

/// A revision file taken apart without decoding the JSON.
public struct RecoveredRevision: Hashable, Sendable {
    /// The revision JSON, exactly as `gunzip` prints it.
    public var json: Data
    /// True when the inner HMAC tag was checked against the vault secret and
    /// matched; false when no vault secret was available.
    public var verified: Bool
    /// True when a vault secret was available and the tag did NOT match, and
    /// the caller asked to proceed anyway (`TagPolicy.allowMismatch`).
    public var tagMismatch = false
}

/// What `Recovery.decrypt` does when the tag does not match.
public enum TagPolicy: Sendable {
    /// Throw `BodyFramingError.tagMismatch`.
    case fail
    /// Return the body with `tagMismatch == true` (for damaged vaults).
    case allowMismatch
}

/// The "get my data out" path (format.md §4): one `.age` file and an
/// identity, with the vault's help when it can be found.
public enum Recovery {
    /// Decrypts one revision file and returns its JSON.
    ///
    /// - Parameters:
    ///   - file: the bytes of the `.age` file.
    ///   - noteId, filename: the note directory name and file name the tag
    ///     binds to (only used when `vault` is given).
    ///   - identities: age identities to try.
    ///   - vault: when given and unlocked, the tag is verified (also under
    ///     the previous secret during an unfinished rewrap).
    ///   - onMismatch: what to do when the tag does not match.
    /// - Throws: `AgeError` if age decryption fails, `BodyFramingError` for
    ///   a bad frame or a tag mismatch, `VaultError`/`RevisionReadError` for
    ///   a corrupt gzip body.
    public static func decrypt(_ file: Data, noteId: String, filename: String,
                               identities: [any AgeIdentity], vault: Vault?,
                               onMismatch: TagPolicy = .fail) throws -> RecoveredRevision {
        let plain = try AgeFile.decrypt(file, with: identities)
        var unframed: BodyFraming.Unframed
        var mismatch = false
        if let vault, let secret = vault.secret {
            do {
                unframed = try Vault.unframe(plain, note: noteId, filename: filename, secret: secret,
                                             previous: vault.previousSecret)
            } catch BodyFramingError.tagMismatch where onMismatch == .allowMismatch {
                unframed = try BodyFraming.unframe(plain, noteId: noteId, filename: filename, secret: nil)
                mismatch = true
            }
        } else {
            unframed = try BodyFraming.unframe(plain, noteId: noteId, filename: filename, secret: nil)
        }
        let json: Data
        do { json = try Gzip.decompress(unframed.gzip) } catch {
            throw RevisionReadError.corruptBody("\(error)")
        }
        return RecoveredRevision(json: json, verified: unframed.verified, tagMismatch: mismatch)
    }
}
