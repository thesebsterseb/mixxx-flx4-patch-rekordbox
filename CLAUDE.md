# CLAUDE.md — project context

Handoff notes for continuing this work in Claude Code. Everything below was
established in a prior session; treat it as verified unless marked otherwise.

---

## 1. Goal

Make the jog wheels on a **Pioneer DDJ-FLX4** usable for beatmatching in
**Mixxx** on a **Raspberry Pi 3** (moving to a Pi 4 later).

Symptom as originally reported: nudging the *side* of the jog wheel (not the
top) pushes the track much further than intended, and the rate change persists
noticeably longer than the touch — measured by the user at >0.3 s. Aligning two
running tracks is effectively impossible. **The same behaviour occurs on
Ubuntu**, which was the clue that it is not Pi-specific.

Top-of-platter scratching feels fine and is not part of the problem.

---

## 2. Root cause (verified against Mixxx source)

The FLX4 mapping's `jogTurn` branches on scratch state:

```js
if (engine.isScratching(deckNum)) {
    engine.scratchTick(deckNum, newVal);      // top of platter — alpha-beta filter, feels good
} else {
    engine.setValue(group, "jog", newVal * this.bendScale);   // side of platter — the problem
}
```

The `[ChannelN],jog` path runs through `RateControl::getJogFactor()`, which
pushes the value through `Rotary::filter()` — a **25-tap moving average**,
evaluated **once per audio buffer**. Confirmed present in `ratecontrol.cpp` on
branches **2.3, 2.4, 2.5 and main** (`m_pJogFilter->setFilterLength(25)`), so
this affects every Mixxx version in play here.

Consequences:

- Only 1/25 of the first movement reaches the rate on the first buffer → slow ramp-up.
- The value keeps being averaged in for 25 more buffers after you stop → the tail.
- **The smoothing window in time is `25 × audio buffer period`.**

| Audio buffer | Jog tail |
|---|---|
| 46.4 ms | ~1160 ms |
| 23.2 ms | ~580 ms |
| 11.6 ms | ~290 ms |
| 5.8 ms  | ~145 ms |

This explains why lowering `bendScale` (0.8 in the stock mapping) does not help:
it shrinks the *magnitude* of the overshoot but not its *duration*.

Upstream issue: <https://github.com/mixxxdj/mixxx/issues/11091> — still open.
Corroborating evidence: the Stanton SCS.1m mapping guide documents different jog
constants per latency setting, and an old Mixxx bug report notes jog behaviour
changing character at 10 ms latency. Same underlying cause: Mixxx's jog path is
measured in audio buffers, not milliseconds.

### The fix

`RateControl` exposes a second additive input, `[ChannelN],wheel`
(`ControlTTRotary`), which is applied **unfiltered** while playing:

```cpp
rate += wheelFactor;
```

Also confirmed present in 2.3 → main. It has no spring-back, so the script must
zero it itself. `ControlTTRotaryBehavior` only overrides
`valueToParameter`/`parameterToValue`, which affect direct MIDI binding — values
written via `engine.setValue()` are stored raw and unclamped. Verified in
`controlbehavior.h`.

So: accumulate ticks in the script, convert to a rate offset on a 20 ms timer
(20 ms is `engine.beginTimer`'s minimum), and set `wheel` to 0 the moment an
interval passes with no ticks. Instant attack, instant release, proportional to
wheel speed.

---

## 3. Repo layout

```
mixxx-pi-tune/
├── CLAUDE.md                                    # this file
├── README.md                                    # user-facing docs
├── install.sh                                   # idempotent installer, run with sudo
├── system/99-audio.conf                         # → /etc/security/limits.d/
├── system/mixxx-cpu-governor                    # → /usr/local/sbin/
├── system/mixxx-cpu-governor.service            # → /etc/systemd/system/
├── mapping/Pioneer-DDJ-FLX4-rekordbox-patch.js  # the actual fix
├── mapping/vendor/                              # OPTIONAL — see §6
└── config/                                      # OPTIONAL — saved ~/.mixxx prefs
```

`install.sh` reads `system/` and `mapping/` by those paths — keep the layout
flat-in-subdirs as above rather than moving files to the repo root.

Usage on a fresh image:

```bash
git clone <repo> ~/mixxx-pi-tune && cd ~/mixxx-pi-tune
sudo ./install.sh
sudo reboot
```

### Design decision worth preserving

The jog fix is **not** an edit to the vendor script. It is a standalone file
appended to the mapping XML's `<scriptfiles>` block. All mapping scripts share
one JS global scope and load in XML order, so the override runs after the vendor
script and reassigns `PioneerDDJFLX4.jogTurn`. It also wraps `init`/`shutdown`
(saving the originals and calling through) so `wheel` is zeroed on load/unload
without touching the original functions.

Result: a Mixxx upgrade can replace `Pioneer-DDJ-FLX4-script.js` entirely and
the fix survives. **Don't refactor this back into in-place sed patches of the
vendor script.**

For the same reason the `(rekordbox patch)` XML is *generated* by `install.sh`, not
committed — committing it would freeze the mapping at one Mixxx version. The
installer copies whatever XML Mixxx currently ships and patches exactly two
things: the `<name>` (append " (rekordbox patch)") and one `<file>` line inserted
before `</scriptfiles>`. This rewriting was tested against a representative
mapping file; the output parses and the override lands after the vendor script.

Everything is **ES5** — Mixxx 2.3 uses QtScript, where `const`/`let`/arrow
functions throw a syntax error and the whole mapping fails to load. Keep it that
way unless the Pi is confirmed on 2.4+ (which uses QJSEngine).

---

## 4. State as of last session

Done on the Pi 3:

- SSH access working.
- CPU governor set to `performance`; confirmed `performance` ×4. Note
  `systemctl disable ondemand` failed — `ondemand.service` doesn't exist on
  this image, which is harmless and is guarded with `|| true` in `install.sh`.

**Target hardware moved to a Pi 4 on Raspberry Pi OS trixie**, where
`cpufrequtils` does not exist: Debian removed the package after bullseye. Step 1
of `install.sh` no longer depends on it — it writes
`/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor` directly via
`system/mixxx-cpu-governor` and persists that with a oneshot unit,
`mixxx-cpu-governor.service` (ordered `After=ondemand.service
cpufrequtils.service` so nothing on either image overwrites it at boot).
`/etc/default/cpufrequtils` is still written *if the file already exists*, which
keeps the old Pi 3 image working. Don't reintroduce a hard `apt-get install
cpufrequtils` — it will fail on trixie.

Not yet done / unverified:

- The mapping override has **not been installed or tested on hardware yet**.
  `bendSensitivity = 0.02` is a calculated starting point, not an empirical one.
- Audio buffer size not yet lowered in Preferences → Sound Hardware.
- `audio` group membership and `ulimit` values not confirmed for user `pi`.
  Caution: the user was operating from a `root@mixxxpi` shell, so an earlier
  `usermod -aG audio $USER` may have added **root**, not `pi`. Verify with
  `id pi`.

**Open problem — thermal throttling.** `vcgencmd get_throttled` returned
`0xa0002`:

| Bit | Meaning |
|---|---|
| 1 | ARM frequency capped right now |
| 17 | frequency capping has occurred since boot |
| 19 | soft temperature limit has occurred since boot |

Bits 0/16 (under-voltage) are **clear** — the power supply is fine. The CPU was
running at 1141 MHz instead of its 1200 MHz ceiling. This is a hardware/cooling
problem that no config change fixes, and it will cap how low the audio buffer
can go regardless of everything else here. Heatsink minimum, fan preferred; the
Pi 4 runs hotter still. Bits 16–19 are sticky since boot, so re-check after a
reboot plus a few minutes of playback.

---

## 5. Environment

- **Image:** <https://github.com/fayaaz/mixxx-pi-gen> — pi-gen build of 64-bit
  Raspbian, i3 window manager, Mixxx auto-started from i3 config.
- **Default login:** user `pi`, password `mixxx`. Terminal on the Pi itself:
  `Super`+`Enter`.
- **Settings dir:** `~/.mixxx/` — `mixxx.cfg` (general prefs),
  `soundconfig.xml` (device selection + audio buffer, in the `latency`
  attribute), `mixxx.log`, `controllers/`.
- **System mappings:** `/usr/share/mixxx/controllers/` (check
  `/usr/local/share/mixxx/controllers` for self-built Mixxx).
- Mixxx is not supervised by anything — i3 `exec`s it once. Restart manually:

```bash
pkill -x mixxx; sleep 2; DISPLAY=:0 mixxx > /tmp/mixxx.out 2>&1 &
```

`DISPLAY=:0` is required over SSH. For mapping work:

```bash
DISPLAY=:0 mixxx --developer --controller-debug > /tmp/mixxx.out 2>&1 &
tail -f ~/.mixxx/mixxx.log      # JS syntax errors appear here
```

`--developer` enables Developer → Developer Tools, where `[Channel1],wheel` and
`rateEngine` can be watched live while turning the jog.

---

## 6. Known gotchas

**Mixxx 2.3 has no DDJ-FLX4 mapping.** It was added in 2.4. If the user obtained
it manually into `~/.mixxx/controllers`, `install.sh` will print
`no mapping matching 'FLX4' -- skipping mapping step` and silently do nothing,
because it only searches *system* directories. Check with:

```bash
mixxx --version
ls /usr/share/mixxx/controllers/ | grep -i flx4
```

If empty, commit the vendor `.midi.xml` + `-script.js` into `mapping/vendor/`
and make `install.sh` prefer that directory, **copying** rather than symlinking
the vendor script in that case (a symlink into the repo breaks if the clone
moves). The patch for this was drafted but not applied — see the repo history or
re-derive from the `SYS_CONTROLLERS` block in `install.sh`.

**All scripts a mapping references must sit next to the copied XML.** Mixxx
resolves `<scriptfiles>` relative to the mapping's own directory, and the 2.4+
FLX4 mapping pulls in shared helpers (`midi-components-0.0.js`,
`lodash.mixxx.js`) besides its own script. `install.sh` therefore parses
`filename="…"` out of the copied XML and symlinks every referenced `.js` it can
find in the system dir, warning about any it can't. Don't narrow this back to a
`*FLX4*script.js` glob — that silently drops the helpers and the mapping fails
to load.

**Paths are env-overridable for testing:** `TARGET_USER`, `MIXXX_DIR`,
`SYS_CONTROLLERS`, `MAPPING_MATCH`. The mapping step was exercised end-to-end
against a synthetic 2.4-style FLX4 mapping this way (output validated with
`xmllint`, re-run clean); steps 1–3 need real root and were not.

**The settings dir is detected, not hardcoded.** `~/.mixxx` first, then
`~/.local/share/mixxx`, falling back to `~/.mixxx` — cheap insurance in case a
later Mixxx moves to XDG paths. Verify with `ls ~/.mixxx` on the Pi 4 before
trusting the install.

**`shift`+jog fast-seek still uses the filtered `jog` path.** `jogSearch` with
`fastSeekScale = 150` is untouched and is the "sudden huge jumps" half of issue
#11091. Left alone deliberately. If it needs fixing, `beatjump` is the right
primitive, not a rate control — don't reuse the `wheel` trick there, since
`wheel` is scaled by `kWheelMultiplier` when paused but not when playing, which
makes seek behaviour inconsistent across play states.

**`limits.d` is PAM-applied at login.** It covers SSH sessions and the console
login that starts i3, but *not* systemd services. If Mixxx is ever moved to a
systemd unit, use `LimitRTPRIO=95` and `LimitMEMLOCK=infinity` in the unit file
instead.

**Mixxx writes its config on clean exit.** Repeated `kill -9` loses preference
changes, including the audio buffer setting. Quit from the GUI at least once
after changing it.

---

## 7. Verification commands

```bash
# CPU / thermal
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor    # performance ×4
systemctl status mixxx-cpu-governor.service                  # active (exited)
vcgencmd measure_clock arm
vcgencmd measure_temp
vcgencmd get_throttled                                        # want 0x0

# realtime audio (run as the user Mixxx runs as, NOT root)
su - pi -c 'ulimit -r; ulimit -l; id -nG'                     # 95 / unlimited / …audio…
ps -eLo pid,tid,class,rtprio,comm | grep -i mixxx             # want FF or RR + non-zero rtprio

# mapping install
ls -l ~/.mixxx/controllers/
grep -n "name>\|scriptfiles\|<file " ~/.mixxx/controllers/*rekordbox-patch*.xml
```

`ps` showing class `TS` and rtprio `-` on every thread means Mixxx never got
realtime scheduling and the limits aren't reaching it.

---

## 8. Next steps

1. Run `install.sh` on the Pi; confirm the `(rekordbox patch)` mapping appears under
   Preferences → Controllers and selects without errors in `mixxx.log`.
2. Tune `PioneerDDJFLX4.bendSensitivity` by feel — 0.02 start, 0.01 finer,
   0.04 stronger. This is the only knob that should need touching.
3. Lower the audio buffer in Preferences → Sound Hardware, watching the overload
   counter on that same page. Still worth doing even with the override, since
   latency itself matters and `jogSearch` remains on the filtered path.
4. Sort out cooling before concluding anything about achievable buffer size.
5. Once settled, save `~/.mixxx/mixxx.cfg` and `~/.mixxx/soundconfig.xml` into
   `config/` and commit, so the Pi 4 migration is one `git clone` away.

Optional: the `wheel`-based approach is general and would make a reasonable
upstream contribution against issue #11091 — but note the real upstream fix is
making `Rotary`'s window time-based rather than buffer-count-based, in
`ratecontrol.cpp`, which is a C++ change affecting all controllers.
