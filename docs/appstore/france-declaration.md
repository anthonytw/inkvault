# France: encryption declaration (ANSSI)

Sempere uses standard encryption algorithms that the OS does not provide
(age, scrypt, HPKE over swift-crypto). Supplying it in France therefore needs a
declaration to ANSSI, and Apple needs that declaration uploaded before the app
can be sold in France (`docs/release/export-compliance.md`).

**Plan:** ship everywhere except France. File this declaration in parallel,
and add France once it is approved.

## Steps

1. **App Store Connect, now:**
   - answer the encryption questions: uses encryption; standard algorithms
     instead of, or in addition to, Apple's;
   - leave France out of availability (Pricing and Availability).
2. **Fill in the form** "Déclaration et demande d'autorisation d'opérations
   relatives à un moyen de cryptologie", **Annex I** (a *moyen*, a product; not
   Annex II, which is for a *prestation*, a service). The form is fixed by the
   *arrêté* of 29 January 2015. Download the current form from ANSSI
   (cyber.gouv.fr, "Contrôle relatif à un moyen de cryptologie").
   - Tick **déclaration de fourniture** (supply in France).
   - Request **catégorie 3 ("grand public")** in section C, so the app can
     also be exported freely.
3. **Submit to ANSSI:** two signed copies to ANSSI, Bureau des contrôles
   réglementaires, 51 boulevard de La Tour-Maubourg, 75700 Paris 07 SP, or by
   the e-mail address printed on the current form. The legal deadline is one
   month from a complete file; expect up to about two months. Keep the receipt.
4. **Upload to Apple:**
   - Fill in the app description and availability first, since Apple asks for both.
   - Go to App Information → App Encryption Documentation → +, answer the
     questions with France selected, and upload the signed declaration (and
     ANSSI's receipt once you have it).
   - Apple quotes about 2 business days; some developers waited weeks.
5. **Then:**
   - Apple shows a key value next to the approved documentation. Put it in
     `Apps/Sempere/SempereInfo.plist` as `ITSEncryptionExportComplianceCode`,
     together with `ITSAppUsesNonExemptEncryption = YES`.
   - Add France to availability.

## Section A: déclarant (the maintainer fills this in)

Use **A.2 personne physique** (a natural person; no company, no SIRET).

| Field | Value |
| --- | --- |
| Nom, prénom | TODO(user) |
| Nationalité | TODO(user) |
| Adresse | TODO(user) |
| Téléphone | TODO(user) |
| Courriel | TODO(user) |

## Section B: le moyen de cryptologie

### B.1 Informations générales

| Champ | Valeur (FR) | English |
| --- | --- | --- |
| Désignation générique | Logiciel de prise de notes manuscrites chiffrées | Encrypted handwritten-notes software |
| Dénomination commerciale | Sempere | Sempere |
| Version | the version being declared, e.g. 1.0 (TODO(user) at filing) | |
| Référence commerciale | App Store, identifiant d'app 6819333304 ; bundle `io.github.anthonytw.sempere` | |
| Date de mise sur le marché | TODO(user): first App Store release date | |
| Fabricant / éditeur | the declarant (same as A.2); source code at github.com/anthonytw/sempere | |
| Marque de distribution | Sempere | |

### B.2 Description fonctionnelle

- **Type:** logiciel (software), for iPadOS and macOS (App Store), plus a command-line
  tool for macOS and Linux distributed as source and binaries on GitHub.
- **Description générale (FR):** Application de prise de notes manuscrites. Chaque
  note est enregistrée dans un dossier choisi par l'utilisateur (sur l'appareil, iCloud
  Drive ou WebDAV) sous forme de fichiers chiffrés au format ouvert « age ». Les clés
  sont générées et conservées uniquement par l'utilisateur ; l'éditeur ne détient aucune
  clé et n'exploite aucun serveur. Le logiciel est libre (GPL-3.0-or-later).
- **(EN)** Handwriting notes app. Each note is stored in a folder the user chooses (on
  the device, iCloud Drive or WebDAV) as files encrypted in the open "age" format. Keys
  are generated and held only by the user; the publisher holds no key and runs no
  server. Free software (GPL-3.0-or-later).
- **Fonction principale:** stockage sécurisé de données de l'utilisateur
  (secure storage of the user's own data). It is not a communications product,
  a VPN or a messaging service.

### B.3 Services cryptographiques

| Fonction | Utilisée | Détail |
| --- | --- | --- |
| Confidentialité | oui | chiffrement des notes et des pièces jointes au repos |
| Intégrité | oui | AEAD + HMAC par fichier |
| Authentification | non (sauf déverrouillage local par Face ID / mot de passe, fourni par le système) | |
| Signature | non | |

**Protocoles / formats:** age v1 (C2SP, `age-encryption.org/v1`), including the
post-quantum hybrid recipient type of age v1.3. The app has no network protocol of
its own: WebDAV and iCloud use the system's TLS.

**Algorithmes et longueurs de clé maximales:**

| Usage | Algorithme | Taille de clé |
| --- | --- | --- |
| Échange de clé (destinataires) | ML-KEM-768 + X25519 hybride (X-Wing ; FIPS 203, RFC 7748) via HPKE (RFC 9180) | ML-KEM-768 ; X25519 256 bits |
| Chiffrement des données | ChaCha20-Poly1305 (RFC 8439), mode STREAM par blocs de 64 Kio | 256 bits |
| Chiffrement de la clé de fichier | ChaCha20-Poly1305 | 256 bits |
| Dérivation de clé | HKDF-SHA-256 (RFC 5869) | 256 bits |
| Intégrité | HMAC-SHA-256 | 256 bits |
| Protection par phrase de passe | scrypt (RFC 7914), N = 2^15…2^18, r = 8, p = 1 | 256 bits dérivés |
| Lecture seule (anciens coffres, migration) | X25519 (RFC 7748) | 256 bits |

**Implémentation:** Apple CryptoKit (on Apple platforms) and swift-crypto
(BoringSSL) for the primitives; the age format and scrypt in the app's own open
source code (`Sources/Age`), tested against the official C2SP test vectors and
the reference `age` tool. No proprietary algorithm.

**Gestion des clés:** keys are generated on the user's device (or with the
`age-keygen` tool) and stay with the user: in the Keychain, a password manager, a
paper recovery kit, or a passphrase-protected file. No escrow and no key
recovery by the publisher.

## Section C: catégorie 3 ("grand public")

Requested. Point 3 of Annex II of décret 2007-663 sets three conditions.

1. **Démarche commerciale (the product is for the general public):** it is a
   free app on the App Store for any user, with no custom work for any customer.
2. **Fonctionnalité non modifiable par l'utilisateur:** the algorithms and key
   sizes are fixed in the code; nothing lets the user change them.
3. **Installation sans assistance du fournisseur:** the user installs it from the
   App Store with no help from the supplier.

## Section E: pièces jointes

- **Documentation technique:** `docs/format.md` (the encrypted format) and
  `docs/release/export-compliance.md`, printed or as PDF.
- **Brochure commerciale:** the App Store description (`docs/release/app-store.md` §8).
- **Manuel utilisateur:** README and `docs/cli.md`.
- Company documents and a business register extract do not apply (natural person).

## Section F: attestation

Signature and date by the declarant (TODO(user)).

## Annexe technique

ANSSI may ask for it. Everything is public: the source code, `docs/format.md`
and the test vectors.
