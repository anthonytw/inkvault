/// Vault layout, keys, body framing, revisions, merge, snapshots, compaction.
/// Normative spec: docs/format.md.
public enum SempereFormat {
    public static let identifier = "sempere/1"
    public static let bodyMagic: [UInt8] = Array("SMPR".utf8)
    public static let bodyVersion: UInt8 = 1
}
