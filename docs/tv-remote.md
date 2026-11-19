# TV remote

The roadmap item "TV remote". Steps 1 and 2 are implemented: the decoder and
its tables live in `Shared/RemoteTemplate.swift`, the shipped template is
`InpuDeck/RemoteTemplate.tv-default.json`, and the screen is
`InpuDeck/RemoteScreenPage.swift` behind a new `Пульт` tab. What is still
design-only is the pointer and an editor, both deferred (see "Decisions").

Scope is settled as of 2026-11-14 — see "Decisions". In short: the target is the
maintainer's LG C1 OLED 2021 driven through the ESP32 bridge, v1 has no pointer
at all, and v1 ships one bundled template with no editing. Those three answers
removed a field and two action kinds from the format described below, which is
the whole reason they were worth asking for first.

## What the transport can already carry (verified, not inferred)

A remote key is only as good as the report that carries it, so the first
question was whether the two existing transports can express TV keys at all.
Both already can, and no descriptor or firmware change is needed:

- **Direct Bluetooth HID.** Report ID 3 declares a 16-bit Consumer Control
  usage selector with Logical Min/Max `0x0000`–`0x03FF` and Usage Min/Max
  `0x0000`–`0x03FF` (`Shared/HIDReports.swift:345-348`).
- **ESP32 bridge.** The bridge forwards an arbitrary little-endian uint16 usage
  (`inpudeck_bridge.ino:332`, `V2_CONSUMER_DOWN` → `sendConsumerDown()` at
  `inpudeck_bridge.ino:705`), and the Arduino Consumer descriptor is
  `TUD_HID_REPORT_DESC_CONSUMER`, which tinyusb declares with the same
  `0x0000`–`0x03FF` usage range.

Usages already named in `HIDConsumerUsage` (`Shared/HIDReports.swift:12-27`):
Power `0x0030`, Sleep `0x0032`, Brightness ±`0x006F/0x0070`, Fast Forward
`0x00B3`, Rewind `0x00B4`, Next `0x00B5`, Previous `0x00B6`, Shuffle `0x00B9`,
Repeat `0x00BC`, Play/Pause `0x00CD`, Mute `0x00E2`, Volume ±`0x00E9/0x00EA`.

The usages a TV remote needs beyond those. Each number below is taken from the
Linux kernel's Consumer-page mapping in `drivers/hid/hid-input.c`, i.e. from a
table another HID stack actually uses, not from memory:

| Name | Usage | Linux maps it to |
| --- | --- | --- |
| Menu | `0x0040` | `KEY_MENU` |
| Menu Pick | `0x0041` | `KEY_SELECT` |
| Menu Escape | `0x0046` | `KEY_ESC` |
| Data On Screen (Info) | `0x0060` | `KEY_INFO` |
| Closed Caption | `0x0061` | `KEY_SUBTITLE` |
| TV | `0x0089` | `KEY_TV` |
| Program Guide | `0x008D` | `KEY_PROGRAM` |
| Exit | `0x0094` | `KEY_EXIT` |
| Help | `0x0095` | `KEY_HELP` |
| Channel Up | `0x009C` | `KEY_CHANNELUP` |
| Channel Down | `0x009D` | `KEY_CHANNELDOWN` |
| Home | `0x0223` | `KEY_HOMEPAGE` |
| Back | `0x0224` | `KEY_BACK` |
| Forward | `0x0225` | `KEY_FORWARD` |
| Stop | `0x0226` | `KEY_STOP` |
| Refresh | `0x0227` | `KEY_REFRESH` |

Whether a **given** TV reacts to these is a different question, and it is the
main thing this design cannot answer. See "Unverified".

Holding a mapped consumer usage or key does not need an app-side repeat timer:
the app keeps the report held, and the host applies its own autorepeat. The
current `PressableKeyButton` (`InpuDeck/PressableKeyButton.swift`) already has
`onPress`/`onRelease`, which is exactly that shape, so "hold to keep
scrolling" costs nothing in the template format — but it does need the host to
repeat, which is also unverified per host.

## The unit being designed

A remote screen is a grid of cells. One cell is one control. A control has a
label and produces actions. Three things are deliberately independent:

1. **Placement** — grid coordinates only, never pixels.
2. **Control kind** — how the cell looks and what press means.
3. **Action** — which HID report the press sends.

Independence is what makes the same template renderable on the current iPhone,
a future iPad width and the iPhone Duo layout without editing the template.

## Format version 1

```jsonc
{
  "formatVersion": 1,          // required; unknown major → refuse the file
  "id": "tv-default",          // required, stable; the user picks by id
  "name": "TV",                // required, the screen title
  "columns": 4,                // required, 3…6
  "rows": 6,                   // required, 3…10
  "cells": [
    {
      "id": "power",           // required, unique within the template
      "row": 1, "col": 1,      // required, 1-based, inside the grid
      "rowSpan": 1, "colSpan": 1,   // optional, default 1
      "control": "button",     // button | dpad | rocker | spacer
      "label": "Живлення",     // see "Labels"
      "tone": "plain",         // plain | prominent
      "press": "tap",          // tap | hold; a dpad centre is always a tap
      "action": { "kind": "consumer", "usage": "power" }
    },
    {
      "id": "pad",
      "row": 2, "col": 1, "rowSpan": 3, "colSpan": 3,
      "control": "dpad",
      "actions": {
        "up":    { "kind": "key", "key": "up" },
        "down":  { "kind": "key", "key": "down" },
        "left":  { "kind": "key", "key": "left" },
        "right": { "kind": "key", "key": "right" },
        "center":{ "kind": "key", "key": "return" }
      }
    }
  ]
}
```

Only `button`, `dpad`, `rocker` and `spacer` exist in v1. `rocker` is one cell
with two halves (Volume ±, Channel ±) and is worth having precisely because
putting those four as separate cells looks wrong on a remote.

`dpad` and `rocker` slots carry their **own** label, because an action cannot
say "Гучність +" by itself:

```jsonc
"actions": {
  "primary":   { "kind": "consumer", "usage": "volumeUp", "label": "Гучність +" },
  "secondary": { "kind": "consumer", "usage": "volumeDown", "label": "Гучність −" }
}
```

A slot with no label renders a glyph (`▲ ▼ ◀ ▶ ⏎ + −`), which is why the shipped
dpad is unlabelled and still readable.

### Actions

The vocabulary is closed. Each entry maps onto an existing call on
`RemoteInputController` (`InpuDeck/RemoteInputController.swift:150-199`), so a
template cannot ask for an action the transports do not implement:

| `kind` | fields | sends | notes |
| --- | --- | --- | --- |
| `key` | `key`, `modifiers` | `sendKeyDown`/`sendKeyUp` | `key` is a name (`up`, `return`, `escape`, `digits`…) resolved through `HID`; `modifiers` optional |
| `consumer` | `usage` | `sendConsumerDown`/`sendConsumerUp` | `usage` is a name from the tables above |
| `none` | — | nothing | a labelled gap or an unassigned key |

Three kinds were in an earlier draft and are deliberately **not** in v1:
`setting` (writes an app setting — its only real use was the pointer-surface
switch, which v1 does not have), `sequence` (its only use was a case no TV
remote has), and `text` (typing needs the host-layout state the Input tab owns,
so `TextTypingPlanner` would have to be threaded through the remote for a cell
the shipped template does not have). A format should carry only what the shipped
template actually presses; every field no template uses is a field whose
semantics nobody will ever re-derive. Adding a kind later is additive.

Names, not numbers. A template that says `"usage": "home"` is readable, and a
typo is a hard error at load time instead of a silent dead button. Raw numbers
(`{"kind":"consumer","usage":547}`) are **not** accepted in v1: with no editor,
the only source of templates is the bundled file, which uses names, so accepting
numbers would only widen what the decoder has to trust.

## Layout rules

- No pixels, no font sizes, no colors in a template. The renderer derives them
  from the cell size and `tone`; `minHeight` is not a template field.
- Cells must not overlap. An overlap makes the whole file invalid — silently
  dropping one of two overlapping keys would remove a control the user can see
  missing.
- Empty grid positions are allowed and need no spacer cell.
- Cells are drawn in array order; order is only for painting and diagnostics.

## Labels and localization

`label` is a plain string looked up through the existing `localized()`
(`Shared/Localization.swift`), whose key is the Ukrainian source text and which
returns the key itself when there is no translation. The bundled default
template therefore holds Ukrainian labels and gets English from `en.lproj`
without a second field. A user-authored label with no matching entry simply
renders verbatim. The one accepted wart: a user label that happens to equal an
existing localization key gets translated.

`label` may also name a glyph (`"▲"`, `"⏻"`). Icons stay as text so that a
template does not need app assets; if a real symbol is wanted later, a `symbol`
field can be added without changing existing files.

## Storage and defaults

v1 has exactly one template, and it is not user data:

- the bundled default lives in the app bundle as a real `.json` **resource**, so
  the shipped remote and the format are one code path — the decoder that reads
  the shipped file is the decoder that is unit-tested, and a format bug surfaces
  in CI instead of on the maintainer's sofa;
- nothing is written to Application Support and no template id is stored in
  `@AppStorage`. Both are one file and one key away, and `CommandletStore`
  (`InpuDeck/Commandlet.swift:35-51`) is the precedent to copy when there is a
  second template worth choosing between. Storing a selection before there is a
  picker is how the air-mouse invert keys accumulated migrations.

### The shipped layout

`InpuDeck/RemoteTemplate.tv-default.json` is 4 columns x 6 rows, fully covered, and
follows the shape of the LG remote the maintainer showed: a vertical VOL pair and a
vertical CH pair up top with Guide between them, Mute top-right, Exit and Info on
row 2, the 3x3 pad filling rows 3-5 with Menu beside it, and Back / Home / TV on the
bottom row. Home is the only prominent cell. Empty tiles (`spacer`) fill the rest,
because the codes that did not reach the TV are absent rather than guessed, and
Power is not in the template at all.

Two rules come from how the codes behave, not from taste:

- **No Power cell.** Consumer Power `0x0030` is a toggle: one press turns the TV
  off, and a TV that is off no longer answers this link, so the button would be a
  one-way ticket - the app could not bring the TV back and the bridge would sit
  disconnected. Power stays a legal usage in the format for a template that runs
  over a link that survives standby.
- **A rocker is exactly two halves.** Previous / Play-pause / Next are three
  states, so they are three buttons; a three-role rocker renders two halves and
  overlaps their labels, which is what the first device build showed.

## Validation and recovery

Same posture as `AppTabConfiguration`: a saved file is data of unknown quality,
and recovery must never leave the user with a blank screen.

| Situation | Behaviour |
| --- | --- |
| unparseable file | unreachable in v1 (only the bundled file exists), but tested: the tab shows an empty remote plus a hint, never a crash |
| `formatVersion` newer than the app | refuse that one template, keep the rest |
| unknown `control` / `kind` / name | drop that cell, name it in the test failure and in the app log |
| out-of-range or overlapping coordinates | refuse the template |
| duplicate `id` | refuse the template |
| unknown key in an object | ignore it, so a newer template still half-works |
| known key with the wrong type | refuse the template (a numeric usage is a malformed file, not a guess) |
| a `dpad` without its centre | keep the four directions, report the missing centre |

Refusing is reserved for what makes a screen ambiguous; anything else degrades
visibly and is reported rather than fixed silently. This is the
rule the air-mouse sign work taught the hard way: a wrong guess that loads
"successfully" costs the user a whole install/test cycle.

## Decisions (maintainer, 2026-11-14)

1. **Host: the maintainer's LG C1 OLED 2021, reached through the ESP32 bridge
   today**, i.e. the path is iPhone → BLE → ESP32 → USB HID → TV USB port.
   Direct Bluetooth is a possible later step, explicitly not part of v1.
2. **No pointer on the remote tab in v1.** `pointerSurface` stays one global
   `@AppStorage` and `syncPointerSurface()` (`InpuDeck/ContentView.swift:1120`)
   keeps streaming only while the Input tab is on screen, so the exactly-one-
   pointer-source rule from 3.5.13 is untouched. This is why the format lost its
   `pointerZone` field and the `setting` action.
3. **One bundled template, no editor in v1.** Which means the bundled file is
   the only real specification of the format: whatever it does not exercise is
   not yet a requirement.

## Unverified — what the C1 actually does with these codes

The format is host-independent; the *default template* is not. Established:

- LG documents connecting a wired or wireless keyboard, mouse or gamepad to a
  Smart TV through the USB port, for models from 2012 on (LG help library,
  retrieved 2026-11-14: `lg.com/us/support/help-library/lg-tv-how-to-connect-a-
  keyboard-mouse-or-gamepad-to-your-lg-tv--20152890341179`). That is vendor
  documentation about USB HID in general — it is not a test of the C1, and not a
  statement about this app.

**Measured on the maintainer's C1, 2026-11-15 (build 3.6.7 / 3.6.8):**

- acted on: consumer `volumeUp` `0x00E9`, `volumeDown` `0x00EA`, `mute` `0x00E2`,
  `menu` `0x0040`, `exit` `0x0094`; keyboard arrow keys (the pad's arms);
- ignored: consumer `menuPick` (Select) `0x0041`, `home` `0x0223`, `back` `0x0224`,
  `playPause` `0x00CD`;
- a real keyboard on the TV answered **keyboard Enter** for Select, which is why the
  app's pad centre did nothing: it sent consumer `menuPick`, not Enter. Keyboard
  **Win/GUI** reached the TV's home screen (the earlier text incorrectly said the
  Home navigation key). Keyboard `Escape` and `Backspace` did not act
  as Back at all.
- consumer `tv` `0x0089` does something, but it switches to the TV input instead of
  opening the input list the original remote's button shows.

The centre uses keyboard `Return`. Home must send **Win/GUI**, a modifier-only
keyboard report (modifier byte `0x08`, no ordinary key), not navigation Home
`0x4A`. Channel +/- and TV input are removed at the maintainer\'s request.

**Correction, 2026-11-19:** webOS event keycode 461 (`0x1CD`) is not a USB HID
usage. The previous inference from equal numbers was invalid: consumer `0x01CD`
is AC Insert, not a verified LG Back code. The maintainer tested it and it did
not work. Back remains unresolved; do not claim it works or try more unrelated
numeric codes. The bridge parses the full little-endian UInt16 and forwards it
to `USBHIDConsumerControl.press` without a per-usage filter. That is source-code
evidence, not proof of what the currently flashed device actually emits. The next
useful measurement is the ESP USB report on a computer, followed by identifying
which USB HID report (if any) webOS translates to its Back event. `Tests/
RemoteTemplateTests.swift` refuses a template that reintroduces an ignored usage.
Still unmeasured on the C1: Guide `0x008D`, Info `0x0060`, Channel Up/Down
`0x009C/0x009D`, and what opens the input list at all.

- how far webOS binds the ESP's composite device (keyboard + mouse + consumer +
  microphone-mute in one descriptor): the 2026-11-15 test proves keyboard and
  consumer both arrive, but the consumer set it accepts is partial, so the
  composite binding is only partly demonstrated;
- whether the C1 accepts a direct Bluetooth HID pairing (the "потім напряму"
  path) — not investigated here.

The template-first design paid for itself here: the fix was a JSON edit, not a
code change. The remaining unknowns are the same shape - one or two cells in one
file, verified by the maintainer's phone, never by a guess.

## Order, each step independently shippable

1. **done** — decoder + validation + usage tables in pure `Shared/`, with
   `Tests/RemoteTemplateTests.swift` in the release test script;
2. **done** — the bundled template rendered on the `Пульт` tab, read-only, no
   pointer. This is the first release where the C1 can be tested with it;
3. an editor only if the format survives living with the real remote for a while.

Nothing here needs a descriptor change, a firmware change, or a new transport.
The first change that could need one is a key outside Consumer `0x0000`–`0x03FF`
or a report type the composite descriptor does not already declare.
