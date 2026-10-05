---
title: InkVault Privacy Policy
permalink: /privacy/
---

# InkVault Privacy Policy

*Effective: TODO(user): date. Last updated: TODO(user): date.*

**Short version: InkVault does not collect, transmit or share any data about you. It has no
servers, no accounts, no analytics and no advertising.**

## What InkVault is

InkVault is a handwriting notes app. Your notes are stored in a "vault", a folder of files that
are encrypted on your device with an encryption key that you create and control. The developer
(Anthony Wertz, "we") cannot read your notes and does not receive them.

## Data we collect

None. InkVault does not collect personal data, usage data, diagnostics, identifiers, location,
contacts or content. It contains no analytics or advertising software and no third-party SDKs
that collect data. We run no server that the app talks to.

## Where your notes live

Your notes are saved only where you choose:

- on your device (the app's storage);
- in a folder you pick in the Files app, such as iCloud Drive or a network share;
- on a WebDAV server you configure yourself (a feature of the command-line tool and, when
  offered, the app).

Those storage services are operated by you or by their providers (for example Apple for iCloud
Drive) under their own terms and privacy policies; we have no access to them. Because notes are
encrypted before they are saved, a storage provider sees file names, sizes and modification
times, but not what you wrote or drew.

## Your keys

Your encryption key (an "age" identity) is generated and kept on your device, optionally in the
iOS/macOS Keychain, and you can export and back it up yourself. **We cannot recover your key or
your notes. If you lose every copy of your key, your notes cannot be decrypted by anyone.**

## Device permissions

InkVault asks only for access to the folders you pick with the system file picker, and uses the
Keychain and (optionally) Face ID or Touch ID to unlock your key. Face ID data never leaves the
system. TODO(user): update this list if the camera (QR key import) or any other permission is added.

## Children

InkVault collects no data from anyone, including children.

## Open source

The source code is public under the GPL-3.0-or-later at <https://github.com/anthonytw/inkvault>,
so these statements can be checked.

## Changes

If this policy ever changes it will be updated here with a new date, and a change that
collects data would be described in the app's release notes first.

## Contact

TODO(user): contact e-mail or the GitHub issues URL (<https://github.com/anthonytw/inkvault/issues>).
Security reports: see `SECURITY.md`.

---

**Hosting with GitHub Pages (TODO(user)).** Settings → Pages → deploy from a branch → `main`,
folder `/docs`. With the default Jekyll theme this page is served at
`https://anthonytw.github.io/inkvault/appstore/privacy-policy` (the `permalink` front matter
above is `/privacy/`, so it should appear at `https://anthonytw.github.io/inkvault/privacy/`;
check which one is live and use it as the Privacy Policy URL in App Store Connect). Delete this
section from the hosted copy, or move it to the README, before publishing. Note that Pages from
`/docs` would also publish the rest of `docs/` as web pages; if that is unwanted, use a
dedicated `gh-pages` branch or a separate repository containing only this file.
