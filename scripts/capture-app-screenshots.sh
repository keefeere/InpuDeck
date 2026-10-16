#!/bin/bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/inpudeck-app-screenshots.XXXXXX")"
simulator_id=""
cleanup() {
  if [[ -n "$simulator_id" ]]; then
    xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true
  fi
  rm -rf "$test_root"
}
trap cleanup EXIT

# Create a fresh device: never overwrite anyone's existing simulator commands
# or preferences. Use a device type/runtime pair already known to be available.
read -r device_type runtime < <(xcrun simctl list devices available -j | python3 -c '
import json, sys
pairs = [(d, runtime) for runtime, devices in json.load(sys.stdin)["devices"].items()
         if "iOS" in runtime for d in devices if d["name"].startswith("iPhone")]
if not pairs:
    sys.exit("No available iPhone simulator")
pairs.sort(key=lambda pair: pair[0]["name"] != "iPhone 17 Pro")
device, runtime = pairs[0]
print(device["deviceTypeIdentifier"], runtime)
')
simulator_id="$(xcrun simctl create "InpuDeck Docs $(basename "$test_root")" "$device_type" "$runtime")"
xcrun simctl boot "$simulator_id"
xcrun simctl bootstatus "$simulator_id" -b
xcrun simctl ui "$simulator_id" appearance dark
xcrun simctl status_bar "$simulator_id" override --time '9:41' \
  --batteryState charged --batteryLevel 100 --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4
mkdir -p "$repo_root/dist"

# Build the real app/extension with the production Xcode project, not a copied
# screen or a fake transport. Simulator screenshots intentionally show offline.
xcodebuild \
  -project "$repo_root/InpuDeck.xcodeproj" -scheme InpuDeck \
  -configuration Debug -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$test_root/ProductionDerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM='' \
  build 2>&1 | tee "$repo_root/dist/app-screenshot-build.log"
app_path="$test_root/ProductionDerivedData/Build/Products/Debug-iphonesimulator/InpuDeck.app"
xcrun simctl install "$simulator_id" "$app_path"
container="$(xcrun simctl get_app_container "$simulator_id" com.keefeere.InpuDeck data)"
python3 - "$container" "$repo_root/dist" "$app_path" "$device_type" "$runtime" "$(git -C "$repo_root" rev-parse HEAD)" <<'PY'
import json, plistlib, sys, uuid
from pathlib import Path
container, output, app = map(Path, sys.argv[1:4])
preferences = container / 'Library/Preferences/com.keefeere.InpuDeck.plist'
preferences.parent.mkdir(parents=True, exist_ok=True)
preferences.write_bytes(plistlib.dumps({
    'expertMode': False,
    'inputTransportMode': 'bluetooth',
    'targetKeyboardLayout': 'englishUS',
    'tabConfiguration': json.dumps({'order': ['commands', 'input', 'keyboard', 'tools'], 'hidden': []}),
}))
commands = container / 'Library/Application Support/InpuDeck/commandlets.json'
commands.parent.mkdir(parents=True, exist_ok=True)
examples = [
    ('Find and select', '<Ctrl+F>InpuDeck<Enter><Home><Shift+End>'),
    ('Copy and paste', '<Ctrl+C><Alt+Tab><Ctrl+V>'),
    ('Task Manager', '<Ctrl+Shift+Esc>'),
    ('Refresh', '<F5>'),
]
commands.write_text(json.dumps([
    {'id': str(uuid.uuid5(uuid.NAMESPACE_URL, 'inpudeck-docs/' + name)),
     'name': name, 'syntax': 'mixed', 'body': body}
    for name, body in examples
]))
info = plistlib.loads((app / 'Info.plist').read_bytes())
(output / 'app-screenshot-provenance.json').write_text(json.dumps({
    'version': info['CFBundleShortVersionString'],
    'build': info['CFBundleVersion'],
    'sourceCommit': sys.argv[6], 'deviceType': sys.argv[4], 'runtime': sys.argv[5],
    'application': 'production InpuDeck.xcodeproj/InpuDeck',
    'transport': 'offline simulator; no Bluetooth connection is fabricated',
    'data': 'synthetic public demo commands; no personal host or secret data',
}, indent=2) + '\n')
PY

cp "$repo_root/Tests/AppScreenshots/"* "$test_root/"
xcodegen generate --spec "$test_root/project.yml"
rm -rf "$repo_root/dist/app-screenshots.xcresult" "$repo_root/dist/app-screenshot-attachments" "$repo_root/dist/app-screenshots"
set +e
xcodebuild test \
  -project "$test_root/AppScreenshots.xcodeproj" -scheme ScreenshotRunnerHost \
  -destination "platform=iOS Simulator,id=$simulator_id" -parallel-testing-enabled NO \
  -derivedDataPath "$test_root/TestDerivedData" \
  -resultBundlePath "$repo_root/dist/app-screenshots.xcresult" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$repo_root/dist/app-screenshot-tests.log"
result=${PIPESTATUS[0]}
set -e
if [[ -d "$repo_root/dist/app-screenshots.xcresult" ]]; then
  xcrun xcresulttool export attachments --path "$repo_root/dist/app-screenshots.xcresult" \
    --output-path "$repo_root/dist/app-screenshot-attachments"
fi
if [[ "$result" != 0 ]]; then exit "$result"; fi
python3 - "$repo_root/dist" <<'PY'
import json, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
attachments = root / 'app-screenshot-attachments'
output = root / 'app-screenshots'
output.mkdir(exist_ok=True)
required = {'input-portrait', 'keyboard-portrait', 'keyboard-landscape', 'tools-landscape',
            'commands-portrait', 'commands-editor', 'commands-legend', 'tabs-settings-portrait'}
found = set()
for test in json.loads((attachments / 'manifest.json').read_text()):
    for item in test['attachments']:
        name = item['suggestedHumanReadableName'].split('_', 1)[0]
        if not name.startswith('docs-'):
            continue
        name = name.removeprefix('docs-')
        if name not in required:
            continue
        subprocess.run(['sips', '-s', 'format', 'png', '-Z', '1600',
                        str(attachments / item['exportedFileName']),
                        '--out', str(output / (name + '.png'))], check=True)
        found.add(name)
if found != required:
    sys.exit('Missing documentation screenshots: ' + ', '.join(sorted(required - found)))
print('Captured all eight production app screenshots.')
PY
