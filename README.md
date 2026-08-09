# mixxx-pi-tune

Reapplies my Mixxx / Raspberry Pi tuning to a fresh mixxx-pi image in one step.
Tested on a Pi 3; nothing in here is Pi-3-specific, so it should carry over to a
Pi 4 unchanged.

```bash
git clone <your-repo-url> ~/mixxx-pi-tune
cd ~/mixxx-pi-tune
sudo ./install.sh
sudo reboot
```

Safe to re-run at any time — every step is idempotent.

## What it does

| Step | Change | Why |
|---|---|---|
| 1 | `cpufrequtils` governor → `performance` | Raspbian defaults to `ondemand`, which idles the CPU low and ramps up only after load appears — the wrong behaviour for audio callbacks. |
| 2 | Adds the login user to the `audio` group | Prerequisite for the realtime limits below. |
| 3 | Installs `/etc/security/limits.d/99-audio.conf` | Lets Mixxx's audio thread get realtime scheduling (`rtprio 95`) and lock memory. |
| 4 | Builds a `(tight bend)` copy of the DDJ-FLX4 mapping | Fixes the floaty jog-wheel pitch bend. See below. |
| 5 | Restores `config/` into `~/.mixxx` if present | Optional: carries your saved preferences across images. |

## The jog wheel fix

Turning the side of the jog wheel writes to the `[ChannelN],jog` control. In
`RateControl::getJogFactor()` that value goes through `Rotary::filter()`, a
25-tap moving average evaluated **once per audio buffer**. The smoothing window
is therefore `25 × buffer period`:

| Audio buffer | Jog tail |
|---|---|
| 46.4 ms | ~1160 ms |
| 23.2 ms | ~580 ms |
| 11.6 ms | ~290 ms |
| 5.8 ms | ~145 ms |

That's the slow ramp-up and the overshoot that make beatmatching impossible.
Upstream issue: <https://github.com/mixxxdj/mixxx/issues/11091>

`mapping/Pioneer-DDJ-FLX4-tightbend.js` overrides `PioneerDDJFLX4.jogTurn` to
drive `[ChannelN],wheel` instead, which `RateControl` applies unfiltered and
additively (`rate += wheelFactor`). A 20 ms timer turns the tick stream into a
rate offset and zeroes it as soon as the wheel stops. Top-of-platter scratching
still uses `scratchTick()` and is untouched.

The override is a **separate script file** appended to the mapping XML's
`<scriptfiles>` block, not an edit to the vendor script — so Mixxx upgrades can
replace `Pioneer-DDJ-FLX4-script.js` without clobbering the fix. The installer
symlinks the vendor script into `~/.mixxx/controllers` so it always tracks the
installed version.

Tune `PioneerDDJFLX4.bendSensitivity` at the top of the override file:
`0.02` is a moderate nudge, `0.01` finer, `0.04` stronger.

### Other controllers

```bash
MAPPING_MATCH='DDJ-400' sudo -E ./install.sh
```

The override script assumes the `PioneerDDJFLX4` namespace and the stock
`jogTurn` signature; adapt it for other mappings.

## After install

Select **"… (tight bend)"** in Preferences → Controllers, then set the audio
buffer in Preferences → Sound Hardware. Lower buffer = less latency *and*
(for anything still using the `jog` path, e.g. shift-seek) a shorter tail.

Verify:

```bash
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor   # performance ×4
vcgencmd get_throttled                                       # want 0x0
vcgencmd measure_temp
su - pi -c 'ulimit -r; ulimit -l; id -nG'                    # 95 / unlimited / …audio…
ps -eLo class,rtprio,comm | grep -i mixxx                    # want FF or RR, non-zero rtprio
```

`get_throttled` bit 1/17 = frequency capped, bit 19 = soft temperature limit,
bit 0/16 = under-voltage. Anything non-zero and the CPU is being held back
regardless of the governor — fix cooling or the power supply first, since
throttling causes xruns on its own.

## Saving your preferences

To carry Mixxx settings to the next image:

```bash
mkdir -p config
cp ~/.mixxx/mixxx.cfg ~/.mixxx/soundconfig.xml config/
```

`soundconfig.xml` holds the sound device selection and the audio buffer size
(the `latency` attribute). Device names may differ on new hardware, so treat it
as a starting point rather than gospel — `install.sh` won't overwrite existing
files.

## Not covered

- **Cooling.** A bare Pi 3 running Mixxx hits the soft thermal limit. Heatsink
  minimum, fan preferred. Same applies to the Pi 4.
- **systemd-launched Mixxx.** `limits.d` is applied by PAM at login, so it
  covers i3's autostart and SSH. A systemd unit needs `LimitRTPRIO=95` and
  `LimitMEMLOCK=infinity` in the unit file instead.
