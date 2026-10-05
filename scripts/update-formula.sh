#!/usr/bin/env bash
# Fill packaging/homebrew/inkvault.rb from a published release's SHA256SUMS.
#   scripts/update-formula.sh 0.5.0 > /path/to/homebrew-tap/Formula/inkvault.rb
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?usage: update-formula.sh VERSION}"; version="${version#v}"
sums="$(curl -fsSL "https://github.com/anthonytw/inkvault/releases/download/v${version}/SHA256SUMS")"
sum() { printf '%s\n' "$sums" | awk -v f="inkvault-${version}-$1.tar.gz" '$2 == f { print $1 }' | grep .; }
sed -e "s/@VERSION@/${version}/" \
    -e "s/@SHA256_MACOS_UNIVERSAL@/$(sum macos-universal)/" \
    -e "s/@SHA256_LINUX_X86_64@/$(sum linux-x86_64)/" \
    -e "s/@SHA256_LINUX_AARCH64@/$(sum linux-aarch64)/" \
    packaging/homebrew/inkvault.rb
