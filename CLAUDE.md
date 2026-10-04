# InkVault — agent guide

Open-source, end-to-end-encrypted handwriting notes for iPad and Mac.
Read `DESIGN.md` (why) and `docs/format.md` (normative on-disk format)
before touching `Sources/`. `docs/plan.md` is the task board.

## Build and test

```bash
swift build                 # macOS or Linux
swift test                  # all targets
swift test --filter AgeTests
scripts/test-linux.sh       # on a Mac with Docker, or in a cloud VM: run tests in swift:6.4-noble
```

Toolchain floor is Swift 6.0 (`swift-tools-version: 6.0`, language mode 6).
Do not use features newer than Swift 6.0 in `Sources/`.

## Hard rules

- `Sources/*` and `Tests/*` must build on Linux: Foundation, swift-crypto
  (`import Crypto`), `CZlib` and swift-argument-parser only. No UIKit,
  AppKit, PencilKit, CoreGraphics, Compression, CommonCrypto, Security.
  Apple-only code goes under `Apps/`. Apple-only *tests* (e.g. comparing
  against PencilKit) are allowed behind `#if canImport(PencilKit)`.
- Files under a vault's `notes/` are write-once. Never add code that
  modifies them in place except the recipient-change rewrap in `format.md` §3.3.
- Crypto: use swift-crypto primitives; never hand-roll a cipher or MAC.
  scrypt and PBKDF2 are the only primitives implemented locally
  (swift-crypto lacks them); they must have RFC test vectors.
- No network code in `Sources/` (phase 3 WebDAV will be its own target).
- Keep the stock-CLI recovery path working:
  `age -d -i key FILE.age | tail -c +38 | gunzip | jq .`

## Style

Swift 6 strict concurrency. `Sendable` value types for the model. No
force-unwraps outside tests. Errors are typed enums per module. Tests use
XCTest (Linux-compatible). Keep public API documented with `///`.

## Workflow

Branch per task, PR to `main`, squash merge, CI green. Commit messages:
`area: imperative summary`. Co-author line as the harness instructs.

## Gotchas

- macOS file systems are case-insensitive: never create two paths that differ
  only by case (`Sources/inkvault` vs `Sources/InkVault` collide). The CLI
  target is `InkVaultCLI` for exactly this reason; its product is `inkvault`.
- `swift test` prints Swift Testing's "0 tests" summary after XCTest's; the
  XCTest `Executed N tests` line is the one that matters.
- CLI tests run the built binary as a subprocess (see `Tests/CLITests`);
  do not add the executable target as a test dependency.
- On Linux, `XMLParser` (and `XMLDocument`) live in `FoundationXML`, and
  `URLSession` in `FoundationNetworking`. Guard the import with
  `#if canImport(FoundationXML)`; macOS has them in Foundation.
