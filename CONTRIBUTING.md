# Contributing to InkVault

Thanks for helping. Read `DESIGN.md` (why), `docs/format.md` (the on-disk format, normative)
and `CLAUDE.md` (the rules for working in this repository, including the hard ones: Linux-buildable
`Sources/`, no hand-rolled crypto, notes are write-once) before touching `Sources/`.
Everyone is expected to follow the [code of conduct](CODE_OF_CONDUCT.md).
Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Build and test

Swift 6.0 or newer (CI uses 6.4); `Sources/` must build on Linux and macOS.

```bash
swift build --build-tests
swift test                  # or: swift test --filter AgeTests
scripts/check-portability.sh
scripts/test-linux.sh       # on a Mac with Docker: tests in swift:6.4-noble
```

On Linux install `zlib1g-dev` (and the `age` CLI for the interop tests). The iPad/Mac app needs
Xcode 26 or newer: `scripts/app.sh test` and `scripts/app.sh catalyst`. In `swift test` output,
the XCTest `Executed N tests` line is the one that matters.

## Pull requests

1. Open an issue first for anything bigger than a small fix, so the design can be agreed.
2. One task per branch, one PR to `main`. Branch names like `feat/…`, `fix/…`, `docs/…`.
3. Commit messages: `area: imperative summary` (for example `render: clamp page height`).
4. Add tests with the change; format changes go through `docs/format.md` first.
5. Update `CHANGELOG.md` under `[Unreleased]` for anything a user would notice.
6. CI must be green (Linux, macOS, app). Maintainers squash-merge.
7. Fill in the PR template, including the contributor agreement checkbox.

Style: Swift 6 strict concurrency, `Sendable` value types for the model, typed error enums per
module, no force-unwraps outside tests, `///` on public API, XCTest for tests.

## Licence and contributor agreement

InkVault is licensed **GPL-3.0-or-later** (`LICENSE`). The maintainer, Anthony Wertz, holds the
copyright and intends to distribute the iPad and Mac app through Apple's App Store. Apple's
terms of service impose restrictions that the GPL does not allow on a third party's
redistribution, so the project can only ship there if the copyright holder also licenses its own
code outside the GPL, or the licence carries a matching exception. Contributions must therefore
come with the right to do that.

Policy: **a contributor licence agreement (CLA)**, [CLA.md](CLA.md). By ticking the box in the PR
template (or stating "I agree to the InkVault CLA" in the PR) you confirm:

- you wrote the contribution, or have the right to submit it, and your employer does not claim it;
- you keep your copyright, and the contribution stays available to everyone under the GPL;
- you grant the maintainer a perpetual, worldwide, irrevocable licence to use, modify and
  distribute it under any terms, including the GPL, app-store terms and a future licence, so the
  app can ship on the App Store.

If you cannot agree to that, the project cannot take your code, but issues, bug reports and
ideas are always welcome. Why a CLA rather than an exception, and the alternative text:
[docs/legal/app-store-exception.md](docs/legal/app-store-exception.md).

TODO(user): decide the policy (CLA recommended). Until you do, treat CLA.md and the PR template
checkbox as drafts, and consider accepting no outside code. This is not legal advice; have a
lawyer review it before the App Store release.
