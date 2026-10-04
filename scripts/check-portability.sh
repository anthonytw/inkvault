#!/usr/bin/env bash
# Fail if library/CLI sources import Apple-only frameworks (see CLAUDE.md).
set -euo pipefail
cd "$(dirname "$0")/.."
pattern='^[[:space:]]*import[[:space:]]+(UIKit|AppKit|PencilKit|CoreGraphics|Compression|CommonCrypto|Security|CryptoKit|SwiftUI|Combine)\b'
if grep -rEn "$pattern" Sources/; then
  echo "error: Apple-only import in Sources/ (use 'import Crypto' from swift-crypto, CZlib for gzip)" >&2
  exit 1
fi
echo "portability: ok"
