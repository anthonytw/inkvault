#!/usr/bin/env bash
# Build and test the iPad/Mac app (Apps/Sempere). Needs Xcode; macOS only.
#
#   scripts/app.sh test       # xcodebuild test on an iPad simulator
#   scripts/app.sh test-phone # the iPhone suites (PhoneLayoutTests) on an iPhone simulator
#   scripts/app.sh catalyst   # Mac Catalyst build, unsigned
#   scripts/app.sh test-mac   # the Mac suites (MAC_SUITES below) on Mac Catalyst, ad-hoc signed
#   scripts/app.sh test-mac-ui # the Mac UI tests (MacWindowUITests) on Mac Catalyst
#   scripts/app.sh simulator  # print the simulator id `test` would use
#
# SEMPERE_SIM_ID overrides the simulator choice. SEMPERE_MAC_TESTS=all runs every
# app suite on Mac Catalyst instead of the Mac ones.
set -euo pipefail
cd "$(dirname "$0")/.."
project=Apps/Sempere/Sempere.xcodeproj
scheme=SempereApp
derived=${SEMPERE_DERIVED_DATA:-.build/xcode}

# App suites that cover Mac behaviour (docs/mac.md), run on Mac Catalyst by `test-mac`.
MAC_SUITES=(MacCatalystPDFTests MacDragOutTests NoteWindowTests PDFImportTests BlobCacheTests ItemLayerTests
            MenuCommandTests MacInputTests DragAndDropTests NotebookChoicesTests)

# The newest available simulator whose name starts with $1 (iPad or iPhone, default iPad) on the
# newest iOS runtime. SEMPERE_SIM_ID overrides it.
pick_simulator() {
  local family=${1:-iPad}
  if [[ -n "${SEMPERE_SIM_ID:-}" ]]; then echo "$SEMPERE_SIM_ID"; return; fi
  xcrun simctl list devices available --json | /usr/bin/python3 -c '
import json, re, sys
family = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
best = None
for runtime, devs in devices.items():
    m = re.search(r"SimRuntime\.iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    if version < (26, 0):  # the app targets iPadOS 26 and iOS 26
        continue
    for d in devs:
        if d.get("isAvailable") and d["name"].startswith(family):
            key = (version, d["name"])
            if best is None or key > best[0]:
                best = (key, d["udid"], d["name"], version)
if best is None:
    sys.exit("no available " + family + " simulator on iOS 26 or newer (xcrun simctl list runtimes; xcodebuild -downloadPlatform iOS)")
print(f"using {best[2]} (iOS {best[3][0]}.{best[3][1]})", file=sys.stderr)
print(best[1])
' "$family"
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
  test-phone)
    # Same build products as `test` (the simulator SDK is shared), so after it this only runs the suites.
    sim=$(pick_simulator iPhone)
    xcodebuild test -project "$project" -scheme "$scheme" -derivedDataPath "$derived" \
      -destination "platform=iOS Simulator,id=$sim" CODE_SIGNING_ALLOWED=NO \
      -only-testing:SempereAppTests/CompactNavigationTests -only-testing:SempereAppTests/CompactBackTests \
      -only-testing:SempereAppTests/PhoneReadingTests \
      -only-testing:SempereAppTests/PhoneCanvasTests -only-testing:SempereAppTests/PhoneRootTests \
      -only-testing:SempereAppTests/ZoomStepsTests -only-testing:SempereAppTests/PhoneStackTests \
      -only-testing:SempereAppTests/PhoneInsertTests -only-testing:SempereAppTests/InsertOptionsTests
    ;;
  catalyst)
    xcodebuild build -project "$project" -scheme "$scheme" -derivedDataPath "$derived" \
      -destination 'platform=macOS,variant=Mac Catalyst' \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=-
    ;;
  test-mac)
    # Ad-hoc signed: a sandboxed Catalyst test host has to be signed to launch.
    only=()
    if [[ "${SEMPERE_MAC_TESTS:-}" != all ]]; then
      for suite in "${MAC_SUITES[@]}"; do only+=("-only-testing:SempereAppTests/$suite"); done
    else
      only=(-only-testing:SempereAppTests)
    fi
    xcodebuild test -project "$project" -scheme "$scheme" -derivedDataPath "$derived" \
      -destination 'platform=macOS,variant=Mac Catalyst' "${only[@]}" \
      CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
    ;;
  test-mac-ui)
    # The UI tests live in the SempereScreenshots scheme (never built by `test`).
    xcodebuild test -project "$project" -scheme SempereScreenshots -derivedDataPath "$derived" \
      -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:SempereAppUITests/MacWindowUITests \
      CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
    ;;
  *)
    echo "usage: $0 test|test-phone|catalyst|test-mac|test-mac-ui|simulator" >&2
    exit 2
    ;;
esac
