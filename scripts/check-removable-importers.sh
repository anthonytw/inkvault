#!/usr/bin/env bash
# Proves that the Notability importer can be removed by deleting its directory (docs/import-notability.md
# "Structure"): copies the package without Sources/SempereNotability and Tests/SempereNotabilityTests, builds the
# CLI and every test target, runs the tests that remain, and checks that `sempere import` lists what is left.
# Run by the Linux CI job; takes a full build (the copy has no build cache).
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
scripts/check-importer-isolation.sh

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tar -C "$repo" --exclude=./.build --exclude=./.git --exclude=./Apps --exclude='*/node_modules' -cf - . | tar -C "$work" -xf -
cd "$work"
rm -rf Sources/SempereNotability Tests/SempereNotabilityTests
test ! -e Sources/SempereNotability

swift build --build-tests
swift test --skip-build --parallel

bin=".build/debug/sempere"
help="$("$bin" import --help)"
if printf '%s' "$help" | grep -qi notability; then
  echo "error: 'sempere import --help' still lists Notability without its module" >&2; exit 1
fi
printf '%s' "$help" | grep -q 'pdf' || { echo "error: 'sempere import --help' lost 'import pdf'" >&2; exit 1; }
if "$bin" import notability /nonexistent.note >/dev/null 2>&1; then
  echo "error: 'sempere import notability' exists without its module" >&2; exit 1
fi
echo "removable importers: ok (built and tested without Sources/SempereNotability)"
