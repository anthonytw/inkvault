# App Store material

The submission guide is [`docs/release/app-store.md`](../release/app-store.md), with the
encryption answers in [`docs/release/export-compliance.md`](../release/export-compliance.md).
This folder keeps the pieces other files point to:

| File | What |
| --- | --- |
| [privacy-policy.md](privacy-policy.md) | The privacy policy at the URL App Store Connect has today. The GitHub Pages copy is [`docs/privacy/index.html`](../privacy/index.html): keep both identical, with the same date. |
| [screenshots.md](screenshots.md) | Generated screenshots (`scripts/screenshots.sh`): sizes, shot list, demo vault |
| [france-declaration.md](france-declaration.md) | The ANSSI declaration, needed before France is added to availability |

Before each submission, run `scripts/release-check.sh` (CI runs it too) and work through the
checklist in `docs/release/app-store.md` §9.
