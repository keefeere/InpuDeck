# Commands: regression checks

## Contract

- Play sends a saved command without revealing its body. Viewing, editing,
  copying, duplicating and confirming deletion require Local Authentication.
- Face ID / Touch ID use the system device-passcode fallback. There is no
  separate application password. `NSFaceIDUsageDescription` must be present in
  the built app; the IPA packaging script checks this before publishing.
- Revealed bodies hide after 30 seconds. The unlocked session expires after
  60 seconds, including when an existing-command editor is open.
- An inactive scene hides private UI. Authentication may itself deactivate the
  scene, so its result is retained until activation. Backgrounding or leaving
  Commands cancels the request; a late result cannot reopen private content.
- Swipe Delete is a red, non-destructive presentation action. Authentication
  precedes confirmation; only the confirmed action deletes the stored command.
- Commands starts with an independent EN assumption each time the tab is entered.
  Successful queue acceptance advances that session's assumed layout. This never
  updates the other tabs' `targetKeyboardLayout` preference.
- The raw host-only switch sends the configured layout shortcut without changing
  the displayed assumption. Use it to align the host with the displayed EN/UA.
  HID cannot read the host's actual layout or confirm a switch. The switch
  assumes two host layouts; cycling through more layouts needs manual alignment.
- Invalid syntax or unsupported characters block the entire command rather than
  silently executing a truncated command. A transport refusal is not success.
- Disk write failure leaves the persisted list unchanged and the editor open.
  Failed loading blocks writes so corrupt or unreadable data is not overwritten.

## Automated checks

`./scripts/test-direct-hid.sh` runs the HID/parser tests, pure unlock lifecycle
state tests, and command persistence tests on macOS. `test-localizations.sh`
validates English and Ukrainian resources. The release build checks the actual
built Info.plist, not just the source plist, for the Face ID usage description.

These checks do not prove physical Face ID, presentation animations or Bluetooth
host behavior. They also do not establish that a queued report reached the host.

## Required physical-device checks

1. On a Face ID device, tap a hidden body: system authentication, reveal only
   that row. Cancel and retry; a quick second tap must not replace the action.
   Check device-passcode fallback when biometrics are unavailable.
2. Begin authentication, then background or leave the tab: late success must not
   reveal a body or open an editor/confirmation after returning.
3. Open an existing editor, wait 60 seconds: it closes and cannot save. Repeat
   with backgrounding and tab changes. Do not include command contents in logs.
4. From both locked and unlocked states, exercise menu Edit and Delete and both
   swipe actions. Delete must not remove the row before confirmation. Cancel
   leaves it untouched; confirm removes it permanently after relaunch.
5. Set another tab to UA, enter Commands: its assumption is EN and the other
   tab's preference remains UA. Configure the real host shortcut. Check EN/UA
   selection and the host-only switch separately on both Direct Bluetooth and
   ESP. The host-only switch must leave the app's indicator unchanged.
6. With exactly EN and UA enabled on the host, send EN, UA and mixed text and
   verify the first character after each switch. If standalone switching works
   but the first character is wrong, measure transport drain / host switch timing
   before adding ordered settle steps; an arbitrary delay before queueing does
   not establish that a host switch has completed.
7. Check Ctrl+C, Ctrl+V, Ctrl+P, Win+L and explicit Ctrl+Shift+C. Uppercase key
   names must not inject Shift; uppercase plain text must still type uppercase.
8. Try unsupported text and an oversized command: no partial execution or false
   success. Confirm a failed send leaves the session layout assumption unchanged.
