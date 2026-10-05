import Age
import Foundation

/// The `age-keygen` style identity text (format.md §3.1–§3.2):
///
/// ```
/// # created: 2026-10-04T16:20:00Z
/// # public key: age1...
/// AGE-SECRET-KEY-1...
/// ```
public enum IdentityFile {
    /// Writers use scrypt work factors in this range (format.md §3.2).
    public static let writerWorkFactors = 15...18
    /// Readers accept up to 20 by default.
    public static let defaultMaxWorkFactor = 20
    /// The largest cap a reader may choose (format.md §3.2: "may accept up to 22").
    public static let maxAllowedWorkFactor = 22

    private static let suffix = ".key.age"

    /// `<recipient>.key.age`.
    public static func fileName(for recipient: X25519Recipient) -> String { recipient.string + suffix }

    /// The recipient named by a `keys/` file name, or nil if it is not one.
    public static func recipient(fromFileName name: String) -> X25519Recipient? {
        guard name.hasSuffix(suffix) else { return nil }
        return try? X25519Recipient(string: String(name.dropLast(suffix.count)))
    }

    /// The plaintext, `age-keygen` style, newline-terminated.
    public static func render(_ identity: X25519Identity, created: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return "# created: \(f.string(from: created))\n# public key: \(identity.recipient.string)\n\(identity.string)\n"
    }

    /// Parses `age-keygen` style text: the first line that is neither blank
    /// nor a `#` comment must be the identity. A `# public key:` comment, if
    /// present, must match it.
    public static func parse(_ text: String) throws -> X25519Identity {
        var declared: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let prefix = "# public key:"
                if line.hasPrefix(prefix) {
                    declared = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard let id = try? X25519Identity(string: line) else { throw VaultError.identityFileMalformed }
            if let declared, declared != id.recipient.string { throw VaultError.identityMismatch(declared) }
            return id
        }
        throw VaultError.identityFileMalformed
    }
}

extension Vault {
    /// Writes `keys/<recipient>.key.age`: the identity, `age-keygen` style,
    /// encrypted to a single scrypt recipient (`age -d` with the passphrase
    /// reads it).
    ///
    /// - Throws: `workFactorOutOfRange` outside 15...18; `alreadyExists`
    ///   unless `replace`.
    @discardableResult
    public func writeIdentityFile(_ identity: X25519Identity, passphrase: String, workFactor: Int = 18,
                                  created: Date = Date(), replace: Bool = false) throws -> URL {
        guard IdentityFile.writerWorkFactors.contains(workFactor) else {
            throw VaultError.workFactorOutOfRange(workFactor)
        }
        let text = IdentityFile.render(identity, created: created)
        let encrypted = try AgeFile.encrypt(Data(text.utf8),
                                            to: [ScryptRecipient(passphrase: passphrase, workFactor: workFactor)])
        try FileIO.createDirectory(keysURL)
        let file = keysURL.appendingPathComponent(IdentityFile.fileName(for: identity.recipient))
        try FileIO.writeAtomically(encrypted, to: file, replacing: replace)
        return file
    }

    /// Reads `keys/<recipient>.key.age` with `passphrase`.
    ///
    /// - Parameter maxWorkFactor: the reader's scrypt cap, default 20, at
    ///   most 22 (larger values are clamped).
    /// - Throws: `identityFileMissing`, `wrongPassphrase`, `workFactorTooHigh`,
    ///   `identityFileMalformed`, `identityMismatch`.
    public func readIdentityFile(recipient: X25519Recipient, passphrase: String,
                                 maxWorkFactor: Int = IdentityFile.defaultMaxWorkFactor) throws -> X25519Identity {
        let file = keysURL.appendingPathComponent(IdentityFile.fileName(for: recipient))
        guard FileIO.exists(file) else { throw VaultError.identityFileMissing(file.lastPathComponent) }
        let cap = min(max(maxWorkFactor, 1), IdentityFile.maxAllowedWorkFactor)
        let identity = ScryptIdentity(passphrase: passphrase, maxWorkFactor: cap, maxMemoryBytes: 1 << (cap + 10))
        let plain: Data
        do { plain = try AgeFile.decrypt(try FileIO.read(file), with: [identity]) } catch let e as AgeError {
            switch e {
            case .scryptWorkFactor: throw VaultError.workFactorTooHigh
            case .noMatchingIdentity: throw VaultError.wrongPassphrase
            default: throw VaultError.identityFileMalformed
            }
        }
        let id = try IdentityFile.parse(String(decoding: plain, as: UTF8.self))
        guard id.recipient == recipient else { throw VaultError.identityMismatch(recipient.string) }
        return id
    }

    /// The raw bytes of `keys/<recipient>.key.age` (still passphrase-wrapped),
    /// for printing or copying the file as it is.
    ///
    /// - Throws: `identityFileMissing`, `VaultError.io`.
    public func identityFileData(recipient: X25519Recipient) throws -> Data {
        let file = keysURL.appendingPathComponent(IdentityFile.fileName(for: recipient))
        guard FileIO.exists(file) else { throw VaultError.identityFileMissing(file.lastPathComponent) }
        return try FileIO.read(file)
    }

    /// Recipients that have a passphrase-wrapped identity file in `keys/`.
    ///
    /// - Throws: `VaultError.io` if `keys/` exists but cannot be listed.
    public func identityFiles() throws -> [X25519Recipient] {
        try FileIO.entries(keysURL).compactMap { n in
            FileIO.isDirectory(keysURL.appendingPathComponent(n)) ? nil : IdentityFile.recipient(fromFileName: n)
        }
    }
}
