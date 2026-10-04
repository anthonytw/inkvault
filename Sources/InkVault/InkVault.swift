/// Vault layout, keys, body framing, revisions, merge, snapshots, compaction.
/// Normative spec: docs/format.md.
public enum InkVaultFormat {
    public static let identifier = "inkvault/1"
    public static let bodyMagic: [UInt8] = Array("INKV".utf8)
    public static let bodyVersion: UInt8 = 1
}
