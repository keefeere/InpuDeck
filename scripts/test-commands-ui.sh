#!/bin/bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/inpudeck-commands-ui.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

cp "$repo_root/Tests/CommandsUI/"* "$test_root/"
for source in CommandPalettePage CommandPaletteView Commandlet ShortAndLongPressButtonStyle; do
  cp "$repo_root/InpuDeck/$source.swift" "$test_root/"
done
for source in CommandUnlockState HID KeyComboParser MixedCommandParser TextTypingPlanner Localization; do
  cp "$repo_root/Shared/$source.swift" "$test_root/"
done
xcodegen generate --spec "$test_root/project.yml"

simulator_id="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device["name"].startswith("iPhone"):
            print(device["udid"])
            sys.exit(0)
sys.exit("No available iPhone simulator")
')"
xcrun simctl boot "$simulator_id" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simulator_id" -b
# This path contains only generated test output. xcodebuild refuses to replace
# a previous result bundle, so make local reruns safe.
mkdir -p "$repo_root/dist"
rm -rf "$repo_root/dist/commands-ui.xcresult"
xcodebuild test \
    -project "$test_root/CommandsUITests.xcodeproj" \
    -scheme CommandsHost \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -parallel-testing-enabled NO \
    -derivedDataPath "$test_root/DerivedData" \
    -resultBundlePath "$repo_root/dist/commands-ui.xcresult" \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "$repo_root/dist/commands-ui-tests.log"
