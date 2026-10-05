# Export compliance (encryption)

> Decided by the maintainer: Sempere is **mass-market software using standard, published
> encryption algorithms at full strength**. This page records that decision and what follows
> from it. It is a summary, not legal or compliance advice: US export rules (EAR) and import
> rules elsewhere (France, for example) remain the developer's responsibility; see Apple's
> "Complying with Encryption Export Regulations" and ask a lawyer or BIS if in doubt.

## What the app does cryptographically

The app encrypts the user's own notes with the **age** format (`Sources/Age`, on top of
**swift-crypto**, whose Apple-platform implementation is CryptoKit):

| Purpose | Algorithm |
| --- | --- |
| Recipient keys (vault encryption), post-quantum hybrid | ML-KEM-768 + X25519 (X-Wing; age `MLKEM768-X25519`, FIPS 203 + RFC 7748), HPKE (RFC 9180) |
| Key derivation | HKDF-SHA-256 |
| Payload and file-key encryption | ChaCha20-Poly1305 (chunked "STREAM") |
| Header integrity | HMAC-SHA-256 |
| Passphrase-protected key files | scrypt (RFC 7914; local implementation, tested with the RFC vectors) |
| Per-vault integrity tag | HMAC-SHA-256 |

(Vaults accept only the hybrid recipient, see `docs/HANDOFF.md`; plain X25519 remains readable
in legacy vaults.) Every algorithm is a published standard or IETF draft with independent
implementations, at full strength: no reduced key lengths, no proprietary or non-standard
cryptography, no key escrow, no user-configurable key lengths. Encryption protects the user's
own data at rest on storage the user chooses; the app provides no network encryption service
and no platform for others (WebDAV and any HTTPS use the system's URLSession/TLS).

## Classification

- The app is **mass-market encryption software**: sold or given away to the general public
  through the App Store, with a cryptographic functionality that the user cannot easily change
  and no custom cryptographic work for any customer. US category **ECCN 5D992.c**, authorised
  by **License Exception ENC § 740.17(b)(1)** (self-classification, no prior review), for
  standard encryption.
- The source and the CLI binaries are published as open source on GitHub. Publicly available
  encryption source code that uses only *standard* cryptography is, under EAR § 742.15(b)
  (as amended in 2021), not subject to the EAR and needs no BIS/NSA notification; the
  non-standard-cryptography case does not apply because nothing here is non-standard.
  TODO(user): confirm that reading (it is what the rule text says to the author of this page,
  not advice); if you prefer a belt-and-braces record, a one-time e-mail with the repository URL
  to `crypt@bis.doc.gov` and `enc@nsa.gov` does no harm.

## What to do in the project and in App Store Connect

- **Info.plist:** set `ITSAppUsesNonExemptEncryption` to **`YES`**. The app uses encryption
  beyond what the operating system itself provides, so `NO` would be the wrong answer; answer
  the follow-up questions in App Store Connect as: uses encryption; **standard encryption
  algorithms instead of, or in addition to, using or accessing the encryption within Apple's
  operating system**; qualifies for the mass-market treatment above; no proprietary
  algorithms. Add `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = YES;` to both app build
  configurations in `project.pbxproj` (or the key to `InkVaultInfo.plist`) when the first
  TestFlight build is prepared; the project has the key in neither place today.
- Apple may ask for self-classification documentation and return an
  `ITSEncryptionExportComplianceCode`; add that key too when you receive one.
- **US annual self-classification report:** a mass-market (5D992.c) product under ENC
  § 740.17(b)(1) needs no annual self-classification report: the March 2021 amendment dropped
  that report for mass-market items other than components, chipsets and toolkits (it still
  applies to non-mass-market (b)(1) items). Keep the classification record (this page, the
  algorithm table) with your files.
- **France** requires a declaration for some encryption products unless an exemption applies;
  Apple needs documentation only if the app is distributed there with non-exempt encryption.
  TODO(user): either confirm the exemption covers this app or leave France out of availability
  (App Store Connect → Pricing and Availability).
- The CLI release binaries (GitHub Releases) contain the same cryptography; the same
  open-source and mass-market reasoning applies.

## Facts to give if asked

- No algorithms other than those in the table; none proprietary or non-standard; all at full
  standard strength.
- Keys are generated and held by the user; the developer holds no keys and runs no escrow.
- Encryption is for the user's own data at rest; the app is not a communications or
  infrastructure product.
