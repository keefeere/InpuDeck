#!/usr/bin/env python3
# Checks that `path:line` citations in docs/*.md still point at a real line.
#
# Docs quote line numbers from code, so they rot: this session cited
# ContentView.swift:1105 for the pointer guard, and after an earlier edit that
# line was a completely different declaration. A citation is cheap to verify and
# cheap to keep honest, so the hook verifies it instead of trusting memory.
#
# Usage: check-doc-citations.py [DOC ...]   (defaults to docs/*.md)
import glob
import os
import re
import sys

CITATION = re.compile(r"([A-Za-z0-9_./-]+\.(?:swift|md|ino|py|sh|json|strings|yml)):(\d+)")


def check(doc: str) -> list[str]:
    problems: list[str] = []
    text = open(doc, encoding="utf-8").read()
    root = os.getcwd()
    for path, line in ((m.group(1), int(m.group(2))) for m in CITATION.finditer(text)):
        full = os.path.join(root, path)
        if not os.path.isfile(full):
            # A citation may name just the basename (docs quote esp32-bridge/... in
            # prose), so resolve the basename before calling the citation stale.
            matches = glob.glob(os.path.join(root, "**", os.path.basename(path)), recursive=True)
            if len(matches) != 1:
                problems.append(f"{doc}: cites {path}:{line}, but {path} does not exist")
                continue
            full = matches[0]
        lines = open(full, encoding="utf-8").read().split("\n")
        if line > len(lines):
            problems.append(f"{doc}: cites {path}:{line}, but the file has {len(lines)} lines")
        elif not lines[line - 1].strip():
            problems.append(f"{doc}: cites {path}:{line}, which is an empty line")
    return problems


def main() -> int:
    docs = sys.argv[1:] or sorted(glob.glob("docs/*.md"))
    problems = [problem for doc in docs for problem in check(doc)]
    for problem in problems:
        print(problem)
    if not problems:
        print("Every file:line citation in the docs points at a real line.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
