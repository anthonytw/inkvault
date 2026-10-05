# Security policy

InkVault is encryption software; please report vulnerabilities privately.

## Reporting

Use GitHub's private vulnerability reporting: open
<https://github.com/anthonytw/inkvault/security/advisories/new> (Security tab →
"Report a vulnerability"). Do not open a public issue or pull request for a security problem.
Include the affected component (`Sources/Age`, vault format, CLI, app), the version or
commit, and steps or a test vault that reproduce it. Never include real keys or notes.

TODO(user): enable *Private vulnerability reporting* in the repository settings
(Settings → Code security) so the link above works, and optionally add a contact e-mail.

You should get an acknowledgement within a week. This is a volunteer-run project: fixes are
prioritised by impact and coordinated with you, and you will be credited in the advisory if
you wish.

## Scope

In scope: breaking confidentiality or integrity of notes (age implementation, vault tag,
key handling, passphrase-wrapped keys), recovering plaintext or keys from vault files,
planting notes that decrypt without a key holder's cooperation, parser crashes or resource
exhaustion on hostile vault, `.note` or PDF input, and the release pipeline's integrity.

Out of scope: threats that need the unlocked device or the user's identity file, the
metadata a storage provider can see by design (file names, sizes and times; see `DESIGN.md`),
and age's own non-goals (no signatures). 

## Supported versions

Only the latest release and `main`. The on-disk format is versioned (`docs/format.md`);
fixes never silently change it.

## Verifying releases

Release tarballs carry GitHub build provenance attestations:
`gh attestation verify FILE --repo anthonytw/inkvault`, plus `SHA256SUMS`.
