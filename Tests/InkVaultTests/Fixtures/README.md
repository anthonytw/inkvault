# InkVault test fixture vault

**TEST-ONLY. `sample.key` is a throwaway identity committed on purpose so that
tests (and the CLI task) can open `sample.inkvault`. Never encrypt anything real
to its recipient.**

| File | What it is |
| --- | --- |
| `sample.key` | Plain-text post-quantum age identity (`age-keygen -pq` style), test-only |
| `sample.inkvault/` | A small vault in the format of `docs/format.md` |
| `sample.inkvault/keys/age1pq-<sha256>.key.age` | The same identity, passphrase-wrapped: passphrase `inkvault-test`, scrypt work factor 15 |
| `legacy.key`, `legacy.inkvault/` | The same notes in a **legacy** X25519 vault (classic key, `keys/<recipient>.key.age`, same passphrase): migrate-only (format.md §3.3.2), the input of the migration tests |

`*.key` is git-ignored repository-wide; `sample.key` and `legacy.key` were
added with `git add -f`.

## Contents

Vault id `5a3b1e00-1000-4000-8000-000000000001`, created
2026-10-04T16:20:00Z, one recipient. Devices `a1b2c3d4` (A) and `99ee00ff` (B).

| Note | Revisions | Reconstructs to |
| --- | --- | --- |
| `11111111-1111-4111-8111-111111111111` | A1, B1, B2 deltas; A2 snapshot; A3 delta after it | title "Fixture lecture", tags `["fixture"]`, ruled paper, 2 pages with 2 strokes each |
| `22222222-2222-4222-8222-222222222222` | A1 delta, B1 `deleteNote` | title "Fixture deleted", `deleted: true`, 1 page with 1 stroke |

Stroke ids are `f1c70000-0000-4000-8000-0000000001NN`; page ids end in `…001`,
`…002` (lecture) and `…003` (deleted note). All clocks are fixed offsets from
2026-10-04T16:20:00Z.

Recovery without the app:

```bash
age -d -i sample.key sample.inkvault/notes/<noteId>/<file>.age | tail -c +38 | gunzip | jq .   # age >= 1.3
age -d -i legacy.key legacy.inkvault/notes/<noteId>/<file>.age | tail -c +38 | gunzip | jq .
age -d sample.inkvault/keys/*.key.age     # passphrase: inkvault-test
```

## Regenerating

The content is defined in `SampleFixture` in `../FixtureTests.swift`.

```bash
INKVAULT_REGENERATE_FIXTURE=1 swift test --filter FixtureTests/testRegenerateFixture
```

This reuses `sample.key` and `legacy.key` (delete one first to mint a new
identity) and rewrites `sample.inkvault/` and `legacy.inkvault/`. age encryption is randomized, so the ciphertext bytes and
the vault secret change on every regeneration; names, ids, clocks and the
decrypted JSON do not. `testFixtureOpensAndReconstructs` checks that a fresh
generation decrypts to the same revisions as the committed one.
