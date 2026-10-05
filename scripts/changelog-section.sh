#!/usr/bin/env bash
# Print the body of one CHANGELOG.md section, e.g. `scripts/changelog-section.sh 0.6.0`.
# Exits 1 if the section is missing or empty (the release workflow relies on that).
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?usage: changelog-section.sh VERSION}"
version="${version#v}"
body="$(awk -v v="$version" '
  /^## \[/ { if (on) exit; if (index($0, "## [" v "]") == 1) { on = 1; next } }
  on { print }
' CHANGELOG.md | sed -e '/./,$!d')"
if [ -z "$body" ]; then
  echo "error: no non-empty CHANGELOG.md section for $version" >&2
  exit 1
fi
printf '%s\n' "$body"
