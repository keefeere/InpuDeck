# Validation hooks and static checks

CI is the only Swift compiler in this project, so it reports ordinary syntax
mistakes late: after a release tag is already pushed, and as a cascade of errors
that name the wrong file. A stray closing brace in the remote template produced
"extraneous `}`", "static methods may only be declared on a type", "consecutive
statements on a single line", and "invalid redeclaration of `RemoteTemplateDecoder`"
- none of which named the brace.

These checks run on the machine doing the commit, where no Swift exists. They are
deliberately narrow: each is a mechanical leftover that a line-editing script or a
careless merge leaves behind, and each existed because a real commit here got it
wrong. Anything broader would need real Swift parsing, and a hand-rolled parser
that produces false positives is worse than no checker.

## Install

```bash
git config core.hooksPath scripts/hooks
```

Hooks are opt-in so a clone is not silently changed. Escape hatch for a deliberate
bypass: `HOOK_SKIP=1 git commit ...`, or `HOOK_SKIP_SWIFT=1` to skip unit tests when
a local `swiftc` exists.

## Checks

| Script | Checks | Why |
| --- | --- | --- |
| `scripts/check-swift-structure.py` | brace balance after comments and string literals are stripped; a raw string opened with the single-line delimiter on a line it does not close | the brace above, and `#"{"a":1},` spanning lines, which swallowed the rest of the file |
| `scripts/check-remote-template.py` | the shipped template's grid is fully covered and every named key/usage resolves to a declared code | the bundled file is the only template in v1, so a bad cell is a dead button on the sofa, not a CI failure |
| `scripts/check-doc-citations.py` | every `path:line` citation in `docs/*.md` points at a non-empty line that exists | docs once quoted a stale `ContentView` line for the pointer guard, while the guard had already moved |
| `scripts/check-test-registration.py` | every `Tests/*Tests.swift` appears in `scripts/test-direct-hid.sh` | that script lists each test binary explicitly, so an unregistered file never compiles or runs |

## Rules the hooks enforce

- **A tab change needs its test in the same commit.** `AppTab` is declared in
  `Shared/AppTabConfiguration.swift:3`; the tab-configuration tests assert the exact
  order, so a new tab without the paired test edit fails the release test script.
- **A version bump needs a release marker.** `scripts/hooks/commit-msg` compares the
  staged `MARKETING_VERSION` with `HEAD` and requires `release-tag-<version>` in the
  message. `auto-release-tag.yml` tags only commits carrying that marker, and the
  workflow reports nothing when a push matches none, so "all checks green" can mean
  "no release happened".
- **`sidestore-source.json` is normally written by the release workflow.** Staging it
  manually is warned about, not blocked, because correcting an already-published
  release is a legitimate case.
- **Localization gate.** Any commit touching `.strings` or Swift runs
  `scripts/test-localizations.sh`, the same gate CI runs.
- **Real Swift tests**, when a local `swiftc` exists: `scripts/test-direct-hid.sh`.

## What they cannot do

They do not type-check, resolve Swift names, or prove Bluetooth and webOS behavior.
A green pre-commit hook means the file is structurally plausible, not that it
compiles, and CI is still the first real compile. Device behavior still needs the
maintainer's phone and TV.
