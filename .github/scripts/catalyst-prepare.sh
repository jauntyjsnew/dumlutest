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
# This does the same three things the publish workflows do, to a TEMPORARY
# checkout. It never runs against a developer's tree.
set -euo pipefail
cd "${1:?usage: catalyst-prepare.sh <project-dir>}"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8   # pod install dies on ASCII-8BIT otherwise

echo "── web assets"
npm ci --legacy-peer-deps || npm install --legacy-peer-deps
npm run build
npx cap copy ios

gem list -i xcodeproj >/dev/null 2>&1 || sudo gem install xcodeproj --no-document

echo "── 1/3 turn Mac Catalyst on, and drop the SPM product"
ruby -e '
  require "xcodeproj"
  proj = Xcodeproj::Project.open("ios/App/App.xcodeproj")
  app = proj.targets.find { |t| t.name == "App" } or abort "no App target"
  app.build_configurations.each do |c|
    c.build_settings["SUPPORTS_MACCATALYST"] = "YES"
    c.build_settings["SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD"] = "NO"
    c.build_settings["DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER"] = "NO"
  end
  app.package_product_dependencies.clear if app.respond_to?(:package_product_dependencies)
  proj.root_object.package_references.clear
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

echo "── 2/3 patch RevenueCat for Catalyst"
# ⛔ Defensive. If the SDK moved the call, FAIL — an unpatched build breaks at
# link time and the reason is found days later.
python3 - <<'PY'
import glob, sys
hits = [h for h in glob.glob("node_modules/@revenuecat/purchases-capacitor/ios/**/PurchasesPlugin.swift", recursive=True)]
if not hits:
    sys.exit("  RevenueCat plugin source not found — the patch target moved")
p = hits[0]
s = open(p).read()
target = ("        if #available(iOS 14.0, *) {\n"
          "            CommonFunctionality.presentCodeRedemptionSheet()\n"
          "        }")
if "#if !targetEnvironment(macCatalyst)\n" + target in s:
    print("  already patched"); sys.exit(0)
if target not in s:
    sys.exit("  RevenueCat patch target not found — refusing to produce an unpatched Catalyst build")
open(p, "w").write(s.replace(target,
    "        #if !targetEnvironment(macCatalyst)\n" + target + "\n        #endif"))
print("  patched")
PY

echo "── 3/3 generate a Podfile from what the project actually depends on"
python3 - <<'PY'
import glob, os
pods = []
for s in sorted(glob.glob("node_modules/**/*.podspec", recursive=True)):
    if s.count("node_modules") > 1:      # a dependency's own dependency
        continue
    pods.append((os.path.basename(s)[:-len(".podspec")], "../../" + os.path.dirname(s)))
if not pods:
    raise SystemExit("  no podspecs found — cannot build for Catalyst without CocoaPods")
body = "\n".join("  pod %r, :path => %r" % (n, p) for n, p in pods)
open("ios/App/Podfile", "w").write("""platform :ios, '15.0'
use_frameworks!
install! 'cocoapods', :disable_input_output_paths => true
target 'App' do
%s
end
post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |c|
      c.build_settings['SUPPORTS_MACCATALYST'] = 'YES'
      c.build_settings['DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER'] = 'NO'
      c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
      c.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
      c.build_settings['CODE_SIGNING_REQUIRED'] = 'NO'
      c.build_settings['CODE_SIGN_IDENTITY'] = ''
    end
  end
end
""" % body)
print("  pods: " + ", ".join(n for n, _ in pods))
PY
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
echo "── ready for: xcodebuild -workspace ios/App/App.xcworkspace -destination 'platform=macOS,variant=Mac Catalyst'"
