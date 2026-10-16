# Tab customization

Settings → Tabs opens a list with checkmarks and native drag handles. Changes
are applied and saved immediately; hidden tabs remain in the configuration list
so they can be re-enabled at their chosen position.

- Normal mode labels every tab, including Commands. Expert mode uses icons with
  accessible names; changing this mode doesn't reset tab order/visibility.
- At least one tab must remain enabled. The final enabled checkbox is disabled;
  all disabled tabs can still be re-enabled. Every page provides settings access.
- Selection is a stable AppTab ID, not an index. Reordering doesn't change the
  current page. Hiding the current page selects the first enabled tab in the new
  order. Startup selects that first enabled tab.
- Edge swipes traverse only the enabled tabs in their configured order, without
  wrapping at either end. They use local view width, including in landscape.
- Hiding Commands removes its view and cancels its private authentication/editing
  state. Hiding Tools stops the mouse jiggler. Hiding Keyboard releases its held
  input through its existing disappearance handler.
- Incoming Share/Shortcut text does not silently re-enable hidden Input or select
  a missing tab. Its existing queuing/sending behavior remains; re-enable Input
  to inspect pending text if disconnected.

The JSON preference tabConfiguration stores full order and hidden IDs in
UserDefaults. Unknown/duplicate IDs are ignored, newly added tabs are appended,
and malformed/all-hidden configurations recover to a usable state. No app data
or command bodies are stored in this preference.

## Validation

AppTabConfigurationTests covers default/malformed data, normalization, stable
selection, single/multi-row moves, hiding the current tab, last-tab protection,
persistence and swipe neighbors. The simulator harness uses production
ConfiguredTabView and TabSettingsView with fake page contents/input hardware.

UI checks cover normal/expert captions, toggles, real drag reorder, persistence
after relaunch, fallback when hiding Commands, settings remaining reachable from
the sole enabled Input tab, and edge navigation skipping hidden Keyboard.
Commands control/editor tests continue to run through the shared tab container.

CI and simulator tests do not establish physical Bluetooth or Face ID behavior.
