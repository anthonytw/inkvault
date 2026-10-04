import Age
import Foundation

/// A revision file taken apart without decoding the JSON.
public struct RecoveredRevision: Hashable, Sendable {
    /// The revision JSON, exactly as `gunzip` prints it.
    public var json: Data
    /// True when the inner HMAC tag was checked against the vault secret and
    /// matched; false when no vault secret was available.
    public var verified: Bool
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
    /// - Throws: `AgeError` if age decryption fails, `BodyFramingError` for
    ///   a bad frame or a tag mismatch, `VaultError`/`RevisionReadError` for
    ///   a corrupt gzip body.
    public static func decrypt(_ file: Data, noteId: String, filename: String,
                               identities: [any AgeIdentity], vault: Vault?) throws -> RecoveredRevision {
        let plain = try AgeFile.decrypt(file, with: identities)
        let unframed: BodyFraming.Unframed
        if let vault, let secret = vault.secret {
            unframed = try Vault.unframe(plain, note: noteId, filename: filename, secret: secret,
                                         previous: vault.previousSecret)
        } else {
            unframed = try BodyFraming.unframe(plain, noteId: noteId, filename: filename, secret: nil)
        }
        let json: Data
        do { json = try Gzip.decompress(unframed.gzip) } catch {
            throw RevisionReadError.corruptBody("\(error)")
        }
        return RecoveredRevision(json: json, verified: unframed.verified)
    }
}
