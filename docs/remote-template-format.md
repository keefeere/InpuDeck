# Template format manual

A **template** is a JSON file that defines the TV remote screen: a grid of
cells, one control per cell, each cell carrying a label and the HID action
it performs. The remote screen renders exactly what the file says, so a
template is the whole specification of the remote — no pixel layout, no colors,
no font sizes.

This manual documents the format. It is self-contained: a template written from
this page works without reading any other documentation. Device-specific
verified facts (what the maintainer's C1 actually acted on, the LG keycode
table) live in [`docs/tv-remote.md`](tv-remote.md) and are not needed to write
a template.

## Where a template comes from

| Source | How it gets there |
| --- | --- |
| the bundled default | shipped in the app bundle as `RemoteTemplate.tv-default.json`; always present and never deletable |
| an imported file | copied into the app's Documents directory as `RemoteTemplates/<id>.json` via the Settings screen (`Шаблони пульта` → `Імпортувати шаблон`); can also be dropped in by the user in the Files app and imported |

Import goes through the same decoder that renders the remote. A file that does
not load changes nothing on screen — only its reason is shown. The id `tv-default`
is refused on import, so an imported file can never shadow the shipped remote.

A per-host selection (`UserDefaults` key `remoteTemplate.selected.<host key>`)
chooses which template a connected TV draws. The host key is the transport plus
the connected device, e.g. `esp:<bridge uuid>` or `direct:<host uuid>`.
Choosing the bundled id clears the key; deleting a template clears every
selection that pointed at it; an unknown id falls back to the bundled template.

## Top level

```jsonc
{
  "formatVersion": 1,        // required; any other value → refuse the file
  "id": "my-tv",             // required, stable; the user picks by this id
  "name": "My TV",           // required, the title shown by the picker
  "columns": 5,              // required, integer 3..6
  "rows": 4,                  // required, integer 3..10
  "cells": [ /* see below */ ]
}
```

## Cell

```jsonc
{
  "id": "mute",              // required, unique within the template
  "row": 1, "col": 1,       // required, 1-based, inside the grid
  "rowSpan": 1,              // optional, default 1
  "colSpan": 1,              // optional, default 1
  "control": "button",      // button | dpad | rocker | spacer
  "label": "Тиша",          // see "Labels"
  "tone": "plain",          // plain | prominent
  "press": "tap",           // tap | hold
  "scale": 1.0,             // optional, 0.3..1.5, default 1.0
  "fontScale": 1.0,         // optional, 0.5..2.0, default 1.0
  "action": { "kind": "..." }| null,   // buttons and spacers only
  "actions": { "...": { "...": "..." } } // dpad and rocker only
}
```

Cells must not overlap. Empty grid positions are allowed. The grid is expected
to be fully covered (a missing cell means a dead gap the decoder keeps, and
the `check-remote-template.py` validation reports); the bundled template and
`Templates/*.json` use `spacer` cells for those gaps.

### Controls

| Control | What it draws | Roles |
| --- | --- | --- |
| `button` | one labelled tile | single `action` |
| `spacer` | nothing; a dead gap that keeps the grid covered | single `action` (used for coverage) |
| `dpad` | 3x3 grid; the corners stay empty | `actions` with roles `up`, `down`, `left`, `right` (required) and `center` (optional) |
| `rocker` | two halves along the cell's longer axis | `actions` with roles `primary` and `secondary` (both required) |

A dpad `center` is always a tap; the four arms keep the cell's `press`, so a
`hold` cell scrolls the TV on release. A rocker is exactly two halves and
always `hold`-style for the press.

### Actions

The vocabulary is deliberately small. Every entry maps onto an existing call on
`RemoteInputController`, so a template cannot ask for an action the transports
do not implement. Three kinds exist:

| `kind` | fields | sends |
| --- | --- | --- |
| `key` | `key`, `modifiers` | `sendKeyDown`/`sendKeyUp` |
| `consumer` | `usage` | `sendConsumerDown`/`sendConsumerUp` |
| `none` | — | nothing (a labelled gap or an unassigned key) |

`key` is a name resolved through the HID table (`up`, `down`, `left`, `right`,
`return`, `escape`, `backspace`, `tab`, `space`, `delete`, `home`, `end`,
`pageUp`, `pageDown`, `win`). Modifiers (`shift`, `ctrl`, `alt`, `gui`) are an
optional list.

`consumer` names a usage from `RemoteUsageId` — names only, never numbers:
`power`, `sleep`, `brightnessUp`, `brightnessDown`, `fastForward`, `rewind`,
`next`, `previous`, `shuffle`, `repeat`, `playPause`, `mute`, `volumeUp`,
`volumeDown`, `menu`, `menuPick`, `menuEscape`, `info`, `closedCaption`, `tv`,
`guide`, `videoNext`, `exit`, `help`, `channelUp`, `channelDown`, `home`,
`back`, `backLg`, `forward`, `stop`, `refresh`. A typo is a load-time error,
not a silent dead button.

**Names, not numbers.** A template that says `"usage": "home"` is readable.
Raw numbers are not accepted, because with no editor, the only source of
templates is a hand-written file, and a plausible number no host acts on is
the worst silent failure.

A `dpad` or `rocker` carries `actions` keyed by role (`up`/`down`/`left`/
`right`/`center` for dpad, `primary`/`secondary` for rocker) — each value is a
plain action, plus an optional `label`. The centre of a dpad does not need a
label; no label renders the glyph (`▲ ▼ ◀ ▶ ⏎` or `+ −`).

### Labels

`label` is either a plain string or an object of per-language values:

```jsonc
"label": "Тиша"
"label": { "uk": "Тиша", "en": "Mute" }
```

**Plain string:** the text is the localization key. Ukrainian source strings
are the keys; `en.lproj` translates them; a user label with no matching entry
renders verbatim. The accepted wart is that a user label equal to an existing
localization key gets translated.

**Object form:** explicit per-language values, resolved against the current
app locale. Resolution order: exact match (`en_US`) → language prefix (`en`)
→ English → Ukrainian → empty string. Use this when a template must carry its
own translations — e.g. an imported template shared between users on
different language devices. The object form never goes through the app's
localization table.

Role slots accept the same two forms. Each form may be omitted; empty labels
are legal on every control (a dpad arm with no label renders the glyph).

Glyphs are plain text (`"▲"`, `"⏎"`), so a template needs no app assets.

### Visual knobs

- **`scale`** (0.3–1.5, default 1.0): shrinks or grows the control around its
  own centre. 1.0 fills the cell; 0.6 leaves most of the tile empty.
- **`fontScale`** (0.5–2.0, default 1.0): multiplies the label font size. The
  default 16 pt, 10 pt compact.

Unknown or out-of-range values drop the whole cell (with an app note) — a
bad knob must not shift the grid.

## Example

A complete, validated template — a 5×4 remote with per-language labels:

```json
{
  "formatVersion": 1,
  "id": "my-tv",
  "name": "My TV",
  "columns": 5,
  "rows": 4,
  "cells": [
    {
      "id": "mute",
      "row": 1, "col": 1,
      "control": "button",
      "label": { "uk": "Тиша", "en": "Mute" },
      "tone": "plain",
      "press": "tap",
      "action": { "kind": "consumer", "usage": "mute" }
    },
    {
      "id": "home",
      "row": 1, "col": 2,
      "control": "button",
      "label": { "uk": "Додому", "en": "Home" },
      "tone": "prominent",
      "press": "tap",
      "action": { "kind": "key", "key": "win" }
    },
    {
      "id": "menu",
      "row": 1, "col": 3,
      "control": "button",
      "label": { "uk": "Меню", "en": "Menu" },
      "press": "tap",
      "action": { "kind": "consumer", "usage": "menu" }
    },
    {
      "id": "info",
      "row": 1, "col": 4,
      "control": "button",
      "label": { "uk": "Інфо", "en": "Info" },
      "press": "tap",
      "action": { "kind": "consumer", "usage": "info" }
    },
    {
      "id": "back",
      "row": 1, "col": 5,
      "control": "button",
      "label": { "uk": "Назад", "en": "Back" },
      "fontScale": 1.3,
      "press": "tap",
      "action": { "kind": "consumer", "usage": "backLg" }
    },
    {
      "id": "volume",
      "row": 2, "col": 1,
      "rowSpan": 2,
      "control": "rocker",
      "label": { "uk": "Гучність", "en": "Volume" },
      "press": "hold",
      "actions": {
        "primary": {
          "kind": "consumer",
          "usage": "volumeUp",
          "label": { "uk": "Гучн. +", "en": "Vol +" }
        },
        "secondary": {
          "kind": "consumer",
          "usage": "volumeDown",
          "label": { "uk": "Гучн. −", "en": "Vol −" }
        }
      }
    },
    {
      "id": "pad",
      "row": 2, "col": 2,
      "rowSpan": 3,
      "colSpan": 3,
      "control": "dpad",
      "scale": 0.75,
      "press": "hold",
      "actions": {
        "up": { "kind": "key", "key": "up" },
        "down": { "kind": "key", "key": "down" },
        "left": { "kind": "key", "key": "left" },
        "right": { "kind": "key", "key": "right" },
        "center": { "kind": "key", "key": "return" }
      }
    },
    {
      "id": "gap-1",
      "row": 4, "col": 1,
      "control": "spacer",
      "label": "",
      "action": { "kind": "none" }
    },
    {
      "id": "gap-2",
      "row": 4, "col": 5,
      "control": "spacer",
      "label": "",
      "action": { "kind": "none" }
    },
    {
      "id": "gap-3",
      "row": 2, "col": 5,
      "control": "spacer",
      "label": "",
      "action": { "kind": "none" }
    },
    {
      "id": "gap-4",
      "row": 3, "col": 5,
      "control": "spacer",
      "label": "",
      "action": { "kind": "none" }
    }
  ]
}
```

Validate any file with:

```bash
python3 scripts/check-remote-template.py your-file.json
```

## Validation rules

Refusal (the file is not used at all) is reserved for what makes a screen
ambiguous:

| Situation | Behaviour |
| --- | --- |
| unparseable file | rejected — never renders silently |
| `formatVersion` newer than the app | refuse the file |
| missing or empty `id` / `name` / out-of-range `columns`/`rows` | refuse the file |
| duplicate cell `id` | refuse the file |
| out-of-range or overlapping coordinates | refuse the file |
| unknown key with the wrong type | refuse the file |

Everything else degrades visibly and is reported, not fixed silently:

| Situation | Behaviour |
| --- | --- |
| unknown control / kind / name | drop that cell, note the reason |
| out-of-range `scale` / `fontScale` | drop that cell, note the field |
| button with no label | keep it, but note that it is unlabelled |
| dpad with no centre | keep the four directions, note the missing centre |
| unknown key in an object | ignore it (forward compatibility) |
| a cell with no grid position | drop it, note the reason |

A template whose every cell is dropped renders its bundled fallback — a blank
screen is never the answer.

## The shipped default

`InpuDeck/RemoteTemplate.tv-default.json` (4×5) is the reference template:
Mute / Home / Menu / Input on the top row, Exit / Info / Back on row 2, the
volume rocker on the left, and the 3×3 pad. It is the only template the
maintainer has physically confirmed on the LG C1 OLED 2021 — see
[`docs/tv-remote.md`](tv-remote.md) for the verified facts and the Back/Input
keycode chain.

Other shipped examples: `Templates/samsung.json` (a 5×4 Samsung layout,
channel rocker included) and `Templates/scaled-pad-test.json` (scale +
fontScale demonstration).
