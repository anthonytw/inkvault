#!/usr/bin/env bash
# App Store screenshots from a synthetic demo vault (docs/appstore/screenshots.md).
# Needs Xcode on a Mac. Nothing is uploaded anywhere.
#
#   scripts/screenshots.sh ipad   # iPad Pro 13-inch simulator, 2064x2752 portrait
#   scripts/screenshots.sh mac    # Mac Catalyst, composed onto 2880x1800 (best effort)
#   scripts/screenshots.sh        # both
#
# Output: build/screenshots/ipad/*.png and build/screenshots/mac/*.png
# (SEMPERE_SHOTS_OUT changes the folder). SEMPERE_SIM_ID picks the simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
project=Apps/Sempere/Sempere.xcodeproj
scheme=SempereScreenshots
derived=${SEMPERE_DERIVED_DATA:-.build/xcode}
out=${SEMPERE_SHOTS_OUT:-build/screenshots}
mkdir -p "$out"
out=$(cd "$out" && pwd)   # the test runner needs an absolute path

# The newest iPad Pro 13-inch simulator on iOS 26 or newer (2064x2752 pixels).
pick_simulator() {
  if [[ -n "${SEMPERE_SIM_ID:-}" ]]; then echo "$SEMPERE_SIM_ID"; return; fi
  xcrun simctl list devices available --json | /usr/bin/python3 -c '
import json, re, sys
best = None
for runtime, devs in json.load(sys.stdin)["devices"].items():
    m = re.search(r"SimRuntime\.iOS-(\d+)-(\d+)", runtime)
    if not m or (int(m.group(1)), int(m.group(2))) < (26, 0):
        continue
    for d in devs:
        if d.get("isAvailable") and d["name"].startswith("iPad Pro 13-inch"):
            key = ((int(m.group(1)), int(m.group(2))), d["name"])
            if best is None or key > best[0]:
                best = (key, d["udid"], d["name"])
if best is None:
    sys.exit("no iPad Pro 13-inch simulator on iOS 26+ (xcrun simctl list devices; xcodebuild -downloadPlatform iOS)")
print("using " + best[2], file=sys.stderr)
print(best[1])
'
}

pixels() { sips -g pixelWidth -g pixelHeight "$1" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}'; }

ipad() {
  local sim dir="$out/ipad"
  sim=$(pick_simulator)
  rm -rf "$dir"; mkdir -p "$dir"
  xcrun simctl bootstatus "$sim" -b >/dev/null
  # No clutter: 9:41, full battery, full bars, light mode.
  xcrun simctl status_bar "$sim" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode notSupported --batteryState charged --batteryLevel 100
  xcrun simctl ui "$sim" appearance light
  trap 'xcrun simctl status_bar "$sim" clear || true' RETURN
  local status=0 f bad=0
  # A shot that never showed its screen fails the test but still leaves a PNG: keep going to check them all.
  TEST_RUNNER_SEMPERE_SHOTS_DIR="$dir" xcodebuild test -project "$project" -scheme "$scheme" \
    -derivedDataPath "$derived" -destination "platform=iOS Simulator,id=$sim" \
    -only-testing:SempereAppUITests -parallel-testing-enabled NO -resultBundlePath "$out/ipad.xcresult" \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$out/ipad.log" || status=${PIPESTATUS[0]}
  grep -E "error: |SHOTDEBUG" "$out/ipad.log" > "$out/ipad-summary.txt" || true
  ls "$dir"/*.png >/dev/null 2>&1 || { echo "error: no screenshots were written" >&2; exit 1; }
  for f in "$dir"/*.png; do
    if [[ "$(pixels "$f")" != 2064x2752 ]]; then echo "error: $f is $(pixels "$f"), want 2064x2752" >&2; bad=1; fi
  done
  [[ $bad == 0 ]] || exit 1
  echo "iPad screenshots: $dir"
  return $status
}

# Copies the screenshot attachments of a result bundle to DIR as <shot name>.png.
export_attachments() {
  local bundle=$1 dest=$2 tmp
  tmp=$(mktemp -d)
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$tmp"
  /usr/bin/python3 - "$tmp" "$dest" <<'PY'
import json, os, shutil, subprocess, sys
src, dest = sys.argv[1:3]
for test in json.load(open(os.path.join(src, "manifest.json"))):
    for a in test.get("attachments", []):
        name = a["suggestedHumanReadableName"].split("_")[0]
        if not name[:2].isdigit():
            continue
        path = os.path.join(src, a["exportedFileName"])
        out = os.path.join(dest, name + ".png")
        if path.lower().endswith(".png"):
            shutil.copy(path, out)
        else:
            subprocess.check_call(["sips", "-s", "format", "png", path, "--out", out], stdout=subprocess.DEVNULL)
PY
  rm -rf "$tmp"
}

# A Mac window shot has whatever size the window and the display give; scale it to fit
# and centre it on a plain 2880x1800 canvas (App Store Connect takes only exact sizes).
mac() {
  local dir="$out/mac" raw="$out/mac-raw" status=0
  rm -rf "$dir" "$raw"; mkdir -p "$dir" "$raw"
  TEST_RUNNER_SEMPERE_SHOTS_DIR="$raw" xcodebuild test -project "$project" -scheme "$scheme" \
    -derivedDataPath "$derived" -destination 'platform=macOS,variant=Mac Catalyst' \
    -only-testing:SempereAppUITests -resultBundlePath "$out/mac.xcresult" \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES 2>&1 | tee "$out/mac.log" || status=${PIPESTATUS[0]}
  grep -E "error: |SHOTDEBUG" "$out/mac.log" > "$out/mac-summary.txt" || true
  # The Mac test runner is sandboxed and cannot write into the checkout: take the shots
  # from the result bundle's attachments instead.
  if ! ls "$raw"/*.png >/dev/null 2>&1; then
    export_attachments "$out/mac.xcresult" "$raw"
  fi
  ls "$raw"/*.png >/dev/null 2>&1 || { echo "error: no screenshots were found" >&2; exit 1; }
  local f size w h scaled
  for f in "$raw"/*.png; do
    size=$(pixels "$f"); w=${size%x*}; h=${size#*x}
    scaled=$(/usr/bin/python3 -c "
w, h = $w, $h
f = min(2560 / w, 1600 / h)
print(round(h * f), round(w * f))")
    cp "$f" "$dir/$(basename "$f")"
    sips -z $scaled "$dir/$(basename "$f")" >/dev/null
    sips --padToHeightWidth 1800 2880 --padColor E9E6DF "$dir/$(basename "$f")" >/dev/null
    [[ "$(pixels "$dir/$(basename "$f")")" == 2880x1800 ]] || { echo "error: $f did not end up 2880x1800" >&2; exit 1; }
  done
  echo "Mac screenshots: $dir"
  return $status
}

case "${1:-all}" in
  ipad) ipad ;;
  mac) mac ;;
  all) ipad; mac ;;
  *) echo "usage: $0 [ipad|mac|all]" >&2; exit 2 ;;
esac
