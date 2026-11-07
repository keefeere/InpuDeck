#!/bin/bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# These SwiftUI views belong to no pull-request test target, so nothing parses
# them before `xcodebuild` spends its time on them: an argument-order mistake in
# RemoteKeyboardView once failed the release build ten minutes in. A frontend
# parse cannot resolve types, but it does reject unbalanced braces, misplaced
# modifiers and malformed literals within seconds, so the release workflow can
# fail before the full build.
files=(
  "InpuDeck/ContentView.swift"
  "InpuDeck/RemoteKeyboardView.swift"
  "InpuDeck/TrackpadView.swift"
  "InpuDeck/ConnectionStatusView.swift"
  "InpuDeck/CodeScannerView.swift"
  "InpuDeck/InpuDeckApp.swift"
)

for file in "${files[@]}"; do
  test -f "$repo_root/$file" || { echo "missing $file"; exit 1; }
  xcrun swiftc -frontend -parse "$repo_root/$file"
  echo "parsed $file"
done
