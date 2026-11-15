#!/usr/bin/env python3
# Two cheap structural checks for Swift files, for the pre-commit hook.
#
# There is no Swift compiler on the machine that runs these commits, so this
# cannot type-check anything, and a hand-rolled Swift parser would produce
# enough noise to be worse than nothing. These two checks are the mechanical
# leftovers a line-editing script or a careless merge leaves behind, and neither
# can misfire on real Swift:
#
# 1. Brace balance, with comments and string literals stripped. A stray closing
#    brace makes CI report a cascade of unrelated errors: "extraneous brace",
#    "static methods may only be declared on a type".
# 2. A raw string opened with the single-line delimiter on a line it does not
#    close. A multi-line raw string needs the triple-quote form, and the
#    single-line form swallows the rest of the file's syntax.
#
# Usage: check-swift-structure.py FILE [FILE ...]
import re
import sys

TRIPLE_RAW = re.compile(r'#"""')


def strip_noise(src: str) -> str:
    # Remove comments and string literals so brace counting is honest. Raw brace
    # counting lies: doc comments hold JSON examples with braces, and diagnostics
    # hold escaped quotes and interpolations.
    out = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    out = re.sub(r"//[^\n]*", "", out)
    out = re.sub(r'#"""[\s\S]*?"""#', '""', out)
    out = re.sub(r'"""[\s\S]*?"""', '""', out)
    return re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', out)


def check(path: str) -> list[str]:
    problems: list[str] = []
    src = open(path, encoding="utf-8").read()

    depth = 0
    for index, line in enumerate(strip_noise(src).split("\n"), start=1):
        depth += line.count("{") - line.count("}")
        if depth < 0:
            problems.append(f"{path}:{index}: extra closing brace at top level")
            depth = 0
    if depth != 0:
        problems.append(f"{path}: unbalanced braces, {depth} level(s) still open at end of file")

    for index, line in enumerate(src.split("\n"), start=1):
        # A single-line raw literal must open and close on the same line. The
        # triple-quote form is the legal multi-line one, so it is exempt.
        if '#"' in line and '"#' not in line and not TRIPLE_RAW.search(line):
            problems.append(
                f"{path}:{index}: a raw string opens here without closing on the same line; "
                'a multi-line raw string needs the #""" ... """# form'
            )

    return problems


def main() -> int:
    problems = [problem for path in sys.argv[1:] for problem in check(path)]
    for problem in problems:
        print(problem)
    if not problems:
        print("Swift files are brace-balanced and use raw strings correctly.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
