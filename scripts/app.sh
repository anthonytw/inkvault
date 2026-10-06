#!/usr/bin/env bash
# Build and test the iPad/Mac app (Apps/Sempere). Needs Xcode; macOS only.
#
#   scripts/app.sh test       # xcodebuild test on an iPad simulator
#   scripts/app.sh catalyst   # Mac Catalyst build, unsigned
#   scripts/app.sh simulator  # print the simulator id `test` would use
#
# SEMPERE_SIM_ID overrides the simulator choice.
set -euo pipefail
cd "$(dirname "$0")/.."
project=Apps/Sempere/Sempere.xcodeproj
scheme=SempereApp
derived=${SEMPERE_DERIVED_DATA:-.build/xcode}

# The newest available iPad simulator on the newest iOS runtime.
pick_simulator() {
  if [[ -n "${SEMPERE_SIM_ID:-}" ]]; then echo "$SEMPERE_SIM_ID"; return; fi
  xcrun simctl list devices available --json | /usr/bin/python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
best = None
for runtime, devs in devices.items():
    m = re.search(r"SimRuntime\.iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    if version < (26, 0):  # the app targets iPadOS 26
        continue
    for d in devs:
        if d.get("isAvailable") and d["name"].startswith("iPad"):
            key = (version, d["name"])
            if best is None or key > best[0]:
                best = (key, d["udid"], d["name"], version)
if best is None:
    sys.exit("no available iPad simulator on iOS 26 or newer (xcrun simctl list runtimes; xcodebuild -downloadPlatform iOS)")
print(f"using {best[2]} (iOS {best[3][0]}.{best[3][1]})", file=sys.stderr)
print(best[1])
'
}

case "${1:-}" in
  simulator)
    pick_simulator
    ;;
  test)
    sim=$(pick_simulator)
    xcodebuild test -project "$project" -scheme "$scheme" -derivedDataPath "$derived" \
      -destination "platform=iOS Simulator,id=$sim" CODE_SIGNING_ALLOWED=NO
    ;;
  catalyst)
    xcodebuild build -project "$project" -scheme "$scheme" -derivedDataPath "$derived" \
      -destination 'platform=macOS,variant=Mac Catalyst' \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=-
    ;;
  *)
    echo "usage: $0 test|catalyst|simulator" >&2
    exit 2
    ;;
esac
