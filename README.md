# InpuDeck

Turn your iPhone into an additional keyboard, trackpad, and control deck for
multiple computers over direct Bluetooth or an optional ESP32-S3 USB bridge.

<p align="center">
  <img src="docs/images/input-portrait.png" width="42%" alt="InpuDeck text input and trackpad screen">
  &nbsp;&nbsp;
  <img src="docs/images/keyboard-portrait.png" width="42%" alt="InpuDeck full keyboard and trackpad in portrait orientation">
</p>
<p align="center">
  <img src="docs/images/keyboard-landscape.png" width="88%" alt="InpuDeck full keyboard in landscape orientation">
</p>

## Why This Exists

Ever tried typing a password on a computer or Smart TV without a convenient
keyboard nearby? InpuDeck turns the iPhone already in your hand into a
full-featured keyboard, trackpad, scanner, and hardware control surface.

Direct Bluetooth HID needs no companion app or network connection on the
computer. When USB HID or pre-OS input is required, the optional ESP32-S3
bridge presents itself as a physical USB keyboard and mouse.

## Features

- **English and Ukrainian input** - Automatic alphabet detection with physical US and Ukrainian Enhanced HID mappings
- **Two keyboard modes** - Use the native iOS keyboard beside the trackpad or the dedicated full-screen keyboard tab
- **Layout synchronization** - Configurable Ctrl+Space, Ctrl+Shift, Alt+Shift, Shift+Space, or Win+Space host shortcut
- **Shortcuts sharing** - Send text or URLs from the iOS Share sheet through a one-time Shortcuts setup; the main app waits for BLE and types it reliably
- **Clipboard typing** - Send text from the iPhone clipboard in one tap
- **Precision trackpad** - Cursor movement, two-finger scrolling/right click, pinch-to-zoom, tap-drag, edge scrolling, and three-finger middle click
- **Keyboard trackpad** - Uses the free portrait space below the full keyboard without extra mouse buttons
- **Hardware control deck** - System, media, audio, microphone-mute, and numpad HID controls
- **QR and barcode scanner** - Scan into the composer or automatically type codes, including an optional batch mode
- **Mouse jiggler** - Configurable foreground pointer movement with a selectable movement interval
- **Universal compatibility** - Works with any device that accepts USB HID devices (Smart TVs, computers, streaming boxes, embedded systems)
- **Zero configuration** - No drivers, no network setup, just plug and play
- **Low latency** - Direct Bluetooth LE connection for responsive input
- **Universal destinations** - Remembers Direct Bluetooth computers and multiple ESP32 bridges, then safely switches one active input destination
- **Optional hardware bridge** - Uses an ESP32-S3 for USB HID and pre-OS input when needed
- **Warm-reboot recovery** - Recovers a stalled USB HID endpoint when a host reboots without removing USB power
- **Optional privacy mask** - Keep the typing composer visible or mask it when entering passwords
- **Hardware key hold** - Every on-screen key sends real HID key-down/key-up events, including multi-finger chords; modifiers can also be tapped to latch

## Direct Bluetooth

Direct BLE HID is the default on a new installation. Keyboard and mouse
input and reconnect are stable in repeated physical testing on macOS and
Windows. The Windows-side BlueVein integration preserves the existing bond so
normal use and host switching do not require repeated pairing. Linux input also
works, but its reconnect behavior depends more heavily on the BlueZ and kernel
versions; the optional helper remains available for further Linux testing rather
than being a release blocker. See the
[Linux validation report](docs/linux-direct-hid-validation.md). The app remembers
the selected mode and host.

1. In the connection status strip, open **ESP** and choose **Direct Bluetooth**.
2. Open the pairing button beside the status. To connect from the computer,
   enable pairing in the app and select **InpuDeck** (or the iPhone name) in
   the computer's Bluetooth settings. Confirm any system pairing prompt.
3. To initiate the connection from the iPhone, open Bluetooth settings on the
   computer, choose **Find computer** in the app, then select the computer.
   This path needs the host to advertise over BLE. A BLE link alone is not an
   HID connection; wait until the app reports keyboard and mouse connected.
4. Use the existing keyboard and trackpad. Return to **ESP adapter** to use the
   USB bridge. Switching releases held input and cancels queued text.
5. On Linux, start the connection from the computer using explicit LE; see
   [the Linux guide](docs/linux-direct-hid.md) and
   `./scripts/inpudeck-hid.sh`. The helper requires `python3-dbus` and the
   experimental BlueZ LE bearer API described in the guide. After testing it,
   `--install` adds the on-demand command; a background service is optional
   (`--install-service`). Installation leaves audio settings unchanged.
   Audio prevention for a single phone remains unresolved.
   To disable reception from **all phones** while retaining headphones, the
   optional `python3 scripts/inpudeck-audio-receiver.py install` adds a KDE menu
   switch, **Bluetooth audio receiver**. See the guide for activation and rollback.
   A typical BlueZ desktop does not advertise over BLE by default, so step 3
   may not find it. Its generic "Connect" can also bring up phone audio profiles.
6. If input does not become ready, use **Share log** in the pairing
   panel. The log includes connection stages, not typed text. During prototype
   updates a host may retain old GATT services. Start with the Linux guide's
   diagnostics; a missing cached HID service alone is not a reason to re-pair.

Pairing is open for two minutes. Once connected, input is pinned to that host;
use the pairing panel to select a different computer. HID notifications and
readable input-report state are isolated to the selected host: another bonded
host receives neutral reports rather than the current keyboard or pointer
state. The app clears held and queued input when it moves to the background or
loses its HID session.

Run `./scripts/test-direct-hid.sh` on a Swift-equipped machine to check HID report
encoding, queue backpressure, host selection, and descriptor sizes. The IPA
workflow runs these checks for pull requests and pushes to the v2 branch before
building the app. Version 2.0.0 (16) passed these tests and the Xcode 26.6 iOS
build on 2026-09-04 ([Actions run and IPA artifact](https://github.com/keefeere/ESPRemoteControl/actions/runs/33843087676)).
Physical pairing, input, reconnect, and host-switching validation is complete on
macOS and Windows. Linux helper and additional distro-specific lifecycle testing
remain optional follow-up work.

CI uses [path filters](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onpushpull_requestpull_request_targetpathspaths-ignore)
to avoid unrelated runs. **Test button presses** runs on PRs changing
`ShortAndLongPressButtonStyle.swift`, `Tests/PressActions/`, its runner script,
or its workflow; it can also be started manually. iOS builds watch app/extension
code, the Xcode project, and their own tests/scripts. Linux helper changes run
the separate Linux checks. PR filters consider the whole PR diff against its
base, so a PR that already changes the button style still runs its UI test on
subsequent updates.

## Requirements

- **iPhone** running iOS 17+
- A computer with Bluetooth LE HID support

The optional USB bridge additionally requires an **ESP32-S3** development board
with native USB support and a data-capable USB-C cable.

Popular ESP32-S3 boards that work:
- Waveshare ESP32-S3-Zero
- ESP32-S3-DevKitC-1
- Adafruit QT Py ESP32-S3
- Seeed Studio XIAO ESP32S3

## Quick Start

### 1. Flash the optional ESP32 bridge

<p align="center">
  <img src="docs/images/inpudeck-bridge.jpg" width="42%" alt="Waveshare ESP32-S3-Zero running the optional InpuDeck Bridge">
  <br>
  <sub>Waveshare ESP32-S3-Zero running the optional InpuDeck Bridge.</sub>
</p>

For a Waveshare ESP32-S3-Zero on Linux or macOS, the recommended installer is
one command:

```bash
curl -fsSL https://raw.githubusercontent.com/keefeere/InpuDeck/main/scripts/install-esp32.sh | bash
```

It resolves `latest` to an exact release tag, downloads the firmware and Python
installer, checks the firmware SHA-256, and verifies separate Sigstore provenance
bundles for both executable assets before parsing or running downloaded code.
The accepted signing identity is restricted to this repository's tagged release
workflow and the exact selected tag. It then asks for the bridge name, generates
a unique six-digit security passkey and random static BLE identity, explains the
BOOT/RESET sequence, detects a single Espressif serial port, and runs the Python
installer in an isolated `uv` environment. If `uv` is not installed, the script
downloads its versioned installer only after validating that installer's pinned
SHA-256; the upstream installer also validates the selected `uv` binary. The
temporary tools are removed afterward and no system Python packages are changed.
After flashing, the installer pauses until RESET has been pressed and the user
has confirmed that the board may reconnect. On Linux, if the serial device is
not accessible, it requests `sudo` only to add a temporary ACL to that device
node (and reapplies it after USB re-enumeration); neither `uv` nor `esptool` runs
as root. Every tagged release contains the matching firmware, checksum,
installer scripts, and signed provenance bundles rather than relying on an
expiring Actions artifact.

The short `curl ... | bash` command still treats the HTTPS copy of
`install-esp32.sh` from the repository's `main` branch as its initial trust anchor.
For auditing or a manually bootstrapped installation, the tagged release also
contains `install-esp32.sh.sigstore.json`, which authenticates the exact released
shell installer independently through Sigstore's public transparency log.

If several Espressif serial devices are connected, the installer prefers the
port that was just recreated by the BOOT/RESET sequence. If that signal is
ambiguous, it shows the USB product, serial number, and physical location and
asks for a numbered choice in the same run; there is no need to restart it with
a guessed `/dev/ttyACM*` path. `--port` remains available for automation.

Store the passkey printed at the end. In InpuDeck, select the new ESP adapter
and enter that code in the iOS system pairing prompt. The first-pairing window
stays open for five minutes after provisioning and closes immediately after a
successful authenticated bond.

A full flash or passkey rotation replaces the adapter's BLE identity and deletes
its previous bonds. This prevents iOS from reusing a stale system pairing name
for the board's hardware address. If that physical board was already paired,
forget its old entry in both iPhone Settings → Bluetooth and InpuDeck before
pairing it again. Otherwise the obsolete system entry remains alongside the new
identity.

The name must occupy 1–28 UTF-8 bytes. The installer stores it in the `inpudeck`
NVS namespace; it does not patch or recompile the binary. For explicit or
non-default choices, download `install-esp32.sh` and run, for example:

```bash
./install-esp32.sh --port /dev/ttyACM0 --name "InpuDeck Office" --version 3.3.11
```

The lower-level `install-esp32.py` asset supports Windows `COM` ports and
`--skip-flash` for renaming an already flashed compatible bridge. The one-command
installer exposes the same recovery path without rewriting firmware:

```bash
curl -fsSL https://raw.githubusercontent.com/keefeere/InpuDeck/main/scripts/install-esp32.sh | bash -s -- --skip-flash
```

Every `--skip-flash` mutation requires a physical BOOT window: hold BOOT for
3–7 seconds while the firmware is running before confirming the installer.
A rename without rotation preserves the BLE identity and bonds, so iOS may keep
the previous label in its system Bluetooth list even though InpuDeck and new
scans show the stored name. `--skip-flash` refuses firmware older than 3.3.0
because renaming cannot make the old command channel safe. To replace the BLE
identity and passkey and deliberately invalidate all existing iPhone bonds, use:

```bash
curl -fsSL https://raw.githubusercontent.com/keefeere/InpuDeck/main/scripts/install-esp32.sh \
  | bash -s -- --skip-flash --rotate-passkey
```

For a new iPhone without rotating the shared adapter identity, hold BOOT for
3–7 seconds to open a two-minute pairing window, select the adapter in InpuDeck,
and enter its stored passkey. Holding BOOT for at least 10 seconds deletes every
bond and opens the two-minute window; forget the adapter in iOS as well before
pairing again.

To build from source instead, install [Arduino IDE](https://www.arduino.cc/en/software),
add the ESP32 board package URL below, install
[NimBLE-Arduino](https://github.com/h2zero/NimBLE-Arduino), open
`inpudeck_bridge/inpudeck_bridge.ino`, select the ESP32-S3 board with
`Tools > USB Mode > USB-OTG (TinyUSB)`, enable
`Tools > USB CDC On Boot > Enabled`, and upload the sketch:

```text
https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json
```

An Arduino IDE upload uses `InpuDeck Bridge` by default and generates a passkey
that is printed once over Serial. To replace it with an installer-reported code
and set a different name, hold BOOT for 3–7 seconds and run the released
installer with `--skip-flash --rotate-passkey`.

### 2. Install the iOS App

1. Open `InpuDeck.xcodeproj` in Xcode
2. Connect your iPhone and build/install the app
3. Grant Bluetooth permissions when prompted

#### SideStore without a permanent Mac

The `Build unsigned iOS IPA` GitHub Actions workflow builds an unsigned
`InpuDeck-unsigned.ipa` on a `macos-26` runner. Run the workflow from
the repository's Actions tab, download the artifact, and install the IPA with
SideStore. SideStore can then refresh the app's development signature without
rebuilding it.

Tagged builds named `ios-v*` are also attached to a GitHub Release:

```text
ios-v3.0.0
```

#### Automatic SideStore updates

Add the repository's AltSource to SideStore once:

```text
https://raw.githubusercontent.com/keefeere/InpuDeck/main/sidestore-source.json
```

Or open this one-tap URL on the iPhone:

```text
sidestore://source?url=https://raw.githubusercontent.com/keefeere/InpuDeck/main/sidestore-source.json
```

Every tagged build updates this source after its IPA is attached to the GitHub
Release. SideStore will then detect the new version; enable LocalDevVPN and
confirm the update to sign and install it.

#### Migrating from ESP Remote Control

InpuDeck intentionally uses a new app identity and a new SideStore source.
Remove ESP Remote Control and its old source, add the InpuDeck source above,
then install and pair InpuDeck as a new app. Existing 2.x releases remain in
the repository history but are not copied into the new feed.

On Linux, installing either InpuDeck helper removes the corresponding files
managed by ESP Remote Control before writing the new command and service.
Unrelated files without the old ownership marker are refused and left intact.

#### Cutting a release

Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, then land the change on
`main` with `release-tag-<version>` in the merge commit message — putting it in
the pull request title is enough, since GitHub copies that into the merge
commit. `Auto release tag` then checks the marker against `MARKETING_VERSION`,
creates `ios-v<version>`, and starts `Build unsigned iOS IPA` against that tag,
which attaches the IPA and its checksum to a new GitHub Release and updates
`sidestore-source.json`.

The tag has to be dispatched explicitly rather than left to fire on its own: a
tag pushed with `GITHUB_TOKEN` does not start a workflow run. A release
therefore builds twice — once for the push to `main`, once for the tag — and the
tag build also runs the simulator button tests. Tagging by hand
(`git tag -a ios-v<version> && git push origin ios-v<version>`) still works and
skips the first build; do not create the release through the GitHub UI, because
the workflow creates it and would fail on one that already exists.

To build the same unsigned IPA on a Mac locally:

```bash
./scripts/build-unsigned-ipa.sh
```

### 3. Connect and Use

1. Open InpuDeck and pair the computer from **Direct Bluetooth**. To use the
   optional bridge instead, flash the firmware above, connect the ESP32-S3 to
   the target over USB, and select **ESP adapter** in the connection strip.
2. Choose the target computer's layout shortcut in Settings.
3. Type with the native iOS keyboard or use the dedicated keyboard tab:
   - tap `EN`/`UA` to switch both the phone and target computer
   - hold `EN`/`UA` (or `UA/EN` on the full keyboard) for 0.5 seconds to change
     only the on-screen layout, without sending the host shortcut
   - on the full keyboard, tap the orientation lock to freeze the current
     orientation or unlock it; hold it for 0.5 seconds to force landscape
   - use the globe beside the text field to resend only the host shortcut
4. In **Settings → Shortcuts**, open the app’s shortcut page, then create a new shortcut with **Send to InpuDeck**:
   - tap its `Text` field → **Select Variable** → **Shortcut Input**
   - in the shortcut’s Details, enable **Show in Share Sheet** and allow **Text** and **URLs**
5. From another iOS app, choose `Share` → the shortcut. InpuDeck opens, waits for the selected output if needed, then types the input.
6. Use the trackpad area for mouse control:
   - **Drag** to move cursor
   - **Tap** for left click  
   - **Two-finger tap** for right click
   - **Two-finger drag** to scroll
   - **Pinch** to zoom
   - **Three-finger tap** for middle click
   - **Double-tap and hold the second tap** to drag
   - **Drag along the right edge** for one-finger scrolling

## How It Works

In direct mode, the computer sees the iPhone as a standard Bluetooth LE HID
keyboard and mouse:

```text
iPhone App (SwiftUI) → Bluetooth LE HID → Target Computer
```

The optional bridge adds a BLE-to-USB path:

```text
iPhone App (SwiftUI) 
    ↓ Bluetooth LE
ESP32-S3 Firmware 
    ↓ USB HID
Target Computer
```

The ESP32 acts as both a Bluetooth peripheral (receiving from iPhone) and USB
HID device (sending to the computer). It translates touch input and keystrokes
into standard HID keyboard/mouse commands.

## Technical Details

- **Protocol**: Batched TLV command frames over Bluetooth LE, with compatibility for the original 3-byte protocol
- **Battery**: ESP32 powered by target computer via USB
- **Compatibility**: Works with any OS that supports USB HID (Windows, macOS, Linux, etc.)
- **USB recovery**: Idle keyboard reports act as a health check; two consecutive transfer timeouts restart the ESP32-S3 so keyboard and mouse remain available across a host warm reboot. Verified on ASUS ROG Xbox Ally X, including pre-OS input.
- **ESP32-S3-Zero status LED**: The onboard RGB LED reports the complete connection path. Brightness is deliberately restrained. Firmware explicitly selects the GRB order observed on the physically tested board instead of relying on the Arduino-ESP32 Waveshare profile's RGB declaration.

| Indicator | Pattern | Status |
| --- | --- | --- |
| 🟢 Green | Solid | Authenticated Bluetooth and USB HID are both ready |
| 🔵 Blue-cyan | Solid | The PC/USB HID side is ready; Bluetooth is waiting |
| 🟠 Amber | Double blink | Authenticated Bluetooth is connected; USB supplies power but HID is not ready |
| 🔴 Red | Short heartbeat | Neither Bluetooth nor USB HID has a data connection |
| 🟣 Purple | Slow pulse with a dark pause | The physical pairing window is open |
| 🔴 Red | Rapid blink | USB HID is stalled and automatic recovery is about to restart the bridge |

### Direct Bluetooth security

Direct Bluetooth accepts HID input subscriptions only from the selected saved
host. During an open pairing window, a new encrypted peer remains quarantined
until the user separately approves it in an InpuDeck alert; completing the
system Bluetooth pairing is not sufficient. Before approval it receives only
neutral input reports, and its output/control writes are acknowledged without
being applied. A second peer cannot replace an approval already on screen.

Rejecting the alert closes the pairing window and remembers that iOS peer
identifier across launches, so later connection attempts stay blocked without
repeated prompts. Rejected peers are visible in the Bluetooth management sheet
and can be allowed again deliberately. iOS does not expose system-bond removal
to apps, so removing that bond still requires iPhone Settings or the peer's
Bluetooth settings. Already saved destinations reconnect without a new prompt;
selecting a newly discovered destination inside InpuDeck is itself explicit
approval.

### ESP bridge security

Firmware 3.3.0 and newer requires BLE Secure Connections with bonding, MITM
passkey authentication, 128-bit link encryption, and an explicit physical
pairing window. Both the command characteristic and the app's readiness probe
require authenticated encryption, and the firmware independently rejects HID
commands unless the current connection is bonded, encrypted, and authenticated.
The installer gives every adapter a random passkey. Firmware 3.3.7 adds a stored
random static BLE identity; a full reflash or explicit passkey rotation replaces
both identity and passkey and clears old bonds, preventing iOS from reattaching
the old system pairing label. Mutable USB-serial commands require the physical
BOOT window. InpuDeck refuses the legacy service shape instead of
silently operating against an unsafe adapter. Firmware 3.3.3 also exposes its
stored UTF-8 name through a read-only authenticated characteristic, avoiding a
stale CoreBluetooth name after renaming or reflashing. Unsafe or incompatible
firmware blocks input and raises a visible warning even outside developer mode.

> [!CAUTION]
> Firmware through 3.2.2 has no pairing protection and must be fully reflashed;
> `--skip-flash` cannot upgrade it. Radio authentication does not protect a
> board from an attacker with physical USB/BOOT access, who can replace the
> firmware. Production hardware that must resist physical tampering additionally
> needs an irreversible ESP32 Secure Boot and flash-encryption provisioning
> process; those eFuse operations are intentionally not enabled on development
> boards by this installer.

## Project Structure

```
InpuDeck/
├── InpuDeck/           # Main iOS SwiftUI app
│   ├── ContentView.swift       # Main UI with keyboard and trackpad
│   └── BLEKeyboardBridge.swift # Bluetooth LE communication
├── Shared/                     # HID mapping and typing plan
└── inpudeck_bridge/    # ESP32-S3 Arduino firmware
    └── inpudeck_bridge.ino
```

## Use Cases

- **Smart TV control** - Type passwords, search content, and navigate streaming apps naturally
- **Home theater PC** - Control media centers from your couch
- **Presentation remote** - Wireless control during demos

## Troubleshooting

**ESP32 not detected by computer:**
- Ensure you selected "USB-OTG (TinyUSB)" mode before uploading
- Try a different USB cable (some are power-only)
- Check that your ESP32-S3 board supports native USB

**iPhone app won't connect:**
- Make sure ESP32 is powered and running (check serial monitor)
- Restart Bluetooth on iPhone
- Ensure you're within Bluetooth range
- Analyse with BLE monitoring tools

**Typing feels laggy:**
- Move iPhone closer to ESP32
- Check for Bluetooth interference from other devices
- Restart both devices

**Keyboard or mouse stops working after a host reboot:**
- Use a current firmware build; it includes automatic recovery for stalled USB HID transfers
- If recovery still fails, press the ESP32 RESET button once and report the host model and firmware build

## Contributing

This project solves a real problem with a unique hardware approach. Contributions welcome for:

- Additional gesture support
- Protocol optimizations  
- Support for other microcontrollers
- Android app version

## Roadmap

- **Bluetooth security hardening (3.3.2-3.3.11 device validation)** - Direct Bluetooth input-report reads are isolated as well as notifications: the selected host sees the current report, while another bonded host receives a same-size neutral report. Version 3.3.11 additionally quarantines every new incoming host behind an explicit InpuDeck approval alert, remembers rejection across launches, blocks competing approval attempts, and exposes a deliberate unblock control. Release firmware and installer executables carry Sigstore build-provenance attestations, and the bootstrap verifies the selected tag's workflow identity before running downloaded Python. The optional BlueZ 5.87 address-resolution startup hook is fail-closed and scoped to exact root-controlled iPhone identity addresses instead of enumerating every dual-mode bond. Direct Linux mutations require the exact paired, unblocked target, while the optional reconnect service runs unprivileged with a read-only filesystem/home, no capabilities or privilege escalation, private devices, and D-Bus-only socket access. The planned code hardening is complete; validate app approval/rejection/unblock, existing-host reconnect, the scoped hook, and the sandboxed user service on physical devices.
- **Secure ESP enrollment and bonded commands (3.3.0-3.3.7 device validation)** - The implementation now requires BLE Secure Connections, authenticated encrypted characteristics, a unique installer-generated passkey, a physical pairing/provisioning window, preserved bonds, deliberate bond reset, a protected app readiness probe, and a provisioned random static BLE identity. Full provisioning rotates the BLE identity with the passkey so iOS cannot silently reuse the old system pairing label; the rotated identity and provisioned name are verified in the iOS system pairing list, and name-only serial writes are physically gated as well. The authenticated adapter-name channel avoids stale CoreBluetooth names inside InpuDeck, while unsafe or unknown firmware produces a blocking popup. Legacy firmware binaries, installers, and firmware-specific Actions artifacts predating 3.3.0 have been removed; historical source, tags, workflow runs, and IPA releases remain available, so rebuilding an unsafe version requires a deliberate source build. Remaining before marking this complete: validate unattended reconnect, reboot recovery, rejected unknown clients, pairing-window timeout, bond reset, and the unsafe-firmware popup on physical devices.
- **ESP32-S3-Zero status LED (3.3.9 device validation)** - The firmware now distinguishes a complete BLE-to-USB path, PC/USB only, authenticated Bluetooth with power-only USB, neither data side, the physical pairing window, and USB recovery. Physical testing showed that the onboard LED accepts GRB data despite the Arduino-ESP32 Waveshare board profile declaring RGB. Version 3.3.8 therefore made no electrical change; 3.3.9 overrides the profile with the observed GRB order and polls TinyUSB's authoritative mount state so moving from a power-only cable to a data host cannot leave the indicator stuck in BLE-only mode. Confirm every corrected color, transition, and pattern on the onboard WS2812 before marking it complete.
- **Landscape keyboard swipe pointer** - On the landscape keyboard, distinguish a key press or long press from a drag that crosses a movement threshold. A qualifying drag that begins on an ordinary key should cancel/defer that key action and transition into relative touchpad control; normal taps and long presses must retain their current behavior. Add left- and right-click touch zones beside the `input-keyboard-tools` slider.
- **Air mouse** - Add an optional two-dimensional pointer mode driven by `CoreMotion` device motion (primarily gyroscope rotation rate, with sensor fusion rather than raw accelerometer-only input). Include activation/recentering, sensitivity, dead-zone, smoothing, acceleration, axis inversion, orientation handling, and convenient click controls, and keep behavior consistent across Direct BLE and ESP32 transports.
- **Adaptive layouts for iPhone Duo and iPad (wishlist)** - Once the iPhone Duo simulator is available, verify the app in full-screen and half-screen configurations. Also test representative iPad sizes and multitasking widths (Split View and Stage Manager), then consider layouts that make better use of the additional space.

### Ideas / won't do

- **LAN host mode (formerly proposed for v3)** - The current Direct BLE and ESP32 transports already meet the maintainer's needs, so a LAN transport, exact Unicode entry, and bidirectional clipboard are not planned. Reconsider only if future users demonstrate a concrete use case that the existing transports cannot reasonably cover.

See [direct BLE HID research and implementation plan](docs/direct-ble-hid.md) for
the CoreBluetooth approach and implementation history, and
[direct Bluetooth HID on Linux](docs/linux-direct-hid.md) for pairing, HID-only
connection, and reconnect on a BlueZ desktop. Direct mode is the default for a
new installation. macOS and Windows validation is complete; further Linux
helper and distribution-specific testing is optional.

### Completed in iOS 3

- **InpuDeck identity** - Renamed the project and app from ESPRemoteControl to InpuDeck in 3.0.0, reflecting that direct Bluetooth HID is now a first-class transport and the ESP32 bridge is optional.
- **Direct BLE HID on macOS and Windows** - Pairing, keyboard and mouse input, reconnect, and host switching are stable in repeated physical testing. Windows works without repeated pairing through the companion BlueVein improvements. Linux input is functional, with optional helper and distro-specific follow-up retained outside the release roadmap.
- **Global keep-awake option** - Since 3.0.3, an app-wide setting can keep the display awake independently of Mouse Jiggler while InpuDeck is active. Backgrounding the app or disabling the option restores normal system sleep behavior. Confirmed on-device.
- **Expert mode** - Added in 3.0.4 and refined through 3.0.8. It removes optional guidance, action labels, touchpad text, the composer placeholder, and bottom-navigation captions while preserving keyboard legends and operational status. Confirmed on-device.
- **Installer-configurable ESP32 identity** - Added in 3.1.0. The firmware stores a validated UTF-8 bridge name in NVS, and the release installer can flash and name an adapter without recompilation. Releases 3.1.1-3.1.6 added the one-command bootstrap, scoped Linux serial permissions, an explicit RESET/re-enumeration flow, runtime USB CDC, resilient port discovery, a no-reflash recovery path, and the CDC control-line handshake required for bidirectional provisioning.
- **Universal multi-connect** - Completed in 3.2.0-3.2.2. One destination selector manages any mix of saved Direct Bluetooth devices and multiple named ESP32 bridges, releases held input before switching routes, and reconnects each adapter through its own CoreBluetooth identity. Pairing and discovery remain in the adjacent action menu, while protocol icons distinguish ESP and Direct Bluetooth routes. Two-adapter discovery, switching, reconnect, and USB HID input were confirmed on-device.

### Completed in iOS 2.2

- **Hardware controls** - System, media, audio, microphone-mute, and numpad keys are available on the Tools tab.
- **QR and barcode scanner** - Separate QR/2D and barcode modes can fill the composer or type automatically, with optional batch scanning.
- **Mouse Jiggler** - Configurable foreground pointer movement runs at the selected interval, prevents display sleep while active, warns about battery use, and disables itself when the app enters the background.
- **Multi-touch trackpads** - Both input screens support two-finger scrolling/right click, pinch-to-zoom, tap-drag, edge scrolling, and three-finger middle click. The layout, scanner button, and middle-click behavior were confirmed on-device in 2.2.9 (53).
- **Russian characters from the Ukrainian keyboard** - `Alt+і/є/'/ї` sends AltGr combinations for `ы/э/ё/ъ`, updates the visible legends while Alt is active, and uses Shift for uppercase. Automatic text typing recognizes the same letters. Confirmed on-device in 2.2.14 (58); the host's Ukrainian layout must provide these AltGr levels.
- **Dual keyboard legends** - Character keys show both EN and UA legends, with settings for visibility, portrait-only hiding, and scale. Confirmed on-device in 2.2.14 (58).
- **Native iOS dictation** - The input composer accepts voice typing from the system iOS keyboard and correctly forwards committed text and later dictation corrections. Confirmed on-device in 2.2.14 (58).
- **Background Jiggler investigation** - Continuous timer-driven movement is not reliable in the background on iOS 17–25. The supported foreground implementation keeps the screen awake and was confirmed on-device in 2.2.14 (58); see [the feasibility notes](docs/background-mouse-jiggler.md).

## Origins and acknowledgements

This repository is based on
[ESPRemoteControl](https://github.com/KoStard/ESPRemoteControl) by
[Ruben Kostandyan](https://github.com/KoStard). It has since evolved with
direct Bluetooth HID, multiple-host support, expanded keyboard and trackpad
controls, and an optional ESP32 USB bridge.

The ESP32 firmware uses
[NimBLE-Arduino](https://github.com/h2zero/NimBLE-Arduino), distributed under
the Apache License 2.0.

The app icon incorporates the MIT-licensed `keyboard` outline from
[Tabler Icons](https://github.com/tabler/tabler-icons). See
[the attribution notices](ATTRIBUTIONS.md) for details about the original
project and third-party components.

## License

The original repository describes the project as MIT-licensed but does not
currently include the referenced license file. See
[the attribution notices](ATTRIBUTIONS.md) for provenance and licensing
details that could be verified.

---

**Star this repo if it saved you from hunting for a physical keyboard! ⭐**
