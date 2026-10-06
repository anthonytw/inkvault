import Foundation

/// `vault.json`, the plaintext manifest (format.md §2).
public struct VaultManifest: Hashable, Sendable, Codable {
    /// One entry of `recipients`.
    public struct Recipient: Hashable, Sendable, Codable {
        /// Bech32 `age1...` X25519 recipient.
        public var key: String
        /// Free-form, e.g. "Anthony's iPad".
        public var label: String
        /// When the recipient was added.
        public var added: Date

        /// - Parameters:
        ///   - key: Bech32 `age1...` recipient (not validated here; `Vault`
        ///     validates when reading or writing).
        ///   - label: free-form display name.
        ///   - added: when it was added.
        public init(key: String, label: String, added: Date) {
            self.key = key; self.label = label; self.added = added
        }
    }

    /// `sempere/1`.
    public var format: String
    /// Random per vault; lowercase on the wire.
    public var vaultId: UUID
    /// When the vault was created.
    public var created: Date
    /// At least one.
    public var recipients: [Recipient]
    /// The 32-byte vault secret, age-encrypted (armored) to exactly `recipients`.
    public var vaultSecret: String

    /// Builds a manifest value. No validation happens here; `Vault.create`
    /// and `Vault.open` enforce format.md §2.
    ///
    /// - Parameters:
    ///   - format: `sempere/1` unless testing other versions.
    ///   - vaultSecret: the armored age file holding the 32-byte secret.
    public init(format: String = SempereFormat.identifier, vaultId: UUID, created: Date, recipients: [Recipient],
                vaultSecret: String) {
        self.format = format; self.vaultId = vaultId; self.created = created
        self.recipients = recipients; self.vaultSecret = vaultSecret
    }

    enum CodingKeys: String, CodingKey { case format, vaultId, created, recipients, vaultSecret }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        vaultId = try c.decode(LowercaseUUID.self, forKey: .vaultId).uuid
        created = try c.decode(Date.self, forKey: .created)
        recipients = try c.decode([Recipient].self, forKey: .recipients)
        vaultSecret = try c.decode(String.self, forKey: .vaultSecret)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(LowercaseUUID(vaultId), forKey: .vaultId)
        try c.encode(created, forKey: .created)
        try c.encode(recipients, forKey: .recipients)
        try c.encode(vaultSecret, forKey: .vaultSecret)
    }

    /// The manifest as written to disk: InkJSON conventions, pretty-printed
    /// because this is the one plaintext file people read, newline-terminated.
    public func encoded() throws -> Data {
        let e = InkJSON.encoder()
        e.outputFormatting.insert(.prettyPrinted)
        return try e.encode(self) + Data("\n".utf8)
    }

    /// Parses `vault.json` bytes.
    public static func decode(_ data: Data) throws -> VaultManifest {
        try InkJSON.decoder().decode(VaultManifest.self, from: data)
    }
}
