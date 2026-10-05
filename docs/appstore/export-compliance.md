# Export compliance (encryption)

> **TODO(user): you must confirm this yourself.** This is a summary of how the rules read, not
> legal or compliance advice. US export rules (EAR) and the French/other import declarations are
> your responsibility as the developer; check with Apple's documentation ("Complying with
> Encryption Export Regulations") and, if in doubt, a lawyer or the BIS.

## What the app does cryptographically

InkVault encrypts the user's own notes with the **age v1** format, implemented in
`Sources/Age` on top of **swift-crypto** (an open-source library, a CryptoKit-compatible API;
on Apple platforms it wraps the system's CryptoKit/BoringSSL):

| Purpose | Algorithm |
| --- | --- |
| Key agreement (recipient keys) | X25519 |
| Key derivation | HKDF-SHA-256 |
| Payload and file-key encryption | ChaCha20-Poly1305 (chunked "STREAM") |
| Header integrity | HMAC-SHA-256 |
| Passphrase-protected key files and passphrase recipients | scrypt (local implementation, RFC 7914 test vectors) |
| Per-vault integrity tag | HMAC-SHA-256 |

All are standard, published algorithms, with no proprietary or non-standard cryptography. The
encryption is used to protect the user's own data on storage the user chooses. The app does
not use encryption for anything else (no network protocol of its own; WebDAV uses the
system's HTTPS, URLSession/TLS).

## Where this lands

Apple's rule: an app that uses encryption beyond Apple's operating system must answer the
export compliance question at upload, even if it uses only standard algorithms. The usual
reading for this profile (TODO(user): confirm):

1. Encryption is **not** limited to the OS's own encryption: the app contains its own use of
   encryption (age) for data confidentiality, so `ITSAppUsesNonExemptEncryption = NO` is
   *not* automatically right. "Exempt" in Apple's sense means encryption that is only
   (a) in Apple's OS APIs for authentication/HTTPS, or (b) limited in other listed ways.
2. For apps with standard encryption beyond that, the relevant US category is **Mass-market
   encryption software, ECCN 5D992.c**, eligible for **License Exception ENC §740.17(b)(1)
   ("self-classification")** or, where applicable, treated as not needing an annual
   self-classification report if it is publicly available open source under **§742.15(b)**:
   publicly available source code (this repository, GPL) of encryption is not subject to the EAR
   once notified to BIS and NSA (an e-mail with the repository URL to `crypt@bis.doc.gov` and
   `enc@nsa.gov`). TODO(user): decide whether to send that notification (a one-time e-mail
   for open-source encryption source) and keep a copy.
3. France requires a declaration for some encryption apps unless a standard exemption applies;
   Apple asks for an annual self-classification report/documentation only when distributing
   in France with non-exempt encryption. TODO(user): check whether you want France included, or
   exclude it from availability (App Store Connect → Pricing and Availability).

## What to do in the project and in App Store Connect

- **Info.plist.** Setting `ITSAppUsesNonExemptEncryption` avoids the prompt on each upload.
  - If you conclude the app qualifies for an exemption (for example 5D992.c mass market with
    the open-source/ENC treatment and no annual report requirement for you):
    set it to **`NO`** only if your analysis says the encryption is exempt from Apple's
    documentation requirement. Wrongly answering `NO` is a compliance problem.
  - Otherwise set **`YES`** and answer App Store Connect's follow-up questions (uses encryption;
    exempt under (a)..(d) or not; standard algorithms only; available in France or not),
    and upload any self-classification documentation Apple requests; with Apple's
    "ITSEncryptionExportComplianceCode" if you receive a code.
  - The project has the key in neither state today (`Apps/InkVault` build settings). If you
    decide, add `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = YES|NO;` to both app build
    configurations in `project.pbxproj` (or to `InkVaultInfo.plist`).
- **Recommendation (to confirm):** answer **YES, uses encryption, standard algorithms only,
  no proprietary encryption**; qualify under the open-source/mass-market treatment; send the
  one-time BIS/NSA notification for the public source; do not answer `NO` just to skip the
  prompt. This is the conservative choice and costs a few clicks per submission (or one
  `YES` key in Info.plist plus Apple's documentation upload).
- The CLI release binaries (GitHub Releases) contain the same cryptography; the same open-source
  treatment applies. Say so in the notification e-mail.

## Facts to give if asked

- No encryption algorithms other than those in the table; no key lengths adjustable by the user.
- Keys are generated and held by the user; the developer holds no keys and no escrow.
- Encryption is for the user's own data at rest; the app does not provide a network
  encryption service or a platform for others.
