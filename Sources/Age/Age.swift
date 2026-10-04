import Crypto
import Foundation

/// Spec-exact implementation of the age v1 file format
/// ([age-encryption.org/v1](https://c2sp.org/age)).
///
/// Scope (task 0.1 in docs/plan.md): X25519 and scrypt recipients, header
/// parsing and formatting, header HMAC, STREAM payload, ASCII armor, Bech32
/// identity and recipient encoding. Validated against the C2SP CCTV vectors
/// under Tests/AgeTests/Vectors and against the reference `age` CLI.
public enum AgeVersion {
    public static let header = "age-encryption.org/v1"
}

/// One-shot age encryption and decryption of in-memory buffers.
public enum Age {
    /// Encrypts `plaintext` to `recipients`.
    ///
    /// - Parameter armor: wrap the result in the PEM-style ASCII armor.
    /// - Throws: `AgeError.noRecipients` for an empty list,
    ///   `AgeError.scryptNotAlone` if a scrypt recipient is mixed with any
    ///   other recipient, or whatever a recipient's `wrap` throws.
    public static func encrypt(_ plaintext: Data, to recipients: [any AgeRecipient], armor: Bool = false) throws
        -> Data
    {
        guard !recipients.isEmpty else { throw AgeError.noRecipients }
        let fileKey = FileKey()
        var stanzas = [Stanza]()
        for r in recipients { stanzas += try r.wrap(fileKey: fileKey) }
        if stanzas.contains(where: { $0.type == "scrypt" }) && stanzas.count != 1 {
            throw AgeError.scryptNotAlone
        }
        var out = Data(try HeaderCodec.encodeWithoutMAC(stanzas))
        let mac = HeaderCodec.mac(fileKey: fileKey, macInput: out)
        out += Data(" \(Base64.encodeRaw(mac))\n".utf8)
        let nonce = Data(secureRandomBytes(Stream.nonceSize))
        out += nonce
        out += try Stream.encrypt(plaintext, key: Stream.payloadKey(fileKey: fileKey, nonce: nonce))
        return armor ? Armor.encode(out) : out
    }

    /// Decrypts an age file, binary or ASCII-armored (detected the way the
    /// `age` CLI does it: the BEGIN line after optional whitespace).
    ///
    /// Identities are tried in order; the first that unwraps the file key
    /// wins. An identity that throws aborts decryption.
    public static func decrypt(_ ciphertext: Data, with identities: [any AgeIdentity]) throws -> Data {
        let binary = Armor.isArmored(ciphertext) ? try Armor.decode(ciphertext) : ciphertext
        var released = Data()
        _ = try decrypt(binary: binary, with: identities, released: &released)
        return released
    }

    /// Parses the header of a binary age file. Returns the header and the
    /// offset of the payload (the 16-byte nonce) from `data.startIndex`.
    public static func parseHeader(_ data: Data) throws -> (header: Header, payloadStart: Int) {
        let (header, start) = try HeaderCodec.parse(data)
        return (header, start)
    }

    /// Decrypts a binary age file, appending authenticated plaintext to
    /// `released` chunk by chunk (so after a payload failure it holds what a
    /// streaming reader would already have handed out). Returns the file key.
    static func decrypt(binary data: Data, with identities: [any AgeIdentity], released: inout Data) throws
        -> FileKey
    {
        let (header, start) = try HeaderCodec.parse(data)
        guard !identities.isEmpty else { throw AgeError.noIdentities }
        var fileKey: FileKey?
        for identity in identities {
            if let key = try identity.unwrap(stanzas: header.stanzas) {
                fileKey = key
                break
            }
        }
        guard let fileKey else { throw AgeError.noMatchingIdentity }
        guard HeaderCodec.verifyMAC(fileKey: fileKey, header: header) else { throw AgeError.headerMAC }

        let payload = data.dropFirst(start)
        // A file that ends before the nonce is a header-level failure in
        // the reference implementation (and the CCTV vectors).
        guard payload.count >= Stream.nonceSize else { throw AgeError.headerParse }
        let nonce = payload.prefix(Stream.nonceSize)
        let key = Stream.payloadKey(fileKey: fileKey, nonce: nonce)
        try Stream.decrypt(payload.dropFirst(Stream.nonceSize), key: key, released: &released)
        return fileKey
    }
}
