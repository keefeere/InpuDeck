# Documentation screenshots

The [3.4 capture provenance](images/screenshots-3.4.0.json) records the exact
version/build, merge-source commit, runtime and fixture disclosure. Images were
visually reviewed before committing; their production UI source was unchanged
by the subsequent image/documentation-only commit.

The 3.4 screenshots in docs/images are captured from the production
InpuDeck.xcodeproj/InpuDeck simulator build, not the fake-transport UI harness.
A separate XCTest runner launches the already installed production application.

Capture uses a newly created, disposable iPhone simulator. It never overwrites
an existing simulator's preferences or saved commands. The device is deleted on
exit. Only public sample command names/bodies and ordinary preferences are
seeded into the fresh app container. No real Bluetooth host, password, or
connection status is substituted: the screenshots intentionally show offline.

The app runs in English and dark mode, with a fixed simulator status bar.
Captures include Input, Keyboard portrait/landscape, Tools landscape, Commands,
the mixed editor, expanded key legend, and tab settings. Image orientation is
rendered into pixels, and PNGs are resized to at most 1600 pixels for the README.

Run the **Capture app screenshots** GitHub workflow, or on a Mac with Xcode and
xcodegen run bash scripts/capture-app-screenshots.sh. The workflow also runs for
PRs changing this capture suite/script/workflow; it is not a required substitute
for ordinary app and UI tests.

The app-documentation-screenshots artifact contains:
- app-screenshots: eight named PNGs ready for docs/images.
- app-screenshot-provenance.json: actual app version/build, source commit,
  runtime/device type, fixture and offline-transport disclosure.
- exported attachments, xcresult and build/test logs for verification.

Review the generated images before copying them into the repository. Screenshot
capture demonstrates UI rendering only, not physical Bluetooth, host key
behavior, Face ID or wake validation.
