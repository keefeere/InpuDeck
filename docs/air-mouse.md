# Air mouse

Rotate the phone and the host cursor moves. The surface lives on the Input tab,
where the trackpad was: choose **Air mouse** in the *Поверхня курсора* picker,
and the same three mouse buttons keep working.

## What it does

| Gesture | Result |
| --- | --- |
| Turn the phone to the side | The cursor travels the same way, at the same speed whatever angle the phone is held at |
| Tip the phone over the level line drawn across its screen | The cursor moves up and down, at full speed at any roll and any tilt |
| Push the top edge away, or turn the phone sideways | The cursor goes that way: the vertical ships inverted, the horizontal does not |
| Hold still | The cursor stops, and a moment later the filters clear themselves |
| Tip the phone slowly, without a swing | The cursor still travels: the angle the screen has risen to is read from gravity |
| Phone lying flat on a table | The cursor still travels sideways; there is no up-and-down axis to be found in a phone that faces the sky straight up |
| **Скинути нахил** | Tracking restarts from nothing where the phone currently is (an icon alone in expert mode) |
| Click buttons | The same HID buttons as the trackpad, on either transport, filling the Air mouse field so they sit under the thumb |

Settings → **Air mouse** has separate sensitivity for the two axes, a slow-movement
gain, an acceleration gain, a movement threshold, a dead zone and per-axis
inversion. The sensitivity sliders run from 0 % to 100 % of the base gain, where
50 % is the gain a hand steers by, and “Where the numbers come from” states what a
percentage is worth in pointer units per degree, so the slider can be picked from a
number rather than by feel. A stored setting from the old 40…900 % scale is carried
across once: 750 % there is 50 % here.
**Only the vertical is inverted out of the box**: pushing the top edge of the phone
away sends the pointer that way, and turning the phone sideways sends it the way the
phone turned. Both stay toggleable; a tip that raises the screen is the one gesture
that read the other way for a release. The toggles are read from `airMouseInvertXV2`
and `airMouseInvertYV5`, because
`@AppStorage` answers from a stored value before it looks at the default in code:
a phone that has answered a switch once goes on answering it whatever the source
says, which is how one inverted default survived three releases of being switched
off in code. A changed default only reaches a device in use as a new key. The
feature is off by default and the trackpad stays available while it is on; in
expert mode the pad hides its
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
  `horizontalAxis` is the gravity direction itself; the tip axis is the one
  direction that is level with the ground *and* lies inside the plane of the
  screen, because turning the screen's elevation up or down is a turn about
  exactly that, so `verticalAxis` is `(-gravity.y, gravity.x, 0)` normalised.
  Turning the phone right is therefore worth the same cursor travel whether the
  phone is held upright, cradled against the chest or laid back on a desk.
  Deriving the axes from the plane of the screen instead makes that worth fall
  off with the hold, which is what felt sluggish in 3.5.0: reaching the edge of
  the screen meant rotating the whole phone.
- **The tip axis is read from gravity alone, so nothing is lost near flat.** The
  tempting way to find a level direction inside the screen is to take the
  heading — which way the screen faces — and stand at right angles to it. That
  works while the phone is upright-ish and collapses as the phone comes toward
  flat, where the heading is defined but buried in noise, and the cure people
  reach for is to invent a heading from the edge the screen is tipped toward.
  Measured against the rate a screen elevation change really moves the pointer
  at, an invented heading is what pointed the axis away from the tip: with the
  phone cradled at 30° of roll, 13 % of the tip never reached the pointer, at
  60° half of it, and held in landscape — the grip the tall click buttons
  invite — none of it, so the cursor sat still while the screen swung through
  twenty degrees. `(-gravity.y, gravity.x, 0)` is level because it is square to
  gravity and inside the screen because it is square to the screen normal, so it
  is exact at every pitch and every roll and asks for no heading at all. Only
  gravity running exactly along the screen normal is given up, within 0.02 of
  it, where no direction inside the screen is horizontal rather than another:
  the adapter holds the axis it last had through that one sample, and the
  sideways axis is unaffected, so a table phone still steers left and right
  while it waits to be lifted.
- **One tip keeps going one way, through the horizon.** That axis is gravity's
  in-screen direction turned a quarter turn, and a quarter turn of a direction
  that is shrinking to nothing comes back pointing the other way: as the phone
  passes from facing the user to facing the sky, the axis jumps half a turn in a
  single sample. The maintainer's gesture is the one that walks straight through
  it — the phone led from thirty degrees below the horizon to thirty above,
  without pausing — and the pointer rose below the horizon, then walked back down
  as soon as the phone came up past flat. It was not an inversion setting and no
  gain fixed it, because the *other* reading of the tip reversed in the same
  sample: the angle over the horizontal plane is `90 − |tip|`, which reaches its
  ninety degrees and turns around. Both sensors of one rotation said the hand had
  changed its mind. So the engine keeps the axis from the last sample that could
  name one, and reads the slow channel along that same axis, until the phone has
  been still long enough to have been put down and aimed again — see
  `axisScreenShare` and `tipAxis(for:)`. A phone tipped end over end is not kept
  on a stale axis: passing flat is recorded, and an axis named on the far side
  that agrees with the phone's direction is adopted at once.
- **A slow tip is worth movement, and gravity is what sees it.** The gyroscope
  reports how fast the phone is turning, so a tip led evenly at 0.17 rad/s is
  worth as much cursor travel as a fast one, and a start threshold above it
  reads that tip as rest — the maintainer's report was that leading the phone
  up slowly moved nothing at all. Gravity is itself the record of the tip: it
  swung from where it was to where it is, and the cross product of two readings
  is the turn that took it there, with a magnitude of `sin` of the angle — which
  for the fractions of a degree a sample is worth is the angle, so the gain of
  the reading is one. Read along the pointer's axis it is the same quantity the
  gyroscope reports, which is why the two can differ in size and never in
  direction; an angle over the horizontal plane can, and did. The engine takes
  whichever of the two sensors saw the larger rate, so a fast tip is not counted
  twice and a slow one still travels. **“Плавний рух”** scales that channel; at
  0 % the axis is gyroscope-only.
- **Gravity is fused by iOS, not estimated here.** One `CMDeviceMotion` stream
  at 120 Hz carries the fused `gravity` vector and the rotation rate with the
  same timestamp, so the axis pair and the spin belong to one instant. Before
  the first sample the frame is seeded from `AirMouseGravityEstimator
  .initialGravity` (gravity for a phone held upright), so a fresh activation
  starts from a sensible frame instead of inheriting an angle from the previous
  session. Linear acceleration never reaches the host: carrying the phone across
  the room produces no pointer reports. `AirMouseGravityEstimator` stays for the
  seed and the offline tests of a filtered gravity path. A gap in the stream
  longer than one sample is treated as a fresh start, and the angle the tip is
  measured against is cleared with the rest of the filters, so a pause the phone
  spent changing hands cannot arrive as one enormous step.
- **The sample rate is the stream's, and the filters' lag is time.** The motion
  stream runs at 120 Hz rather than 60, which is half the latency between the
  wrist and the cursor on a screen that shows every report. That makes the
  sample count meaningless as a unit, so the smoothing slider is read as a share
  of the previous sample kept per sixtieth of a second and converted by the real
  interval between samples: the same setting damps the same length of time at
  any rate, and one test proves it by feeding an identical tip at 30 Hz and at
  240 Hz and requiring the pointer to travel the same distance.
- **What a slow link would look like, and where to look for it.** Pointer motion
  reaches Bluetooth as one relative report per sample, so the report rate follows
  how fast the cursor is actually travelling, not the sensor rate — crossing a
  2560-pixel screen costs 2560 reports at any rate. Relative reports stack up in
  `HIDReportQueue` faster than a reluctant link drains it, and because they are
  relative, a deep queue does not drop motion, it plays it back late: the cursor
  goes on walking after the hand has stopped. The transport's status line carries
  `queued=` for exactly this; if it climbs while the cursor lags behind the hand,
  the fix is to merge the un-sent pointer motion in the queue rather than to slow
  the sensor down.
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
  own without the phone moving. A reading counts as that tail, and sends nothing,
  only when it is opposite in sign to the axis's last movement, under
  `undershootLimit` = 0.35 rad/s, under `undershootShareOfTurn` = 35 % of how wide
  that turn was, shrinking rather than growing on the raw sensor, and inside
  `stopDamping` = 0.25 s of the last movement **of that axis** — a hand still
  travelling sideways cannot keep a vertical turn back blocked. A turn the hand
  builds up out of nothing grows from sample to sample, so it is never taken for a
  tail; a turn that holds one steady speed gives up the quarter second the window
  covers and walks the pointer from there.
- **A still phone cleans up after itself, once it has moved.** Movement comes
  from rotation rate, so a tilt that is merely being held has never contributed
  anything; what a still phone can leave behind is residue in the smoother and a
  fraction of a unit the last report could not carry. After 0.8 s of stillness
  both are dropped, and `isSettled` says so. Clearing on a phone that has not
  moved since it started wipes the ramp a slow tip builds up, which is how the
  gravity channel reaches the start threshold at all, so the clean-up waits for
  a movement to have happened.
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
kept "running" in the background would be a lie. The tab is part of that rule and
not a detail: the surface choice is a setting that outlives every tab switch, and
the Keyboard tab carries its own trackpad, so a gyroscope that ignores the tab
moves the same pointer as the trackpad the user is looking at — which is what
happened until both were guarded.

## Testing

Unit coverage for the engine is in `Tests/AirMouseEngineTests.swift`: the
pointer frame following gravity rather than the phone, a sideways turn being
worth the same at every roll angle, a tip staying a tip, the flat-table
fallback and the tip axis staying the same across the threshold that triggers it
for both signs of `gravity.y` and both sides of the screen, tremor rejection and
the start/reengage pair, the fractional
carry, report splitting and the signed-byte clamp, smoothing convergence,
smoothing lagging the same length of time at thirty and at two hundred and
forty samples a second, the tip axis being level and inside the screen at every
roll and every tilt, a rolled phone near flat carrying the whole of a tip and a
phone lying perfectly flat giving no tip axis at all, the
acceleration gain, separate axis sensitivity, the shipped gains the table above
prints, an even tip moving the pointer through gravity while the gyroscope
alone sends nothing, both readings of a tip agreeing in direction and in rate at
every screen angle from −89° to +89°, one continuous tip from below the horizon to
above it never turning the pointer around, the gravity tip arriving on the same sign as the gyroscope
tip, the settling tail after a stop staying out of the pointer and walking it
back when the damping is off, a deliberate turn back moving inside that window, a
steady slow turn back arriving once the window is behind it, a turn built up out
of nothing moving at once, and sideways travel not keeping a vertical turn back
blocked, the idle re-anchor, the activation hold, re-centring and gravity
estimation.

Physical-device behaviour — the permission prompt, real hand tremor, the feel
of the two gains, a phone in a pocket, Bluetooth latency — is not covered by
CI. iOS builds are delivered to test devices through SideStore, so a build
number bump and a published SideStore source entry are part of the feature, not
part of a merge.
