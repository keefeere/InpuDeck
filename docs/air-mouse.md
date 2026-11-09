# Air mouse

Rotate the phone and the host cursor moves. The surface lives on the Input tab,
where the trackpad was: choose **Air mouse** in the *Поверхня курсора* picker,
and the same three mouse buttons keep working.

## What it does

| Gesture | Result |
| --- | --- |
| Turn the phone to the side | The cursor travels the same way, at the same speed whatever angle the phone is held at |
| Tip the phone over its heading | The cursor moves up and down |
| Hold still | The cursor stops, and a moment later the filters clear themselves |
| Phone lying flat on a table | The direction the top edge points at steers, instead of a heading the screen cannot have |
| **Скинути нахил** | Tracking restarts from nothing where the phone currently is (an icon alone in expert mode) |
| Click buttons | The same HID buttons as the trackpad, on either transport |

Settings → **Air mouse** has separate sensitivity for the two axes, a dead zone
and per-axis inversion; the sensitivity sliders run from 40 % to 900 % of the
base gain, and “Where the numbers come from” states what a percentage is worth in
pointer units per degree, so the slider can be picked from a number rather than
by feel. **Inversion is on out of the box**: pushing the top edge
of the phone away moves the cursor that way, and the two toggles switch it off
for a hand that prefers the other convention. The feature is off by default and
the trackpad stays available while it is on; in expert mode the pad hides its
captions and the reset button's label, but keeps showing anything that is
actually wrong. Scrolling stays with the trackpad: the air mouse moves the
pointer and clicks, it does not turn a wheel.

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

The accelerometer is used only to establish where gravity is and where the
screen faces. Linear acceleration never reaches the host: moving the phone
across the room produces no pointer reports.

## Where the numbers come from

`Shared/AirMouseEngine.swift` holds all of it — the pointer frame, gravity
estimation, thresholds, smoothing, acceleration and report splitting. It
imports Foundation only, so it is compiled and tested with plain `swiftc`:

```bash
./scripts/test-direct-hid.sh
```

- **Rotation is read about the world's axes, not the phone's.** Gravity gives
  the world's vertical, which is the axis a sideways wrist turn spins about, so
  `horizontalAxis` is the gravity direction itself; the screen normal gives the
  heading the phone points at, and the axis at right angles to it, level with
  the ground, is `verticalAxis`. Turning the phone right is therefore worth the
  same cursor travel whether the phone is held upright, cradled against the
  chest or laid back on a desk. Deriving the axes from the plane of the screen
  instead makes that worth fall off with the hold, which is what felt sluggish
  in 3.5.0: reaching the edge of the screen meant rotating the whole phone.
- **The heading is given up when it is noise.** With the phone nearly flat the
  screen normal points almost straight up, so which way it faces is defined but
  unmeasurable, and noise in the heading is noise in the cursor. Below a
  quarter of its full size the horizontal component of the normal is discarded
  and the top edge of the phone steers instead. The threshold is applied before
  normalising, or it could only ever catch a phone lying perfectly flat.
- **Gravity is fused by iOS, not estimated here.** One `CMDeviceMotion` stream
  at 60 Hz carries the fused `gravity` vector and the rotation rate with the
  same timestamp, so the axis pair and the spin belong to one instant. Before
  the first sample the frame is seeded from `AirMouseGravityEstimator
  .initialGravity` (gravity for a phone held upright), so a fresh activation
  starts from a sensible frame instead of inheriting an angle from the previous
  session. Linear acceleration never reaches the host: carrying the phone across
  the room produces no pointer reports. `AirMouseGravityEstimator` stays for the
  seed and the offline tests of a filtered gravity path.
- **Two thresholds, not one.** A dead zone alone turned the cursor into a crawl
  or let tremor through, and the shipped default is now nothing at all — a held
  hand is quieter than any dead zone needs. The threshold that does the work is
  the one an axis at rest must exceed to start (`0.3` rad/s); an axis already
  moving only has to stay above `0.2`, which is what lets a slow deliberate
  turn stay slow instead of breaking into start/stop steps.
- **A still phone cleans up after itself.** Movement comes from rotation rate,
  so a tilt that is merely being held has never contributed anything; what a
  still phone can leave behind is residue in the smoother and a fraction of a
  unit the last report could not carry. After 0.8 s of stillness both are
  dropped, and `isSettled` says so.
- **Each axis has its own gain** because a forearm swing and a wrist tip are
  not the same movement, and one slider would make the comfortable gesture
  twitchy or the wide one useless.
- **Movement is per radian, so sensitivity is a number, not a feel.** The engine
  integrates rotation rate over time, so the cursor travel of a deliberate turn
  is `units per radian × turn angle`. The slider shows a percentage of
  `basePointerUnitsPerRadianPerSecond = 360`, which is 360 units per radian,
  about 6.3 units per degree, at 100 %. On a host that maps one pointer unit to
  one pixel, crossing a 2560 px screen width costs this much phone rotation:

  | Sensitivity | Units per radian | Units per degree | Rotation to cross 2560 px |
  | --- | --- | --- | --- |
  | 100 % | 360 | 6.3 | 408° |
  | 220 % (default) | 792 | 13.8 | 185° |
  | 400 % | 1 440 | 25.1 | 102° |
  | 600 % | 2 160 | 37.7 | 68° |
  | 900 % (slider top) | 3 240 | 56.7 | 45° |

  The host's own pointer acceleration multiplies this: KDE/Plasma profiles and
  per-device `kcminputrc` entries are outside the app, so measure one known
  rotation on the real screen before trusting the table. A fast swing also gets
  the acceleration gain — up to `1 + acceleration` = 1.8× once the turn reaches
  `accelerationReference` = 2 rad/s — which is what is meant to cross a screen
  with a flick instead of a walk.
- **Reports are split.** A report descriptor carries one signed byte per axis,
  so a fast flick leaves as several reports in the same sample and the host's
  own pointer acceleration cannot be used as an escape hatch.

The stream runs only while the Input tab is on screen and the app is active.
Backgrounded iOS samples slowly and throttles them to zero, so a surface that
kept "running" in the background would be a lie.

## Testing

Unit coverage for the engine is in `Tests/AirMouseEngineTests.swift`: the
pointer frame following gravity rather than the phone, a sideways turn being
worth the same at every roll angle, a tip staying a tip, the flat-table
fallback and the threshold that triggers it, tremor rejection and the
start/reengage pair, the fractional carry, report splitting and the signed-byte
clamp, smoothing convergence, acceleration gain, separate axis sensitivity,
the idle re-anchor, the activation hold, re-centring and gravity estimation.

Physical-device behaviour — the permission prompt, real hand tremor, the feel
of the two gains, a phone in a pocket, Bluetooth latency — is not covered by
CI. iOS builds are delivered to test devices through SideStore, so a build
number bump and a published SideStore source entry are part of the feature, not
part of a merge.
