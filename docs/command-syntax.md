# Command text and explicit keys

New commands offer **Text** and **Text + keys**.

## Text

Everything is typed literally, including `Enter`, `<Enter>`, brackets and
backslashes. Line breaks are real Enter taps. No escape processing occurs.

## Text + keys

Ordinary text remains text, including the word `Enter`, `Ctrl+V`, `F5`, comments
starting with `#`, whitespace and newlines. Only explicit angle markers are keys:

- `<Enter>` — press Enter.
- `<Ctrl+V>` — press Ctrl+V (capitalization does not add Shift).
- `<Ctrl+Shift+Esc>`, `<F5>`, `<Tab>` — other existing key/combo names.
- `<Del>` / `<Delete>` — forward deletion (HID `0x4C`).
- `<Backspace>` / `<⌫>` — backward deletion (HID `0x2A`).
- `<Ctrl+Alt+Del>` — Ctrl+Alt+Delete, with the same forward Delete key.
- `hello<Enter>world` — type hello, press Enter, type world.
- A real newline also presses Enter; formatting lines are not ignored.

Escapes:

| Input | Typed result |
| --- | --- |
| `\<Enter>` | literal `<Enter>` |
| `\<` | literal `<` |
| `\>` | literal `>` |
| `\\` | literal backslash |

Only those three backslash escapes are special. Paths such as `C:\Temp` and
`C:\new` keep their backslashes. A trailing backslash is literal. To type a literal
backslash immediately followed by a key marker, use `\\<Enter>`.

Unpaired `<` or `>` are literal. A key marker cannot cross a newline. A paired but
invalid marker, such as `<Bogus>`, is an error: saving/sending is blocked, never
silently reduced to a partial command. Escape the opening bracket to type a
literal paired expression such as `\<html>` or `\<1+1>`.

Key names/modifiers are case-insensitive and allow surrounding whitespace.
Within a marker the same escapes allow bracket keys, e.g. `<Ctrl+\>>`.
The host keyboard-layout behavior and unsupported-character checks are shared
with the existing input planners; HID does not report the actual host layout.

## Existing keys commands

The persisted syntax value `keys` retains its exact line-based behavior: `Enter`
on its own line is a key, `#` comments/blank lines are skipped, and line separators
do not automatically type Enter. Existing commands are not migrated or rewritten.

Correction in 3.3.27: `Del` previously mapped incorrectly to Backspace in the
parser. It now means forward Delete in both mixed and legacy syntax, matching
`Delete` and the on-screen keyboard. If a saved command relied on that bug, use
`Backspace` or `⌫` explicitly for backward deletion.

When editing one, **Keys (legacy)** remains available for that edit session,
even after selecting another mode. New commands do not offer the legacy mode.
Selecting Text + keys is an explicit reinterpretation of the body: rewrite old
bare key names using `<...>` when switching modes.
