#!/usr/bin/env bash
# Runs the WebDAV integration tests against a local wsgidav server.
#   pip install wsgidav cheroot      (once)
#   scripts/test-webdav.sh
# CI runs this (Linux job); plain `swift test` skips the tests, which need SEMPERE_WEBDAV_TEST_URL.
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${PORT:-8765}"
work="$(mktemp -d)"
trap 'kill "${server_pid:-0}" 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir -p "$work/root"
cat > "$work/wsgidav.yaml" <<YAML
host: 127.0.0.1
port: $PORT
provider_mapping:
  "/": "$work/root"
http_authenticator:
  domain_controller: null
  accept_basic: true
  accept_digest: false
  default_to_digest: false
simple_dc:
  user_mapping:
    "*":
      sempere:
        password: "test-password"
verbose: 1
YAML
wsgidav --config "$work/wsgidav.yaml" >"$work/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.2
done
export SEMPERE_WEBDAV_TEST_URL="http://127.0.0.1:$PORT/"
export SEMPERE_WEBDAV_TEST_USER=sempere
export SEMPERE_WEBDAV_TEST_PASSWORD=test-password
swift test --filter 'WebDAVIntegrationTests|BlobIntegrationTests|CLIWebDAVTests' "$@"
