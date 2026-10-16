# Commands: regression checks

## Contract

- Play requires an unlocked session before any saved command is queued. If
  locked, authenticate first and send the originally selected command exactly
  once after activation, without revealing its body. Cancellation, backgrounding
  or leaving the tab must not send anything. Viewing, editing, copying,
  duplicating and confirming deletion also require Local Authentication.
- Face ID / Touch ID use the system device-passcode fallback. There is no
  separate application password. `NSFaceIDUsageDescription` must be present in
  the built app; the IPA packaging script checks this before publishing.
- Revealed bodies hide after 30 seconds. The unlocked session expires after
  60 seconds, including when an existing-command editor is open. Editing activity
  refreshes that idle timer; inactive/background/tab-change locks do not wait.
- An inactive scene hides private UI. Authentication may itself deactivate the
  scene, so its result is retained until activation. Backgrounding or leaving
  Commands cancels the request; a late result cannot reopen private content.
- Swipe Delete is a red, non-destructive presentation action. Authentication
  precedes confirmation; only the confirmed action deletes the stored command.
- Commands starts with an independent EN assumption each time the tab is entered.
  Successful queue acceptance advances that session's assumed layout. This never
  updates the other tabs' `targetKeyboardLayout` preference.
- Compact reorder and EN/UA buttons float over the bottom corners of the list,
  above the tab bar. There is no extra control panel or Commands page heading.
  Normal mode shows its tab caption like the other tabs; expert mode uses icons.
  Accessibility labels remain. Reorder toggles the native list edit mode.
  Scroll content has bottom clearance so the last row stays reachable.
  The EN/UA button matches the keyboard tab: short press switches
  the host and local assumption; long press changes only the local assumption
  for manual synchronization (also when disconnected). No large layout section
  or shortcut picker is shown here; the existing host shortcut setting is used.
  The connection header is also in normal layout flow, not a root safe-area inset.
  HID cannot read the host's actual layout or confirm a switch. This assumes two
  host layouts; cycling through more layouts needs manual alignment.
- Invalid syntax or unsupported characters block the entire command rather than
  silently executing a truncated command. A transport refusal is not success.
- Disk write failure leaves the persisted list unchanged and the editor open.
  Failed loading blocks writes so corrupt or unreadable data is not overwritten.

- Expert mode uses an icon-only Add button and hides editor syntax-help footers
  and empty-state instructions. Successful parse previews are not rendered in
  either mode; concise validation errors remain visible. Existing keys syntax is
  available only for existing legacy commands. New mixed commands use explicit
  angle-bracket key markers; plain text and escapes are documented below.

## Automated checks

`./scripts/test-direct-hid.sh` runs the HID/parser tests, pure unlock lifecycle
state tests, and command persistence tests on macOS. `test-localizations.sh`
validates English and Ukrainian resources. The release build checks the actual
built Info.plist, not just the source plist, for the Face ID usage description.

`bash scripts/test-commands-ui.sh` renders the production Commands view with a
fake input transport on iPhone Simulator. It checks visible/hittable layout
controls in normal and expert modes, real short/long touches and input counts,
bottom placement, reorder mode toggling, absent Commands page heading,
normal/expert tab captions and tab configuration,
icon-only expert Add, hidden expert footer and absence of successful parse rows.
The result bundle includes screenshots of the actual rendered Commands view.

These checks do not prove physical Face ID, presentation animations or Bluetooth
host behavior. They also do not establish that a queued report reached the host.

## Required physical-device checks

1. On a Face ID device, tap a hidden body: system authentication, reveal only
   that row. Cancel and retry; a quick second tap must not replace the action.
   Check device-passcode fallback when biometrics are unavailable. On the first
   unlock, allow the system Face ID permission. If previously denied, enable it
   in iOS Settings → InpuDeck; otherwise passcode-only is expected.
2. From a locked tab, press Play: no host input before Face ID succeeds; only
   the selected command sends once, with no body reveal. Cancel Face ID: no input.
   Rapidly tap two different Play buttons during authentication: only the first
   selection may run. Begin authentication, then background or leave the tab:
   late success must not send input, reveal a body or open an editor/confirmation.
   After the 60-second lock, Play must authenticate again.
3. Open an existing editor, wait 60 seconds: it closes and cannot save. Repeat
   with backgrounding and tab changes. In both new and existing editors, type
   continuously for more than 60 seconds: activity must prevent timeout. Do not
   include command contents in logs.
4. From both locked and unlocked states, exercise menu Edit and Delete and both
   swipe actions. Delete must not remove the row before confirmation. Cancel
   leaves it untouched; confirm removes it permanently after relaunch. Specifically
   check locked context menu → Delete → Face ID → confirmation.
5. Set another tab to UA, enter Commands: its assumption is EN and the other
   tab's preference remains UA. Configure the real host shortcut in settings.
   There must only be floating reorder/EN/UA buttons at the bottom, not a layout
   form or header row. Confirm no Commands page heading, normal/expert tab
   captions follow the chosen mode, and that the final
   list row can scroll clear of the buttons.
   Confirm it is visible and tappable in normal/expert and portrait/landscape.
   On both
   Direct Bluetooth and ESP check: short press switches host and local assumption
   exactly once; long press changes only the local assumption and sends nothing
   to the host (the same behavior as Keyboard). Test long press disconnected too.
6. With exactly EN and UA enabled on the host, send EN, UA and mixed text and
   verify the first character after each switch. If standalone switching works
   but the first character is wrong, measure transport drain / host switch timing
   before adding ordered settle steps; an arbitrary delay before queueing does
   not establish that a host switch has completed.
7. Check Ctrl+C, Ctrl+V, Ctrl+P, Win+L and explicit Ctrl+Shift+C. Uppercase key
   names must not inject Shift; uppercase plain text must still type uppercase.
8. Try unsupported text and an oversized command: no partial execution or false
   success. Confirm a failed send leaves the session layout assumption unchanged.
