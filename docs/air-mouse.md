# Air mouse

Tilt the phone and the host cursor moves. The surface lives on the Input tab,
next to the trackpad: choose **Air mouse** in the *Поверхня курсора* picker, and
the same three mouse buttons keep working.

## What it does

| Gesture | Result |
| --- | --- |
| Tilt the phone | The cursor moves in the direction the screen faces |
| Turn the phone around | The screen becomes the other side of the plane, so the cursor reverses instead of jumping |
| Hold still | The cursor stops, including while the phone lies flat on a table |
| **Скинути нахил** | The tilt currently held becomes the new centred position |
| Click buttons | The same HID buttons as the trackpad, on either transport |

Sensitivity, dead-zone width and per-axis inversion are in **Settings → Air
mouse**. The feature is off by default and the trackpad stays available while
it is on. Scrolling stays with the trackpad: the air mouse moves the pointer and
clicks, it does not turn a wheel.

## Permissions and hardware

The gyroscope needs the **Motion & Fitness** permission. iOS asks once the
first time the surface starts and never asks again; if it was refused, the
stream stays silent rather than reporting an error, so the surface waits for a
sample for two seconds and then says so and points at
**Settings → Privacy & Security → Motion & Fitness**. Resetting the permission
means deleting and reinstalling the app.

Devices without a gyroscope — the original iPad and every iPod touch — report
that the hardware is missing. There is no accelerometer-only fallback; the
trackpad is the pointer on those devices.

The accelerometer is used only to establish where gravity is. Linear
acceleration never reaches the host: moving the phone across the room produces
no pointer reports, which is the difference between an air mouse and a
gyroscope that has not been given a plane to work in.

## Where the numbers come from

`Shared/AirMouseEngine.swift` holds all of it — axis derivation, gravity
estimation, the dead zone, smoothing, acceleration and report splitting. It
imports Foundation only, so it is compiled and tested with plain `swiftc`:

```bash
./scripts/test-direct-hid.sh
```

- **Screen plane from gravity, not from yaw.** The pointer axes are the gravity
  vector projected onto the screen and the axis perpendicular to it on-screen.
  Because gravity is in both axes, the in-plane tilt is proportional to the
  sine of the tilt angle, which is exactly what makes a tilt feel like a tilt
  at any yaw — the cursor speed does not depend on which way the phone faces
  the room. Yaw, pitch and roll never enter the calculation, so there is no
  axis whose sign flips with orientation and no gimbal lock to design around.
- **Gravity is estimated, not read.** The accelerometer is sampled at 20 Hz and
  averaged over 0.5 s, then blended with a time constant of 1.5 s. A phone
  already tilted when the surface starts reports no movement; only a change in
  tilt does.
- **A dead zone needs hysteresis.** The tremor of a held phone is the same
  order of magnitude as the tilt that should start a slow move. A single
  threshold therefore turns the cursor into a crawl. A slow move starts only
  above a second, higher threshold, and a move that has started continues above
  a lower one; the absorbed rate is also carried between samples so tremor
  cannot accumulate into drift.
- **Reports are split.** A report descriptor carries one signed byte per axis,
  so a fast flick becomes several reports in the same sample and the host's own
  pointer acceleration cannot be used as an escape hatch.

The stream runs only while the Input tab is on screen and the app is active.
Backgrounded iOS samples slowly and throttles them to zero, so a surface that
kept "running" in the background would be a lie.

## Testing

Unit coverage for the engine is in `Tests/AirMouseEngineTests.swift`: axis
derivation including a 180° flip, roll invariance, tremor rejection, the
fractional carry, report splitting, acceleration, inversion, the activation
hold, gravity estimation and every holding orientation.

Physical-device behaviour — the permission prompt, real hand tremor, a phone in
a pocket, Bluetooth latency — is not covered by CI. iOS builds are delivered to
test devices through SideStore, so a build number bump and a published
SideStore source entry are part of the feature, not part of a merge.
