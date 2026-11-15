#!/usr/bin/env python3
# Checks that every Swift unit-test file is compiled by scripts/test-direct-hid.sh.
#
# That script lists each test binary explicitly, so a new Tests/*Tests.swift is
# silently unrun unless a block is added — which is exactly how the remote
# template tests nearly shipped untested. CI is the only Swift compiler here, so
# a forgotten block is invisible until a release build.
#
# Usage: check-test-registration.py
import glob
import os
import re
import sys

SCRIPT = "scripts/test-direct-hid.sh"


def main() -> int:
    if not os.path.isfile(SCRIPT):
        print(f"{SCRIPT} is missing")
        return 1
    script = open(SCRIPT, encoding="utf-8").read()
    missing = [
        path for path in sorted(glob.glob("Tests/*Tests.swift"))
        if os.path.basename(path) not in script
    ]
    for path in missing:
        print(f"{SCRIPT} never compiles {path}")
    if missing:
        print("Add a swiftc block for each file above, or remove the file.")
        return 1
    print("Every Swift unit-test file is registered in the release test script.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
