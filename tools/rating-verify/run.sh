#!/usr/bin/env bash
# ─── rating-verify: one app's rating flow on a Mac runner ────────────────────
# Drives a private app's REAL build in a simulator and checks the App Store rating policy:
#   a real success moment asks, a share sheet closed without sharing does not, every ask happens
#   AFTER the sheet closed (checked by clock), and the 4th success no longer asks.
#
# ⛔ THIS REPOSITORY IS PUBLIC AND THE APP IT TESTS IS NOT. Nothing here prints project content:
# every command's output goes to a file under $RUNNER_TEMP. The console gets breadcrumbs of its own
# making (which step was reached, which assertion failed), the on-screen rating markers and a
# PASS/FAIL line — never the app's screen dumps, sources or file paths.
#
# The simulator-only patch (RevenueCat cut + the StoreKit call replaced by an on-screen marker) is
# applied to the RUNNER's checkout only and never committed anywhere.
#
# env: APP_DIR KIND BUNDLE V_HOME V_FILE V_READY V_OPEN_ASKS V_EXPORT V_ONBOARD FIXTURE [SPEC_B64]
#      TOOLS (this directory), OUT (log file), FAIL_TAIL (0 = print nothing on failure)
set -uo pipefail
TOOLS="${TOOLS:?tools dir}"; APP_DIR="${APP_DIR:?app dir}"; KIND="${KIND:?kind}"
OUT="${OUT:-$RUNNER_TEMP/rating-verify.log}"; FAIL_TAIL="${FAIL_TAIL:-60}"
: > "$OUT"
say() { printf '%s\n' "$*"; }
run() { echo "+ $*" >> "$OUT"; "$@" >> "$OUT" 2>&1; }
scrub() { sed -e "s#$HOME#~#g" -e "s#$APP_DIR#APP#g" -e "s#$RUNNER_TEMP#TMP#g"; }
die() {
  say "FAIL: $1"
  if [ "$FAIL_TAIL" -gt 0 ]; then
    say "--- steps the test reached ---"
    grep -oE "VERIFY-TREE [A-Za-z0-9-]+ BEGIN" "$OUT" | sed -e 's/VERIFY-TREE //' -e 's/ BEGIN//' | uniq | tr '\n' ' '
    echo
    say "--- what the screen was when it broke ---"
    grep -a -o "VERIFY-STATE .*" "$OUT" | head -3
    say "--- assertions that failed ---"
    grep -o "testRatingFlow\] : .*" "$OUT" | sed 's/^testRatingFlow\] : //' | head -12 | cut -c1-160
    say "--- build / run errors ---"
    # A test that never ran leaves no assertion and no "error:" line — the reason is phrased by
    # xcodebuild or CoreSimulator instead ("The test runner exited", "Unable to boot"). Match those
    # too, or a failure like that reports nothing at all and cannot be diagnosed.
    grep -nE "error:|fatal error|\*\* [A-Z ]+ FAILED|No such file|command not found|Testing failed|test runner|Unable to |Failed to |Underlying error|crashed|Timed out|never launched|not available" \
      "$OUT" | tail -14 | scrub | cut -c1-200
  fi
  exit 1
}

# ── 1. simulator-only patch ──────────────────────────────────────────────────
case "$KIND" in
  generic)      run python3 "$TOOLS/patch-web.py" "$APP_DIR" || die "patch (template)" ;;
  generic-spec) printf '%s' "${SPEC_B64:?spec}" | base64 -d > "$RUNNER_TEMP/spec.json"
                run python3 "$TOOLS/patch-web.py" "$APP_DIR" "$RUNNER_TEMP/spec.json" || die "patch (spec)" ;;
  native:*)     run python3 "$TOOLS/patch-swift.py" "$APP_DIR" || die "patch (swift)" ;;
  *) die "unknown kind" ;;
esac
say "patch: applied"

# ── 2. fixture: a file from the app's own repo, or one generated here ────────
FIXDIR="$RUNNER_TEMP/fixture"; mkdir -p "$FIXDIR"
case "${FIXTURE:?fixture}" in
  repo:*) src="${FIXTURE#repo:}"; dest="${src##*:}"; src="${src%:*}"
          [ -f "$APP_DIR/$src" ] || die "fixture missing in the app repo"
          cp "$APP_DIR/$src" "$FIXDIR/$dest" ;;
  gen:*)  run bash "$TOOLS/make-fixture.sh" "${FIXTURE#gen:}" "$FIXDIR" || die "fixture generator" ;;
  *) die "unknown fixture recipe" ;;
esac
FIXFILE=$(ls "$FIXDIR" | head -1); [ -n "$FIXFILE" ] || die "no fixture produced"
say "fixture: $FIXFILE ($(wc -c < "$FIXDIR/$FIXFILE" | tr -d ' ') bytes)"

# ── 3. build the app for testing ─────────────────────────────────────────────
cd "$APP_DIR" || die "app dir"
ARCH=$(uname -m); [ "$ARCH" = arm64 ] && RUST_SIM=aarch64-apple-ios-sim || RUST_SIM=x86_64-apple-ios
if [ -d rust-engine ] || [ -d engine ] || [ -d ios/rust-engine ]; then
  run rustup target add "$RUST_SIM" || true
fi
case "$KIND" in
  native:*)
    command -v xcodegen >/dev/null || run brew install xcodegen || die "xcodegen"
    run xcodegen generate || die "xcodegen generate"
    PROJ=$(ls -d ./*.xcodeproj | head -1); TESTS_DIR=VerifyUITests; APP_TARGET="${KIND#native:}" ;;
  *)
    script=""
    for cand in rust-engine/build-ios.sh ios/rust-engine/build-ios.sh engine/build-ios.sh; do
      [ -f "$cand" ] && script="$cand" && break
    done
    if [ -n "$script" ]; then
      # These engines build with `cargo --offline`: fine on a machine whose registry already holds the
      # crates, but a fresh runner has an empty one and the build dies with "no matching package
      # named ...". Fill the registry from the lockfile first.
      run cargo fetch --locked --manifest-path "$(dirname "$script")/Cargo.toml" \
        || run cargo fetch --manifest-path "$(dirname "$script")/Cargo.toml" \
        || die "cargo fetch (engine dependencies)"
      ( cd "$(dirname "$script")" && env SDK_NAME=iphonesimulator PLATFORM_NAME=iphonesimulator \
          EFFECTIVE_PLATFORM_NAME=-iphonesimulator ARCHS="$ARCH" bash "./$(basename "$script")" ) >> "$OUT" 2>&1 \
        || die "rust engine build"
    fi
    if [ -d rust ] && [ ! -d src/wasm ]; then
      RUST_DIR=$(find rust -maxdepth 1 -type d ! -name rust | head -1)
      if [ -n "$RUST_DIR" ] && [ -f "$RUST_DIR/Cargo.toml" ]; then
        command -v wasm-pack >/dev/null || run brew install wasm-pack || true
        ENGINE=$(basename "$RUST_DIR" | sed 's/-wasm-engine//')
        run wasm-pack build "$RUST_DIR" --target web --out-dir "../../src/wasm/${ENGINE}-engine" --release || die "wasm engine"
      fi
    fi
    run npm ci --legacy-peer-deps || { rm -f package-lock.json; run npm install --legacy-peer-deps || die "npm install"; }
    run npm run build || die "web build"
    run npx cap sync ios || die "cap sync"
    # A Capacitor project builds through CocoaPods: without `pod install` the Xcode project points at
    # an xcconfig that does not exist yet and the build dies on "Unable to open base configuration".
    if [ -f ios/App/Podfile ]; then
      command -v pod >/dev/null || run gem install --no-document cocoapods || die "cocoapods install"
      ( cd ios/App && run pod install ) || die "pod install"
    fi
    PROJ=ios/App/App.xcodeproj; TESTS_DIR=VerifyUITests; APP_TARGET=App
    cd ios/App || die "ios dir" ;;
esac
say "build: web and native inputs ready"

mkdir -p "$TESTS_DIR"
cp "$TOOLS/uitest-generic.swift" "$TESTS_DIR/VerifyUITests.swift"
run gem install --no-document xcodeproj || die "xcodeproj gem"
run ruby "$TOOLS/add-uitest-target.rb" "$(basename "$PROJ")" "$APP_TARGET" "$TESTS_DIR" || die "add test target"

DD="$RUNNER_TEMP/dd"
XC="-project $(basename "$PROJ")"; [ -d App.xcworkspace ] && XC="-workspace App.xcworkspace"
# The same small phone the policy was verified on locally: a 4.7" screen puts the export controls
# below the fold, which is exactly the case the test has to survive. Fall back to any iPhone.
pick_device() {
  xcrun simctl list devices available -j | python3 -c 'import json,sys
d = json.load(sys.stdin)["devices"]
se = None; any_iphone = None
for rt, ds in d.items():
    if "iOS" not in rt:
        continue
    for x in ds:
        if not x.get("isAvailable"):
            continue
        if "iPhone SE" in x["name"] and se is None:
            se = x["udid"]
        if "iPhone" in x["name"] and any_iphone is None:
            any_iphone = x["udid"]
print(se or any_iphone or "")'
}
DEV=$(pick_device)
if ! xcrun simctl list devices available | grep -q "iPhone SE"; then
  RT=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and "iOS" in r["name"]]
print(rs[-1]["identifier"] if rs else "")')
  TYPE=$(xcrun simctl list devicetypes -j | python3 -c 'import json,sys
ts = [t for t in json.load(sys.stdin)["devicetypes"] if "iPhone SE" in t["name"]]
print(ts[-1]["identifier"] if ts else "")')
  if [ -n "$RT" ] && [ -n "$TYPE" ] && xcrun simctl create rating-verify-se "$TYPE" "$RT" >> "$OUT" 2>&1; then
    DEV=$(pick_device); say "device: created a small phone for this run"
  else
    say "device: no small phone available on this runner, using the default one"
  fi
fi
[ -n "$DEV" ] || die "no iPhone simulator on the runner"
say "device: $(xcrun simctl list devices | grep "$DEV" | sed -e 's/^ *//' -e "s/ ($DEV).*//")"
run xcodebuild build-for-testing $XC -scheme VerifyUI -destination "id=$DEV" \
  -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO || die "build-for-testing"
say "build: test bundle built"

# ── 4. fresh install, fixture in place, then the test ────────────────────────
run xcrun simctl boot "$DEV" || true
run xcrun simctl bootstatus "$DEV" -b || true
run xcrun simctl uninstall "$DEV" "${BUNDLE:?bundle}" || true
APP=$(find "$DD/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name '*.app' -type d ! -name '*-Runner.app' | head -1)
[ -n "$APP" ] || die "built app not found"
run xcrun simctl install "$DEV" "$APP" || die "install"
DOCS="$(xcrun simctl get_app_container "$DEV" "$BUNDLE" data)/Documents"
mkdir -p "$DOCS"; cp "$FIXDIR/$FIXFILE" "$DOCS/"
# A never-used runner simulator has no Files storage yet: start Files once so the fixture can also
# sit in "On My iPhone", where an app without its own Files folder opens its picker.
xcrun simctl launch "$DEV" com.apple.DocumentsApp >/dev/null 2>&1 || true
sleep 5
xcrun simctl terminate "$DEV" com.apple.DocumentsApp >/dev/null 2>&1 || true
placed="app Documents"
for g in "$HOME/Library/Developer/CoreSimulator/Devices/$DEV"/data/Containers/Shared/AppGroup/*; do
  [ -d "$g" ] || continue
  id=$(/usr/libexec/PlistBuddy -c 'Print :MCMMetadataIdentifier' "$g/.com.apple.mobile_container_manager.metadata.plist" 2>/dev/null || true)
  if [ "$id" = "group.com.apple.FileProvider.LocalStorage" ]; then
    mkdir -p "$g/File Provider Storage" && cp "$FIXDIR/$FIXFILE" "$g/File Provider Storage/" && placed="$placed + On My iPhone"
  fi
done
say "app installed fresh; fixture in: $placed"

export TEST_RUNNER_V_HOME="${V_HOME:-}" TEST_RUNNER_V_FILE="${V_FILE:-}" TEST_RUNNER_V_READY="${V_READY:-}"
export TEST_RUNNER_V_OPEN_ASKS="${V_OPEN_ASKS:-0}" TEST_RUNNER_V_EXPORT="${V_EXPORT:-}" TEST_RUNNER_V_ONBOARD="${V_ONBOARD:-}"
XCTESTRUN=$(ls "$DD"/Build/Products/*.xctestrun | head -1)
run xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "id=$DEV" \
  -only-testing:"VerifyUITests/VerifyUITests/testRatingFlow"
rc=$?
xcrun simctl shutdown "$DEV" >/dev/null 2>&1 || true

# ── 5. verdict: only the markers and the counts reach the log ────────────────
asks=$(grep -oE "REVIEW-VERIFY ask [0-9] of 3 at [0-9]+" "$OUT" | sort -u)
executed=$(grep -oE 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$OUT" | tail -1)
say "asks seen on screen:"; printf '%s\n' "${asks:-  (none)}" | sed 's/^/  /'
say "xctest: ${executed:-none}"
[ "$rc" -eq 0 ] || die "testRatingFlow ($executed)"
printf '%s' "$executed" | grep -q "with 0 failures" || die "testRatingFlow ($executed)"
say "PASS"
