#!/usr/bin/env bash
# App Store release checks for the Xcode project (docs/release/app-store.md).
# Runs on Linux and macOS (bash + python3 only, no Xcode). Fails if:
#   - MARKETING_VERSION or CURRENT_PROJECT_VERSION differ between targets or
#     configurations (an extension's versions must equal its app's), or an
#     Info.plist hard-codes a different one;
#   - DEVELOPMENT_TEAM (or a TargetAttributes DevelopmentTeam) is set anywhere
#     under Apps/ (never commit the signing team);
#   - the app's or the widget extension's PrivacyInfo.xcprivacy is missing or
#     invalid, declares tracking or collected data, uses an unknown reason code,
#     or misses a required-reason API category its sources call;
#   - an entitlements file has a key outside the allow-list below, a referenced
#     entitlements file is missing, or the Mac build is not sandboxed;
#   - the Mac build would get its own bundle id (no universal purchase);
#   - ITSAppUsesNonExemptEncryption is missing from the app's Info.plist;
#   - the two copies of the privacy policy (docs/privacy, docs/appstore) differ in date.
#
# Usage: scripts/release-check.sh [--root DIR] [--list]
#   --root DIR  check another checkout (scripts/test-release-check.sh uses copies)
#   --list      also print every required-reason API use as file:line
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
list=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) root="$(cd "$2" && pwd)"; shift 2 ;;
    --list) list=1; shift ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

exec python3 -I - "$root" "$list" <<'PY'
import os, plistlib, re, sys

root, list_uses = sys.argv[1], sys.argv[2] == "1"
app_dir = os.path.join(root, "Apps", "Sempere")
pbxproj_path = os.path.join(app_dir, "Sempere.xcodeproj", "project.pbxproj")
errors, warnings = [], []

def rel(p):
    return os.path.relpath(p, root)

def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()

# --- Policy -----------------------------------------------------------------

# Every entitlement the project may ship, and why (docs/release/app-store.md,
# "Entitlements"). Adding one is a deliberate change: update this list and the doc.
ENTITLEMENTS_ALLOWED = {
    "com.apple.security.app-sandbox",                    # required on the Mac App Store
    "com.apple.security.files.user-selected.read-write", # vault folders picked in the open panel
    "com.apple.security.files.bookmarks.app-scope",      # recent vaults across launches
    "com.apple.security.print",                          # printing the recovery kit
    "com.apple.security.device.audio-input",             # recording audio into notes
    "com.apple.security.application-groups",             # quick voice status for the widgets (iOS app + widget)
}

# The only value an entitlement on the allow-list may take, where it has one.
ENTITLEMENT_VALUES = {
    "com.apple.security.application-groups": ["group.io.github.anthonytw.sempere"],
}

# Apple's approved reasons per required-reason API category (TN3183 /
# "Describing use of required reason API"). A code outside this table is a typo.
APPLE_REASONS = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"DDA9.1", "C617.1", "3B52.1", "0A2A.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1", "8FFB.1", "3D61.1"},
    "NSPrivacyAccessedAPICategoryDiskSpace": {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    "NSPrivacyAccessedAPICategoryActiveKeyboards": {"3EC4.1", "54BD.1"},
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
}

# Calls that put a source file in a category (Swift and C spellings of the APIs
# Apple lists). Comment lines are skipped.
API_PATTERNS = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": re.compile(
        r"FileAttributeKey\.(creationDate|modificationDate)\b"
        r"|\[\s*\.(creationDate|modificationDate)\s*\]"
        r"|\.(creationDate|modificationDate)\s*:"
        r"|NSFile(Creation|Modification)Date"
        r"|\b(contentModificationDate|creationDate|contentAccessDate|attributeModificationDate)Key\b"
        r"|\.contentModificationDate\b|\bfileModificationDate\b"
        r"|(?<![.\w])[fl]?stat(at)?\s*\(|\b[fs]?(get|set)attrlist(bulk|at)?\s*\("),
    "NSPrivacyAccessedAPICategorySystemBootTime": re.compile(
        r"\bsystemUptime\b|\bmach_absolute_time\b|kern\.boottime"),
    "NSPrivacyAccessedAPICategoryDiskSpace": re.compile(
        r"\bvolume(Available|Total)Capacity\w*Key\b|NSFileSystem(Free|Size)\b|\.systemFreeSize\b"
        r"|\.systemSize\b|(?<![.\w])f?statv?fs\s*\(|attributesOfFileSystem"),
    "NSPrivacyAccessedAPICategoryActiveKeyboards": re.compile(r"\bactiveInputModes\b"),
    "NSPrivacyAccessedAPICategoryUserDefaults": re.compile(r"\bUserDefaults\b|@AppStorage\b|NSUserDefaults"),
}

# Package products the app links, mapped to the Sources/ targets they compile
# (transitively, from Package.swift). A product missing here fails the check, so
# a new dependency cannot slip past the privacy scan.
PRODUCT_SOURCES = {
    "Age": ["Age"],
    "Sempere": ["Sempere", "Age", "CZlib"],
    "SempereRender": ["SempereRender", "Sempere", "SemperePDF", "Age", "CZlib"],
    "SempereSpeech": ["SempereSpeech", "Sempere", "Age", "CZlib"],
    # The app's Notability import (`AppModel+NotabilityImport`).
    "SempereImport": ["SempereImport", "Sempere", "SemperePDF", "SempereRender", "Age", "CZlib"],
    # Third-party (app only, never in Sources/): ships its own manifest if it needs one;
    # check the archive's privacy report (docs/release/app-store.md).
    "SwiftMath": [],
}

# Targets that ship (the bundle the user installs), their source folders and privacy manifest.
SHIPPING = {
    "SempereApp": {"dirs": ["SempereApp", "SempereShared"],
                   "manifest": "SempereApp/PrivacyInfo.xcprivacy"},
    "SempereWidgets": {"dirs": ["SempereWidgets", "SempereShared"],
                       "manifest": "SempereWidgets/PrivacyInfo.xcprivacy"},
}

# --- Project file --------------------------------------------------------------

if not os.path.isfile(pbxproj_path):
    print(f"error: {rel(pbxproj_path)} not found", file=sys.stderr)
    sys.exit(1)
pbx = read(pbxproj_path)

def setting_values(name):
    # `NAME = value;` and `"NAME[sdk=...]" = value;`
    pat = re.compile(r'^\s*"?' + re.escape(name) + r'(\[[^\]]*\])?"?\s*=\s*(.*?);\s*$', re.M)
    return [m.group(2).strip().strip('"') for m in pat.finditer(pbx)]

for name in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
    vals = setting_values(name)
    if not vals:
        errors.append(f"{name} is not set in project.pbxproj")
    elif len(set(vals)) != 1:
        errors.append(f"{name} differs between targets/configurations: {sorted(set(vals))} "
                      "(an extension's version must equal its app's)")
marketing = (setting_values("MARKETING_VERSION") or [None])[0]
build = (setting_values("CURRENT_PROJECT_VERSION") or [None])[0]
if marketing and not re.fullmatch(r"\d+(\.\d+){0,2}", marketing):
    errors.append(f"MARKETING_VERSION {marketing!r} is not 1 to 3 dot-separated integers")
if build and not re.fullmatch(r"\d+(\.\d+){0,2}", build):
    errors.append(f"CURRENT_PROJECT_VERSION {build!r} is not 1 to 3 dot-separated integers")

# Signing team: never committed (docs/HANDOFF.md). Scan every text file under Apps/.
team_pat = re.compile(r'(DEVELOPMENT_TEAM(\[[^\]]*\])?"?\s*=\s*"?([^";\s]+)|DevelopmentTeam\s*=\s*"?([^";\s]+))')
for dirpath, dirnames, filenames in os.walk(app_dir):
    dirnames[:] = [d for d in dirnames if d not in ("xcuserdata", ".build", "build", "DerivedData")]
    for fn in filenames:
        if not fn.endswith((".pbxproj", ".xcconfig", ".xcscheme", ".plist", ".entitlements", ".xcworkspacedata")):
            continue
        p = os.path.join(dirpath, fn)
        try:
            text = read(p)
        except UnicodeDecodeError:
            continue
        for i, line in enumerate(text.splitlines(), 1):
            m = team_pat.search(line)
            if m and (m.group(3) or m.group(4)) not in ('""', ""):
                errors.append(f"{rel(p)}:{i}: signing team is set ({line.strip()}); never commit DEVELOPMENT_TEAM")

# Universal purchase: the Catalyst build must keep the iOS bundle id.
for v in setting_values("DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER"):
    if v.upper() == "YES":
        errors.append("DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER = YES gives the Mac build its own "
                      "bundle id (maccatalyst.…), which breaks universal purchase")
ids = set(setting_values("PRODUCT_BUNDLE_IDENTIFIER"))
app_id = "io.github.anthonytw.sempere"
if app_id not in ids:
    errors.append(f"the app's PRODUCT_BUNDLE_IDENTIFIER {app_id} is gone (it cannot change after the first upload)")
for v in setting_values("PRODUCT_BUNDLE_IDENTIFIER[sdk=macosx*]"):
    if v != app_id:
        errors.append(f"the Mac build overrides the bundle id ({v}); universal purchase needs {app_id}")
for i in ids:
    if i != app_id and not i.startswith(app_id + "."):
        errors.append(f"bundle id {i} is not under {app_id} (extensions must be prefixed by the app's id)")

# Package products linked by any target.
products = set(re.findall(r"isa = XCSwiftPackageProductDependency;[^}]*?productName = (\w+);", pbx, re.S))
for p in sorted(products - set(PRODUCT_SOURCES)):
    errors.append(f"package product {p} is linked but not in PRODUCT_SOURCES of scripts/release-check.sh: "
                  "add it (and check its privacy manifest)")

def target_products(target):
    m = re.search(r"/\* " + re.escape(target) + r" \*/ = \{\s*isa = PBXNativeTarget;(.*?)\n\t\t\};", pbx, re.S)
    if not m:
        return None
    block = m.group(1)
    deps = re.search(r"packageProductDependencies = \((.*?)\);", block, re.S)
    return set(re.findall(r"/\* (\w+) \*/", deps.group(1))) if deps else set()

# --- Info.plist ------------------------------------------------------------------

info_path = os.path.join(app_dir, "SempereInfo.plist")
for path in (info_path, os.path.join(app_dir, "SempereWidgetsInfo.plist")):
    try:
        with open(path, "rb") as f:
            info = plistlib.load(f)
    except Exception as e:
        errors.append(f"{rel(path)}: not a valid plist ({e})")
        continue
    for key, want in (("CFBundleShortVersionString", marketing), ("CFBundleVersion", build)):
        v = info.get(key)
        if v is not None and v not in ("$(MARKETING_VERSION)", "$(CURRENT_PROJECT_VERSION)") and v != want:
            errors.append(f"{rel(path)}: {key} = {v!r} disagrees with the build setting ({want!r})")
    if path == info_path:
        enc = info.get("ITSAppUsesNonExemptEncryption")
        if not isinstance(enc, bool):
            errors.append(f"{rel(path)}: ITSAppUsesNonExemptEncryption must be a boolean "
                          "(docs/release/export-compliance.md)")
        if enc is True and "ITSEncryptionExportComplianceCode" not in info:
            warnings.append(f"{rel(path)}: ITSAppUsesNonExemptEncryption is YES without "
                            "ITSEncryptionExportComplianceCode: every build will ask the encryption questions")

# --- Entitlements ---------------------------------------------------------------

ent_files = set()
for dirpath, dirnames, filenames in os.walk(app_dir):
    for fn in filenames:
        if fn.endswith(".entitlements"):
            ent_files.add(os.path.join(dirpath, fn))
for v in setting_values("CODE_SIGN_ENTITLEMENTS"):
    p = os.path.join(app_dir, v)
    if not os.path.isfile(p):
        errors.append(f"CODE_SIGN_ENTITLEMENTS names {v}, which does not exist")
    ent_files.add(p)
mac_ents = set(setting_values("CODE_SIGN_ENTITLEMENTS[sdk=macosx*]"))
for p in sorted(ent_files):
    if not os.path.isfile(p):
        continue
    try:
        with open(p, "rb") as f:
            ents = plistlib.load(f)
    except Exception as e:
        errors.append(f"{rel(p)}: not a valid plist ({e})")
        continue
    for k, want in ENTITLEMENT_VALUES.items():
        if k in ents and ents[k] != want:
            errors.append(f"{rel(p)}: {k} must be exactly {want} (docs/release/app-store.md \"Entitlements\")")
    for k in sorted(set(ents) - ENTITLEMENTS_ALLOWED):
        errors.append(f"{rel(p)}: entitlement {k} is not in the allow-list (scripts/release-check.sh, "
                      "docs/release/app-store.md \"Entitlements\")")
    if os.path.relpath(p, app_dir) in mac_ents and ents.get("com.apple.security.app-sandbox") is not True:
        errors.append(f"{rel(p)}: the Mac build must set com.apple.security.app-sandbox to true")
if not mac_ents:
    errors.append("no CODE_SIGN_ENTITLEMENTS[sdk=macosx*]: the Mac Catalyst build would not be sandboxed")

# --- Privacy manifests and required-reason APIs ------------------------------------

def scan(dirs):
    uses = {c: [] for c in API_PATTERNS}
    for d in dirs:
        for dirpath, dirnames, filenames in os.walk(d):
            dirnames.sort()
            for fn in sorted(filenames):
                if not fn.endswith((".swift", ".c", ".h", ".m")):
                    continue
                p = os.path.join(dirpath, fn)
                for i, line in enumerate(read(p).splitlines(), 1):
                    code = line.split("//", 1)[0]
                    if not code.strip() or code.lstrip().startswith("*"):
                        continue
                    for c, pat in API_PATTERNS.items():
                        if pat.search(code):
                            uses[c].append(f"{rel(p)}:{i}")
    return uses

for target, spec in SHIPPING.items():
    linked = target_products(target)
    if linked is None:
        errors.append(f"target {target} not found in project.pbxproj")
        continue
    dirs = [os.path.join(app_dir, d) for d in spec["dirs"]]
    for prod in sorted(linked):
        dirs += [os.path.join(root, "Sources", s) for s in PRODUCT_SOURCES.get(prod, [])]
    uses = scan(sorted(set(dirs)))
    mpath = os.path.join(app_dir, spec["manifest"])
    if not os.path.isfile(mpath):
        errors.append(f"{rel(mpath)} is missing (privacy manifest of {target})")
        continue
    try:
        with open(mpath, "rb") as f:
            man = plistlib.load(f)
    except Exception as e:
        errors.append(f"{rel(mpath)}: not a valid plist ({e})")
        continue
    if man.get("NSPrivacyTracking") is not False:
        errors.append(f"{rel(mpath)}: NSPrivacyTracking must be false")
    if man.get("NSPrivacyTrackingDomains", []) != []:
        errors.append(f"{rel(mpath)}: NSPrivacyTrackingDomains must be empty")
    if man.get("NSPrivacyCollectedDataTypes") != []:
        errors.append(f"{rel(mpath)}: NSPrivacyCollectedDataTypes must be an empty array (\"Data Not Collected\")")
    declared = {}
    for entry in man.get("NSPrivacyAccessedAPITypes", []):
        cat = entry.get("NSPrivacyAccessedAPIType")
        reasons = entry.get("NSPrivacyAccessedAPITypeReasons", [])
        if cat not in APPLE_REASONS:
            errors.append(f"{rel(mpath)}: unknown API category {cat!r}")
            continue
        if not reasons:
            errors.append(f"{rel(mpath)}: {cat} has no reason")
        for r in reasons:
            if r not in APPLE_REASONS[cat]:
                errors.append(f"{rel(mpath)}: {cat} reason {r!r} is not one of Apple's ({sorted(APPLE_REASONS[cat])})")
        declared[cat] = reasons
    for cat, where in uses.items():
        if where and cat not in declared:
            errors.append(f"{target} uses {cat} ({where[0]}{' and %d more' % (len(where) - 1) if len(where) > 1 else ''}) "
                          f"but {rel(mpath)} does not declare it")
        if not where and cat in declared:
            warnings.append(f"{rel(mpath)} declares {cat}, but no use was found in {target}'s sources "
                            "(dependencies and Apple frameworks are not scanned)")
    if list_uses:
        print(f"== {target} ({', '.join(rel(d) for d in sorted(set(dirs)))})")
        for cat, where in uses.items():
            for w in where:
                print(f"{cat.replace('NSPrivacyAccessedAPICategory', '')}\t{w}")

# --- Privacy policy: the Pages copy and the Markdown copy carry the same date ----------

policy_dates = {}
for p in ("docs/privacy/index.html", "docs/appstore/privacy-policy.md"):
    path = os.path.join(root, p)
    if not os.path.isfile(path):
        errors.append(f"{p} is missing (the privacy policy, docs/release/app-store.md section 5)")
        continue
    m = re.search(r"Last updated:\s*(?:<[^>]*>)?\s*(\d{4}-\d{2}-\d{2})", read(path))
    if not m:
        errors.append(f"{p}: no \"Last updated: YYYY-MM-DD\"")
        continue
    policy_dates[p] = m.group(1)
if len(set(policy_dates.values())) > 1:
    errors.append(f"the two privacy policy copies differ in date ({policy_dates}): edit both")

for w in warnings:
    print(f"warning: {w}", file=sys.stderr)
for e in errors:
    print(f"error: {e}", file=sys.stderr)
if errors:
    print(f"release-check: {len(errors)} problem(s)", file=sys.stderr)
    sys.exit(1)
print(f"release-check: ok (version {marketing}, build {build})")
PY
