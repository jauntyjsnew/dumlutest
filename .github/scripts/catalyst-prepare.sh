#!/usr/bin/env bash
# Make a checked-out Capacitor project buildable for Mac Catalyst.
#
# ⛔ A FRESH CLONE DOES NOT BUILD FOR MAC. Three separate things are true of
# every project in this portfolio, and each one alone is fatal:
#   1. `SUPPORTS_MACCATALYST` is not in the pbxproj — the publish workflows
#      inject it, so `xcodebuild` on a clone silently tests something else.
#   2. Capacitor 8 ships Capacitor.xcframework and Cordova.xcframework through
#      SPM with NO maccatalyst slice (measured: only `ios-arm64` and
#      `ios-arm64_x86_64-simulator`), so the Catalyst link fails on correct code.
#      The fix is to drop SPM and use the CocoaPods podspecs, which build from
#      source and therefore have a Catalyst slice.
#   3. RevenueCat calls `presentCodeRedemptionSheet()`, which breaks the compile.
#      ⛔ AND THE REASON IS NOT THE ONE EVERYONE ASSUMES. Apple's own header on
#      this SDK is `API_UNAVAILABLE(tvos, macos, watchos)` — macCatalyst is NOT
#      in that list, so StoreKit's method IS available on Catalyst and a
#      typecheck of it passes. The blocker is RevenueCat's OWN wrapper:
#        PurchasesHybridCommon.CommonFunctionality.presentCodeRedemptionSheet:7
#        note: 'presentCodeRedemptionSheet()' has been explicitly marked unavailable here
#      MEASURED both ways on Xcode 26.6: patched -> BUILD SUCCEEDED, unpatched ->
#      exit 65. Anyone who checks Apple's header, concludes the patch is
#      unnecessary and drops it will ship a build that cannot compile for Mac.
#
# ⛔ AND "BUILDABLE" MEANS BUILDABLE THE WAY r.yml BUILDS IT. verify-catalyst.yml
# asks this script whether a commit compiles for Mac, and that answer is worth
# having only while it agrees with the publish workflow. Every step r.yml takes
# before its Catalyst build that this script skips makes verification wrong in
# one of two directions:
#   - RED for an app that ships. MEASURED 2026-09-10 on pst-to-mbox
#     (@capacitor/filesystem 8.1.2): this script put CapacitorFilesystem v8 in
#     the Podfile and the universal Release build died, exit 65, on
#       CAPPluginCall+Accelerators.swift:2:8: error: unable to resolve module dependency: 'IONFilesystemLib'
#     with no error in the App target — while r.yml, which pins v6, had built
#     and uploaded that app's Mac package three days earlier (run 34130449978:
#     `Installing CapacitorFilesystem (6.0.4)`). 55 of the 73 Capacitor repos
#     carried filesystem v7+ that day.
#   - GREEN for an app r.yml refuses, e.g. one whose src/ still imports a pod
#     that r.yml strips.
# So each block below names the r.yml step it mirrors. Change one, change both.
#
# It does this to a TEMPORARY checkout, never to a developer's tree: it rewrites
# the pbxproj, deletes CapApp-SPM and downgrades a dependency.
set -euo pipefail
cd "${1:?usage: catalyst-prepare.sh <project-dir>}"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8   # pod install dies on ASCII-8BIT otherwise

echo "── web assets"
# r.yml `Deps`: a lockfile that `npm ci` refuses is DELETED before
# `npm install`. Left in place it keeps being honoured, and the two builds
# compile different dependency versions whenever a lockfile has drifted.
if [ -f package-lock.json ]; then
  npm ci --legacy-peer-deps || { rm -f package-lock.json; npm install --legacy-peer-deps; }
else
  npm install --legacy-peer-deps
fi
npm run build
# r.yml `Sync`: a repo with no Xcode project gets one (jpeg-repair and
# prompt-pal commit none), and it is `cap sync`, not `cap copy` — for a
# committed Podfile that is what refreshes the plugin list step 3/3 builds on.
if [ ! -d ios/App/App.xcodeproj ]; then
  npx cap add ios --packagemanager cocoapods 2>/dev/null || npx cap add ios
fi
npx cap sync ios

# r.yml `Node` -> `iOS Target` / `Catalyst Pods`: ONE deployment target — 13.0
# for Capacitor <=5, 15.0 otherwise — on the project, every target and every
# pod. It decides which APIs compile without an availability check, so a
# pbxproj that says 14.0 (msgViewer's does) must not be verified at 14.0 when
# r.yml builds it at 15.0.
CAP_VER=$(node -p 'const p = require("./package.json"); (p.dependencies || {})["@capacitor/core"] || (p.devDependencies || {})["@capacitor/core"] || ""')
CAP_MAJOR=$(printf '%s' "$CAP_VER" | sed 's/[^0-9.]//g' | cut -d. -f1)
IOS_TARGET=15.0
if [ -n "$CAP_MAJOR" ] && [ "$CAP_MAJOR" -le 5 ] 2>/dev/null; then IOS_TARGET=13.0; fi
export IOS_TARGET

gem list -i xcodeproj >/dev/null 2>&1 || sudo gem install xcodeproj --no-document

echo "── 1/3 turn Mac Catalyst on, and drop the SPM product"
# r.yml `Preserve app native sources (pre-SPM-teardown)`. Capacitor 8 lets an
# app keep its OWN native sources in CapApp-SPM/Sources/CapApp-SPM, reach them
# through `import CapApp_SPM` and name that module in the storyboard's
# customModule — bankconverter, igcViewer and p7mViewer do. Deleting
# CapApp-SPM without rescuing them is
#   AppDelegate.swift:3:8: error: unable to resolve module dependency: 'CapApp_SPM'
# (r.yml run 32664742253): red here for an app r.yml ships.
PRESERVED=0
if [ -d ios/App/CapApp-SPM/Sources/CapApp-SPM ]; then
  for f in ios/App/CapApp-SPM/Sources/CapApp-SPM/*.swift; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "CapApp-SPM.swift" ] && continue   # the package's own marker, not app code
    mkdir -p ios/App/App/Native
    cp "$f" ios/App/App/Native/
    echo "  preserved: $(basename "$f")"
    PRESERVED=$((PRESERVED + 1))
  done
fi
python3 - <<'PY'
import glob, re
sb = "ios/App/App/Base.lproj/Main.storyboard"
try:
    s = open(sb).read()
except OSError:
    s = ""
if 'customModule="CapApp_SPM"' in s:
    open(sb, "w").write(s.replace('customModule="CapApp_SPM"', 'customModule="App"'))
    print("  storyboard: customModule CapApp_SPM -> App")
for p in sorted(glob.glob("ios/App/App/**/*.swift", recursive=True)):
    s = open(p).read()
    t = re.sub(r"^import CapApp_SPM(?:\n|\Z)", "", s, flags=re.M)
    if t != s:
        open(p, "w").write(t)
        print("  dropped import CapApp_SPM: " + p)
PY
PRESERVED=$PRESERVED ruby -e '
  require "xcodeproj"
  proj = Xcodeproj::Project.open("ios/App/App.xcodeproj")
  app = proj.targets.find { |t| t.name == "App" } or abort "no App target"
  app.build_configurations.each do |c|
    c.build_settings["SUPPORTS_MACCATALYST"] = "YES"
    c.build_settings["SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD"] = "NO"
    c.build_settings["DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER"] = "NO"
  end
  # r.yml step "iOS Target".
  (proj.build_configurations + proj.targets.flat_map(&:build_configurations)).each do |c|
    c.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = ENV.fetch("IOS_TARGET")
  end
  # r.yml step "Preserve app native sources": a rescued file is in no target until the project says so.
  if ENV.fetch("PRESERVED").to_i > 0
    group = proj.main_group.find_subpath("App/Native", true)
    group.set_source_tree("SOURCE_ROOT")
    group.set_path("App/Native")
    added = 0
    Dir.glob("ios/App/App/Native/*.swift").sort.each do |path|
      name = File.basename(path)
      next if group.files.any? { |f| f.display_name == name }
      app.add_file_references([group.new_reference(name)])
      added += 1
    end
    abort "no sources added to App target" if added.zero?
    puts "  added #{added} app native source(s) to the App target"
  end
  # r.yml step "SPM Clean" — every target, not only App.
  proj.root_object.package_references.clear
  proj.targets.each do |t|
    t.package_product_dependencies.clear
    t.dependencies.to_a.each { |d| d.remove_from_project if d.respond_to?(:product_ref) && d.product_ref }
    bp = t.frameworks_build_phase or next
    bp.files.to_a.each { |f| f.remove_from_project if f.respond_to?(:product_ref) && f.product_ref }
  end
  proj.main_group.recursive_children.each do |child|
    next unless child.respond_to?(:path) && child.path.to_s.include?("CapApp-SPM")
    child.remove_from_project rescue nil
  end
  proj.save
'
# xcodeproj clears REMOTE package refs; a LOCAL one (CapApp-SPM) needs removing by hand.
python3 - "$PWD/ios/App/App.xcodeproj/project.pbxproj" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r"^\t\t\w+ /\* CapApp-SPM in Frameworks \*/.*\n", "", s, flags=re.M)
s = re.sub(r"^\t+\w+ /\* CapApp-SPM in Frameworks \*/,\n", "", s, flags=re.M)
for sec in ("XCLocalSwiftPackageReference", "XCSwiftPackageProductDependency"):
    s = re.sub(r"/\* Begin %s section \*/.*?/\* End %s section \*/\n" % (sec, sec), "", s, flags=re.S)
open(p, "w").write(s)
print("  SPM references removed")
PY
rm -rf ios/App/CapApp-SPM

echo "── 2/3 patch the plugins that cannot compile for Catalyst as shipped"
# r.yml `RC Patch`, the same three rules: no PurchasesPlugin.swift under the
# package's ios/ -> nothing to do (kgtolb has no RevenueCat at all); the file
# already says `#if !targetEnvironment(macCatalyst)` ANYWHERE -> nothing to do;
# otherwise r.yml's own sed wraps every `CommonFunctionality.presentCodeRedemptionSheet()`.
# ⛔ MEASURED 2026-09-10, stlviewer (RevenueCat 12.2.2): this block used to demand
# one exact `if #available(iOS 14.0, *) {…}` block and refuse anything else.
# RevenueCat ships no guard (every release checked, 9.0.9 to 13.5.1, carries that
# bare block); stlviewer's COMMITTED Podfile adds one in its post_install, which
# `cap sync` runs above — a column-0 `#if` INSIDE the `if #available` block. r.yml
# skipped that file and shipped, while this script stopped here, red. With
# r.yml's rule the same commit built for Mac: BUILD SUCCEEDED, x86_64 arm64, platform 6.
# ⛔ Still defensive, about the ANSWER rather than the shape: once r.yml's edit is
# done, is a presentCodeRedemptionSheet call left that Mac Catalyst compiles?
# RevenueCat's own wrapper is unavailable there (top of this file), so that is
# exit 65 in r.yml's build too — a guard elsewhere in the file makes r.yml skip,
# and its sed only sees the one-line call. Refuse, naming the line, instead of
# building to the same red.
RC_IOS=node_modules/@revenuecat/purchases-capacitor/ios
if [ ! -d "$RC_IOS" ]; then
  echo "  RevenueCat not installed — nothing to patch"
else
  PLUGIN_FILE=$(find "$RC_IOS" -name "PurchasesPlugin.swift" 2>/dev/null | head -n 1 || true)
  if [ -z "$PLUGIN_FILE" ] || [ ! -f "$PLUGIN_FILE" ]; then
    echo "  RevenueCat: no PurchasesPlugin.swift — r.yml patches nothing"
  elif grep -q "#if !targetEnvironment(macCatalyst)" "$PLUGIN_FILE"; then
    echo "  RevenueCat: already says #if !targetEnvironment(macCatalyst) — r.yml patches nothing"
  else
    sed -i.bak 's/CommonFunctionality\.presentCodeRedemptionSheet()/#if !targetEnvironment(macCatalyst)\n            CommonFunctionality.presentCodeRedemptionSheet()\n            #else\n            \/\/ Not available on Mac Catalyst\n            call.reject("Not available on Mac Catalyst")\n            return\n            #endif/g' "$PLUGIN_FILE"
    echo "  RevenueCat: wrapped with r.yml's sed"
  fi
  python3 - "$RC_IOS" <<'PY'
import os, re, sys
CAT = "targetEnvironment(macCatalyst)"

def catalyst_skips(chain):
    # One #if/#elseif/#else chain up to the branch a line sits in; None = #else.
    *earlier, here = chain
    if CAT in earlier:
        return True
    return here is not None and "||" not in here and "!" + CAT in here.split("&&")

guarded, reachable = 0, []
for root, dirs, files in os.walk(sys.argv[1]):
    dirs[:] = sorted(d for d in dirs if not d.endswith("Tests"))   # the pod compiles no tests
    for name in sorted(f for f in files if f.endswith(".swift")):
        path = os.path.join(root, name)
        src = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group().count("\n"),
                     open(path, encoding="utf-8").read(), flags=re.S)
        chains = []
        for n, line in enumerate(src.split("\n"), 1):
            code = re.sub(r'"(?:\\.|[^"\\])*"', '""', line).split("//")[0]
            for call in re.finditer(r"\bpresentCodeRedemptionSheet\s*\(", code):
                if re.search(r"\bfunc\s+$", code[:call.start()]):
                    continue
                if any(catalyst_skips(c) for c in chains):
                    guarded += 1
                else:
                    reachable.append("%s:%d" % (path, n))
            directive = re.match(r"\s*#(if|elseif|else|endif)\b(.*)", code)
            if not directive:
                continue
            kind, cond = directive.group(1), re.sub(r"\s+", "", directive.group(2))
            if kind == "if":
                chains.append([cond])
            elif chains and kind == "endif":
                chains.pop()
            elif chains:
                chains[-1].append(cond if kind == "elseif" else None)
if reachable:
    print("  ⛔ Mac Catalyst still compiles presentCodeRedemptionSheet at " + ", ".join(reachable))
    print("  RevenueCat's wrapper is unavailable on Mac Catalyst, so r.yml's build of this commit fails to compile:"
          " its RC Patch left the call as it is (a guard elsewhere in the file makes it skip; its sed matches"
          " only the one-line call). Refusing instead of building to the same red.")
    sys.exit(1)
print("  RevenueCat: %d presentCodeRedemptionSheet call(s), none reachable on Mac Catalyst" % guarded)
PY
fi
# r.yml `Geolocation Catalyst Patch`. @capacitor/geolocation 8 imports
# IONGeolocationLib, another prebuilt .xcframework, and r.yml builds the Mac app
# without it: on Catalyst the plugin becomes a stub that rejects every call, and
# the two other files that import the library compile to nothing. Its podspec
# half is in step 3/3, where r.yml does it. GPXview is the app this is for.
python3 - <<'PY'
import os
d = "node_modules/@capacitor/geolocation/ios/Sources/GeolocationPlugin"
plugin = os.path.join(d, "GeolocationPlugin.swift")
if not os.path.isfile(plugin):
    raise SystemExit(0)
if "GPX_CATALYST_GEO_STUB" in open(plugin).read():
    print("  geolocation: already stubbed"); raise SystemExit(0)
def wrap(head, path):
    body = open(path).read()
    open(path, "w").write(head + body + ("" if body.endswith("\n") else "\n") + "#endif\n")
wrap('''#if targetEnvironment(macCatalyst)
import Capacitor

@objc(GeolocationPlugin)
public class GeolocationPlugin: CAPPlugin, CAPBridgedPlugin {
    // GPX_CATALYST_GEO_STUB
    public let identifier = "GeolocationPlugin"
    public let jsName = "Geolocation"
    public let pluginMethods: [CAPPluginMethod] = [
        .init(name: "getCurrentPosition", returnType: CAPPluginReturnPromise),
        .init(name: "watchPosition", returnType: CAPPluginReturnCallback),
        .init(name: "clearWatch", returnType: CAPPluginReturnPromise),
        .init(name: "checkPermissions", returnType: CAPPluginReturnPromise),
        .init(name: "requestPermissions", returnType: CAPPluginReturnPromise)
    ]

    @objc func getCurrentPosition(_ call: CAPPluginCall) { reject(call) }
    @objc func watchPosition(_ call: CAPPluginCall) { reject(call) }
    @objc func clearWatch(_ call: CAPPluginCall) { call.resolve() }

    @objc override public func checkPermissions(_ call: CAPPluginCall) {
        call.resolve(["location": "denied", "coarseLocation": "denied"])
    }

    @objc override public func requestPermissions(_ call: CAPPluginCall) { reject(call) }

    private func reject(_ call: CAPPluginCall) {
        call.reject("Geolocation is not available on Mac Catalyst.", "OS-PLUG-GLOC-0007")
    }
}
#else
''', plugin)
for name in ("GeolocationCallbackManager.swift", "IONGLOCPositionModel+JSONTransformer.swift"):
    if os.path.isfile(os.path.join(d, name)):
        wrap("#if targetEnvironment(macCatalyst)\nimport Capacitor\n// GPX_CATALYST_GEO_STUB\n#else\n", os.path.join(d, name))
print("  geolocation: Catalyst stub in place")
PY

echo "── 3/3 generate the Podfile r.yml builds from"
# ── Keep @capacitor/filesystem linkable for Mac — r.yml `Catalyst Pods` ──
# v7+ depends on IONFilesystemLib, a PREBUILT .xcframework whose Info.plist
# lists ios-arm64 and ios-arm64_x86_64-simulator and nothing else, so it can
# never link for Catalyst; v6 is pure Swift (`import Capacitor` only) and does.
# r.yml pins v6 instead of amputating the feature, so the pod verified here must
# be v6 too — the measurement at the top is what skipping this looked like.
# Only here: after `npm ci`, which would reinstall the package.json range, and
# before the Podfile is written.
if [ -f node_modules/@capacitor/filesystem/package.json ]; then
  FS_VER=$(node -p 'require("./node_modules/@capacitor/filesystem/package.json").version' 2>/dev/null || echo "")
  FS_MAJOR="${FS_VER%%.*}"
  if [ -n "$FS_MAJOR" ] && [ "$FS_MAJOR" -ge 7 ] 2>/dev/null; then
    echo "  @capacitor/filesystem $FS_VER cannot link for Mac Catalyst (IONFilesystemLib.xcframework has no maccatalyst slice) — pinning v6, as r.yml does"
    npm install @capacitor/filesystem@^6.0.4 --legacy-peer-deps ||
      echo "  ⛔ filesystem downgrade FAILED — the pod will be stripped below, as r.yml strips it"
  fi
fi
# r.yml `Build App` -> prepare_geolocation_for_catalyst, before every Catalyst
# build: IONGeolocationLib leaves the podspec (step 2/3 stubbed the Swift that imports it).
python3 - <<'PY'
p = "node_modules/@capacitor/geolocation/CapacitorGeolocation.podspec"
try:
    lines = open(p).read().splitlines(True)
except OSError:
    raise SystemExit(0)
kept = [l for l in lines if "IONGeolocationLib" not in l]
if len(kept) != len(lines):
    open(p, "w").write("".join(kept))
    print("  geolocation: IONGeolocationLib dropped from the podspec")
PY
python3 - <<'PY'
import os, re
ios_target = os.environ["IOS_TARGET"]
podfile = "ios/App/Podfile"

def drop(text, needle):
    return "".join(l for l in text.splitlines(True) if needle not in l)

if os.path.exists(podfile):
    # A committed Podfile (ten repos keep one) is r.yml's starting point too:
    # `cap sync` refreshed its plugin list and `iOS Target` rewrites only the
    # platform line. Generating over it would drop whatever else it carries.
    text = re.sub(r"platform :ios, '[0-9.]*'", "platform :ios, '%s'" % ios_target, open(podfile).read())
    print("  starting from the committed Podfile")
else:
    # r.yml's rule, not a better one: Capacitor and CapacitorCordova, then every
    # podspec at ANY depth under node_modules whose path mentions capacitor or
    # revenuecat — its `find` descends into a dependency's own node_modules and
    # passes over podspecs that mention neither.
    specs = []
    for root, dirs, files in os.walk("node_modules"):
        for f in files:
            if f.endswith(".podspec") and ("capacitor" in os.path.join(root, f) or "revenuecat" in os.path.join(root, f)):
                if f[:-len(".podspec")] not in ("Capacitor", "CapacitorCordova"):
                    specs.append("  pod '%s', :path => '../../%s'" % (f[:-len(".podspec")], root))
    text = "\n".join(["platform :ios, '15.0'", "target 'App' do", "  use_frameworks!",
                      "  pod 'Capacitor', :path => '../../node_modules/@capacitor/ios'",
                      "  pod 'CapacitorCordova', :path => '../../node_modules/@capacitor/ios'"]
                     + sorted(specs) + ["end"]) + "\n"

try:
    still_ion = "IONFilesystemLib" in open("node_modules/@capacitor/filesystem/CapacitorFilesystem.podspec").read()
except OSError:
    still_ion = False
if still_ion:
    # r.yml's fallback when the v6 pin did not take effect.
    print("  ⛔⛔⛔ @capacitor/filesystem is STILL v7+: stripping IONFilesystemLib and CapacitorFilesystem.")
    print("  ⛔⛔⛔ EVERY Filesystem call in this binary will fail at runtime (\"Filesystem\" plugin is not implemented on ios).")
    text = drop(drop(text, "IONFilesystemLib"), "CapacitorFilesystem")
# r.yml strips Google Mobile Ads from every Catalyst Podfile: it does not link
# for Mac Catalyst. Six Capacitor repos depended on it on 2026-09-10.
for needle in ("Google-Mobile-Ads-SDK", "GoogleUserMessagingPlatform", "CapacitorCommunityAdmob"):
    text = drop(text, needle)

# r.yml deletes any existing post_install (sed '/^post_install/,/^end$/d') and
# appends its own. Signing lives here, not in Pods.xcodeproj: any later
# pod install regenerates that project and would throw it away.
out, inside = [], False
for line in text.splitlines(True):
    if not inside and line.startswith("post_install"):
        inside = True
    if inside:
        inside = line.rstrip("\n") != "end"
        continue
    out.append(line)
text = "".join(out) + """
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings["SUPPORTS_MACCATALYST"] = "YES"
      config.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "%s"
      config.build_settings["CODE_SIGN_IDENTITY"] = ""
      config.build_settings["CODE_SIGN_STYLE"] = "Manual"
      config.build_settings["CODE_SIGNING_REQUIRED"] = "NO"
      config.build_settings["CODE_SIGNING_ALLOWED"] = "NO"
    end
  end
end
""" % ios_target
open(podfile, "w").write(text)
print("  pods: " + ", ".join(re.findall(r"^\s*pod '([^']+)'", text, flags=re.M)))
PY

# r.yml `Stripped Plugin Guard`. A pod stripped above whose package src/ still
# imports ships a binary in which every call to it fails at runtime, and r.yml
# STOPS the publish build there. The strip alone would build on and verify an
# app that cannot ship. Same plain-text test and MAC-STRIPPED-OK opt-out as
# r.yml, so the two cannot disagree — including where r.yml is wrong: a comment
# that merely names the package trips it (dng-to-jpg's src/lib/config.ts did on
# 2026-09-10). dbf.yml is the copy that matches imports instead.
STRIPPED=0
guard() {
  local pkg="$1" pod="$2" offenders="" f
  grep -qs "pod '$pod'" ios/App/Podfile && return 0
  # Word-split exactly as r.yml's guard does, file names included.
  # shellcheck disable=SC2013
  for f in $(grep -rls --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.vue' "$pkg" src/ 2>/dev/null); do
    grep -q "MAC-STRIPPED-OK" "$f" || offenders="$offenders $f"
  done
  [ -z "$offenders" ] && return 0
  echo "  ⛔ $pkg is imported by src/ but $pod is not in the Podfile for this build, so the binary ships WITHOUT it and every call fails at runtime with '\"plugin is not implemented on ios\"' — on Mac and on iPhone. r.yml stops the publish build here. Offending files:$offenders"
  STRIPPED=1
}
guard "@capacitor/filesystem" "CapacitorFilesystem"
guard "@capacitor-community/admob" "CapacitorCommunityAdmob"
if [ "$STRIPPED" = 1 ]; then
  echo "  Fix options: (a) let the v6 pin work, (b) write through your own native plugin method (pattern: mht-viewer-converter MHTEnginePlugin.writeCacheFile + src/lib/cache-file.ts), (c) build this app without Mac."
  exit 1
fi
( cd ios/App && pod install )

# A project with its own base xcconfig stops CocoaPods linking its own.
for cfg in debug release; do
  f="ios/$cfg.xcconfig"
  [ -f "$f" ] || continue
  grep -q "Pods-App.$cfg.xcconfig" "$f" || \
    printf '#include "App/Pods/Target Support Files/Pods-App/Pods-App.%s.xcconfig"\n%s\n' \
      "$cfg" "$(cat "$f")" > "$f"
done
# Xcode 15+ rejects DT_TOOLCHAIN_DIR in LIBRARY_SEARCH_PATHS.
find ios/App/Pods -name "*.xcconfig" -exec sed -i '' 's/DT_TOOLCHAIN_DIR/TOOLCHAIN_DIR/g' {} \;
echo "── ready for the build r.yml ships: xcodebuild -workspace ios/App/App.xcworkspace -scheme App -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' ARCHS=\"arm64 x86_64\" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build"
