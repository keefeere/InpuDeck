#!/bin/bash
set -Eeuo pipefail

# The pull-request and release jobs run this from the repository root, so no path
# arithmetic is involved. The check keeps a manual run from silently parsing
# nothing.
test -d InpuDeck -a -d Shared || { echo "run from the repository root"; exit 1; }

# Most app and shared sources belong to no pull-request test target, so nothing
# parses them before `xcodebuild` spends its time on them: an argument-order
# mistake in RemoteKeyboardView once failed the release build ten minutes in, and
# a malformed optional chain in PressableKeyButton only surfaced in the simulator
# job. A frontend parse cannot resolve types, but it does reject unbalanced
# braces, misplaced modifiers, malformed literals and broken optional chaining.
# Every source is parsed here unless a cheaper gate already compiles it fully
# (scripts/test-press-actions.sh, scripts/test-direct-hid.sh).
compiled_by_other_gates=(
  "InpuDeck/KeyboardSwipePointer.swift"
  "InpuDeck/PressableKeyButton.swift"
  "InpuDeck/EdgeTabNavigation.swift"
  "InpuDeck/ShortAndLongPressButtonStyle.swift"
  "Shared/Localization.swift"
)

skip() {
  local file="$1" other
  for other in "${compiled_by_other_gates[@]}"; do
    [[ "$file" == "$other" ]] && return 0
  done
  return 1
}

found=0
while IFS= read -r -d '' path; do
  file="$path"
  skip "$file" && continue
  found=$((found + 1))
  xcrun swiftc -frontend -parse "$path"
  echo "parsed $file"
done < <(find InpuDeck Shared -name '*.swift' -print0 | sort -z)

test "$found" -gt 0 || { echo "no sources found"; exit 1; }
echo "parsed $found source files"
