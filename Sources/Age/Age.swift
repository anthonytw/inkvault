/// Spec-exact implementation of the age v1 file format (age-encryption.org/v1).
///
/// Scope (task 0.1 in docs/plan.md): X25519 and scrypt recipients, header
/// parsing and formatting, header HMAC, STREAM payload, ASCII armor, Bech32
/// identity and recipient encoding. Validated against the C2SP CCTV vectors
/// under Tests/AgeTests/Vectors.
public enum AgeVersion {
    public static let header = "age-encryption.org/v1"
}
