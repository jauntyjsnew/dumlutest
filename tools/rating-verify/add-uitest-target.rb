#!/usr/bin/env ruby
# Throwaway-worktree only: add a UI test bundle + a shared "VerifyUI" scheme to an iOS app project,
# so XCUITest can drive the real app in the simulator headlessly (no host screen, no taps via
# CGEvent). Never committed.
# usage: add-uitest-target.rb <project.xcodeproj> <app-target> <tests-dir-relative-to-project-dir>
require 'xcodeproj'

proj_path, app_name, tests_dir = ARGV
abort 'usage: add-uitest-target.rb <xcodeproj> <app-target> <tests-dir>' unless proj_path && app_name && tests_dir
proj = Xcodeproj::Project.open(proj_path)
app = proj.targets.find { |t| t.name == app_name } or abort "no target #{app_name}"
name = 'VerifyUITests'
if proj.targets.any? { |t| t.name == name }
  puts 'UI test target already present'
else
  deployment = app.build_configurations.first.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] || '15.0'
  t = proj.new_target(:ui_test_bundle, name, :ios, deployment, nil, :swift)
  t.add_dependency(app)
  group = proj.main_group.find_subpath(tests_dir, true)
  group.set_source_tree('SOURCE_ROOT')
  group.set_path(tests_dir)
  Dir.glob(File.join(File.dirname(proj_path), tests_dir, '*.swift')).sort.each do |f|
    ref = group.new_reference(File.basename(f))
    t.add_file_references([ref])
  end
  t.build_configurations.each do |c|
    s = c.build_settings
    s['TEST_TARGET_NAME'] = app_name
    s['PRODUCT_BUNDLE_IDENTIFIER'] = 'tools.rush.verify.uitests'
    s['PRODUCT_NAME'] = name
    s['GENERATE_INFOPLIST_FILE'] = 'YES'
    s['SWIFT_VERSION'] = '5.0'
    s['CODE_SIGN_STYLE'] = 'Manual'
    s['CODE_SIGN_IDENTITY'] = '-'
    s['DEVELOPMENT_TEAM'] = ''
    s['CODE_SIGNING_REQUIRED'] = 'NO'
    s['TARGETED_DEVICE_FAMILY'] = '1,2'
    # ⛔ Do not inherit the app's pod linkage. A UI test bundle is loaded into its OWN runner app,
    # which carries none of the app's embedded frameworks. When a Podfile has no explicit target
    # block, CocoaPods applies its xcconfig at the PROJECT level, so a target created afterwards
    # inherits OTHER_LDFLAGS full of -framework flags; the bundle then links the app's dynamic pods
    # and dyld cannot resolve a single one of them. Measured on dng-to-jpg: 11 @rpath dependencies
    # (Capacitor, CapacitorApp, CapacitorRateApp, CapacitorShare, CapawesomeCapacitorFilePicker,
    # Cordova, PurchasesHybridCommon, RevenueCat, ...) and "Failed to load the test bundle", with no
    # reason in the log. XCTest itself comes from the target type, not from these flags.
    s['OTHER_LDFLAGS'] = ''
    s['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks @loader_path/Frameworks'
  end
  proj.save
  puts "added #{name} (deployment #{deployment})"
end
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app, proj.targets.find { |x| x.name == name })
scheme.test_action.build_configuration = 'Debug'
scheme.save_as(proj_path, 'VerifyUI', true)
puts 'shared scheme VerifyUI saved'
