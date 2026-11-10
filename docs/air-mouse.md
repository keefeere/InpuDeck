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
| Tip the phone slowly, without a swing | The cursor still travels: the angle the screen has risen to is read from gravity |
| Phone lying flat on a table | The direction the screen faces steers, which is the downhill side of it, the bottom edge |
| **Скинути нахил** | Tracking restarts from nothing where the phone currently is (an icon alone in expert mode) |
| Click buttons | The same HID buttons as the trackpad, on either transport, filling the Air mouse field so they sit under the thumb |

Settings → **Air mouse** has separate sensitivity for the two axes, a slow-movement
gain, an acceleration gain, a movement threshold, a dead zone and per-axis
inversion. The sensitivity sliders run from 0 % to 100 % of the base gain, where
50 % is the gain a hand steers by, and “Where the numbers come from” states what a
percentage is worth in pointer units per degree, so the slider can be picked from a
number rather than by feel. A stored setting from the old 40…900 % scale is carried
across once: 750 % there is 50 % here.
**Inversion is on out of the box**: pushing the top edge
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
  and the screen's downhill side steers instead — the direction the bottom edge
  points, which is the same direction a screen facing slightly upward faces.
  Taking the *top* edge there pointed the heading the other way round, and the
  tip axis turned 180° at the threshold, so a phone held almost flat started
  answering a tip up with a tip down. The threshold is applied before
  normalising, or it could only ever catch a phone lying perfectly flat, and
  the axis is the same on both sides of it.
- **A slow tip is worth movement, and gravity is what sees it.** The gyroscope
  reports how fast the phone is turning, so a tip led evenly at 0.17 rad/s is
  worth as much cursor travel as a fast one, and a start threshold above it
  reads that tip as rest — the maintainer's report was that leading the phone
  up slowly moved nothing at all. The angle the screen faces upward is
  `-gravity.z`, so the change of `asin` of it is the tip in radians, on the
  same sign the gyroscope axis gives for it. The engine takes whichever of the
  two sensors saw the larger rate, so a fast tip is not counted twice and a
  slow one still travels. **“Плавний рух”** scales that channel; at 0 % the
  axis is gyroscope-only.
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
  the one an axis at rest must exceed to start (`0.12` rad/s); an axis already
  moving only has to stay above `0.08`. A hand that leads the phone evenly sits
  around 0.15 rad/s, so it is admitted, while the tremor of a held hand, near
  0.05 rad/s, is not. **“Поріг руху”** moves that start threshold over
  0…0.5 rad/s, and the keep threshold follows it at two thirds.
- **A movement leaves the pointer where the hand left it.** Fused rotation does
  not stop dead at zero when the hand stops: it tails off through zero and keeps
  a small opposite reading for a few tenths of a second. Integrating that tail
  was the maintainer's report that a 30° tip, held, walked the cursor back on its
  own without the phone moving. For `stopDamping` = 0.35 s after a movement, an
  opposite-sign reading under `undershootLimit` = 0.35 rad/s is treated as the
  sensor settling on the attitude the hand already put there, not as a turn, so
  it sends nothing. A turn that really goes back is far above that and moves the
  pointer on the sample after it.
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
  `basePointerUnitsPerRadianPerSecond = 5400`, which is 5400 units per radian,
  about 94 units per degree, at 100 %. On a host that maps one pointer unit to
  one pixel, crossing a 2560 px screen width costs this much phone rotation:

  | Sensitivity | Units per radian | Units per degree | Rotation to cross 2560 px |
  | --- | --- | --- | --- |
  | 100 % (slider top) | 5 400 | 94.3 | 27° |
  | 50 % (default) | 2 700 | 47.1 | 54° |
  | 25 % | 1 350 | 23.6 | 109° |
  | 10 % | 540 | 9.4 | 272° |

  The maintainer's 750 % on the old scale is this 50 %: the base gain grew
  fifteenfold so the setting a hand actually steers by sits in the middle of
  the slider. The host's own pointer acceleration multiplies this: KDE/Plasma
  profiles and per-device `kcminputrc` entries are outside the app, so measure
  one known rotation on the real screen before trusting the table. A fast swing
  also gets the acceleration gain — up to `1 + acceleration` = 1.8× once the
  turn reaches `accelerationReference` = 2 rad/s, **“Прискорення”** over
  0…100 % of `maximumAcceleration` = 2.0 — which is what is meant to cross a
  screen with a flick instead of a walk.
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
fallback and the tip axis staying the same sign across the threshold that
triggers it, tremor rejection and the start/reengage pair, the fractional
carry, report splitting and the signed-byte clamp, smoothing convergence,
acceleration gain, separate axis sensitivity, the shipped gains the table above
prints, an even tip moving the pointer through gravity while the gyroscope
alone sends nothing, the gravity tip arriving on the same sign as the gyroscope
tip, the settling tail after a stop staying out of the pointer and walking it
back when the damping is off, a deliberate turn back moving inside that window,
the idle re-anchor, the activation hold, re-centring and gravity
estimation.

Physical-device behaviour — the permission prompt, real hand tremor, the feel
of the two gains, a phone in a pocket, Bluetooth latency — is not covered by
CI. iOS builds are delivered to test devices through SideStore, so a build
number bump and a published SideStore source entry are part of the feature, not
part of a merge.
