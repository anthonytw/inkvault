# App Store preparation

Drafts for the iPad/Mac (Catalyst) release. Everything marked **TODO(user)** needs your
decision or confirmation; nothing here has been submitted. Not legal advice.

| File | What |
| --- | --- |
| [privacy-policy.md](privacy-policy.md) | Privacy policy, written to be served by GitHub Pages |
| [app-privacy.md](app-privacy.md) | App Privacy ("nutrition label") answers and the privacy manifest |
| [export-compliance.md](export-compliance.md) | Encryption export compliance notes |
| [listing.md](listing.md) | Name ideas, subtitle, description, keywords, what's new, review notes |
| [screenshots.md](screenshots.md) | Screenshot shot-list and sizes |

## Checklist before the first TestFlight/App Store build

- [ ] TODO(user): contributor policy decided (`CONTRIBUTING.md`, `docs/legal/app-store-exception.md`)
- [ ] TODO(user): name available in App Store Connect (`listing.md`); bundle id is
      `io.github.anthonytw.inkvault` in the project today, and cannot change after the first upload
- [ ] TODO(user): signing team set in Xcode; the iCloud entitlement is *not* needed (vaults
      live in folders picked through Files)
- [ ] TODO(user): `ITSAppUsesNonExemptEncryption` decision (`export-compliance.md`)
- [ ] TODO(user): add `PrivacyInfo.xcprivacy` (`app-privacy.md`; not added by this PR because it
      is an app-target resource and needs a build to validate on a Mac)
- [ ] TODO(user): host the privacy policy and enter its URL
- [ ] TODO(user): the app is a work in progress (key management UI, export and recognition are
      open in `docs/plan.md`); App Review needs a build that works without developer tooling
- [ ] TODO(user): age rating questionnaire (expected 4+, no objectionable content, no web access, no UGC sharing)
