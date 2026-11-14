# TV remote

Design draft for the roadmap item "TV remote". Nothing in this file is
implemented yet: there is no template decoder, no remote tab and no bundled
template in the app. The point of this document is to settle the template
format before the first line of UI, because a format that ships is hard to
change afterwards.

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
  "name": "TV",                // required, shown in the picker
  "columns": 4,                // required, 3…6
  "rows": 6,                   // required, 3…10
  "pointerZone": "none",       // "none" | "strip" — see Open decisions
  "cells": [
    {
      "id": "power",           // required, unique within the template
      "row": 1, "col": 1,      // required, 1-based, inside the grid
      "rowSpan": 1, "colSpan": 1,   // optional, default 1
      "control": "button",     // button | dpad | rocker | spacer
      "label": "Живлення",     // see "Labels"
      "tone": "plain",         // plain | prominent
      "press": "tap",          // tap | hold
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

### Actions

The vocabulary is closed. Each entry maps onto an existing call on
`RemoteInputController` (`InpuDeck/RemoteInputController.swift:150-199`), so a
template cannot ask for an action the transports do not implement:

| `kind` | fields | sends | notes |
| --- | --- | --- | --- |
| `key` | `key`, `modifiers` | `sendKeyDown`/`sendKeyUp` | `key` is a name (`up`, `return`, `escape`, `digits`…) resolved through `HID`; `modifiers` optional |
| `consumer` | `usage` | `sendConsumerDown`/`sendConsumerUp` | `usage` is a name from the tables above |
| `text` | `text` | the existing typing path | for TV search boxes; reuses `MixedCommandParser`, so `<Enter>` markers already work |
| `setting` | `setting`, `value` | writes an app setting | the one non-HID kind; see Open decisions |
| `sequence` | `steps` | the actions in order | for "mute then volume", app-launch combos |
| `none` | — | nothing | a labelled gap or an unassigned key |

Names, not numbers: a template that says `"usage": "home"` is readable and
validated, and a typo is a hard error at load time. Raw numbers are accepted
for `consumer` (`{"kind":"consumer","usage":547}`) but the loader marks that
cell as unverified in the editor, because a plausible number that no host acts
on is the worst possible silent failure.

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

Following the `CommandletStore` precedent (`InpuDeck/Commandlet.swift:35-51`,
JSON in Application Support):

- user templates: `Application Support/InpuDeck/remoteTemplates.json`
- the bundled default lives in the app bundle as a real `.json` resource, so
  the shipped remote and the format are the same code path, and the bundled
  file is parsed by the same decoder that parses the user's — a format bug then
  shows up before any user can hit it
- the selected template id: one `@AppStorage` key, not an index; deleting the
  chosen template falls back to the bundled default

## Validation and recovery

Same posture as `AppTabConfiguration`: a saved file is data of unknown quality,
and recovery must never leave the user with a blank screen.

| Situation | Behaviour |
| --- | --- |
| unparseable file | keep the bundled default, say why in the picker |
| `formatVersion` newer than the app | refuse that one template, keep the rest |
| unknown `control` / `kind` / name | drop that cell, name it in diagnostics |
| out-of-range or overlapping coordinates | refuse the template |
| duplicate `id` | refuse the template |
| unknown key in an object | ignore it, so a newer template still half-works |

Refusing is reserved for what makes a screen ambiguous; anything else degrades
visibly and is listed in the editor rather than fixed silently. This is the
rule the air-mouse sign work taught the hard way: a wrong guess that loads
"successfully" costs the user a whole install/test cycle.

## Unverified — and it decides nothing above, but decides the defaults

The design above is host-independent. What is **not** established:

- whether the target TV acts as a Bluetooth HID host at all. Bluetooth keyboards
  are common on Android TV, far less predictable on other brands;
- whether that TV maps `Home`/`Back` as consumer `0x0223`/`0x0224`, or only
  reacts to plain keyboard `Escape`/`Return`;
- whether the remote is meant for a TV directly, or for a box/PC attached to it.

If the TV is not a HID host, the whole feature still works unchanged — the same
template just drives the box or the PC — so this does not block the format. It
does decide which two keys go in the bundled default, and it is a question about
real hardware rather than a thing to be reasoned out.

## Open decisions (answered by the maintainer, not by me)

1. **Pointer switch.** `pointerSurface` is one global `@AppStorage`, and after
   3.5.13 the gyroscope streams only while the Input tab is on screen
   (`syncPointerSurface()`,
   `InpuDeck/ContentView.swift:1120-1126`). A remote tab with a pointer must either
   widen that guard or keep its own pointer state. Widening it re-opens the
   exactly-one-pointer-source rule that the 3.5.13 fix exists to hold, so this
   is a decision, not a detail.
2. **Editing in v1, or bundled template only?** Format + engine + one shipped
   template is a much smaller step than also building an editor, and the
   bundled template already exercises every part of the format. A raw-JSON
   editor with the validation table above is the cheapest honest editor; a
   visual one is not cheap.
3. **Which host is this for?** See "Unverified".

## Suggested order, each step independently shippable

1. decoder + validation + the tables, pure `Shared/`, unit-tested before any UI
   (this is where the tests are cheap and where mistakes are expensive);
2. bundled default template rendered on a tab, read-only, no pointer;
3. the pointer decision;
4. an editor, if still wanted once the format has been lived with.
