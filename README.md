# Solana Epoch — Garmin fenix 6 watch face

A Connect IQ watch face for the fenix 6 family that shows how far through the current
Solana mainnet-beta epoch the network is, and how long is left.

## What it shows

```
              ╭──────────────╮
             ╱   [solana mark] ╲       black on day, white at night
            │    THU 18 SEP    │       date, FONT_XTINY, secondary
            │      14:32       │       time, FONT_NUMBER_MEDIUM, primary
            │   EPOCH 1036     │       epoch number, FONT_SMALL, accent
            │   2h 14m left    │       countdown, FONT_TINY, primary
            │     94.1%        │       progress + status, FONT_XTINY
            │  HR 72   8432    │       heart rate and steps, FONT_TINY
             ╲                ╱
              ╰──────────────╯
        outer ring: track with an accent arc from 12 o'clock
        day (07:00-19:00): white field, black type, black logo
        night: black field, white type, white logo
```

- **Ring** - epoch progress. Full circle = epoch complete. Pen width is `max(6, w/28)`.
- **Day / night** - local hour 07:00-18:59 is a white MIP field (readable outdoors). After 19:00 the original black field returns. The Solana mark follows: black on white, white on black.
- **HR** - `Activity.getActivityInfo().currentHeartRate`, falling back to the newest `SensorHistory` sample. `--` until a sample exists.
- **Steps** - `ActivityMonitor.getInfo().steps` for today. `Nk` above 100000.
- **Countdown** — adaptive: `Xd Yh left` above a day, `Xh Ym left` above an hour, `Ym left`
  above a minute, and `<1m left` below that (never `0m left`). Shows `rollover` once the
  estimate runs past the end of the epoch, because at that point the real epoch has almost
  certainly advanced and we have not refetched yet.
- **Status line** — percent through the epoch, plus glyphs:
  - ` !` in orange — stored data is older than 3× the refresh interval.
  - ` x` — the phone is not connected, so the next fetch will fail.
  - `RPC <code>` in orange replaces the percent when the last fetch returned an error.
    The code is printed verbatim and the number spaces do not collide:
    `-32768`..`-32000` is the server's own JSON-RPC `error.code`, passed straight through;
    `-101` BLE host timeout, `-300` request timed out, `-400` invalid HTTP body, `-402`
    response too large and `-403` response out of memory are Connect IQ transport errors;
    `1xx`..`5xx` are HTTP statuses. `RPC 1` is our own fallback for an HTTP 200 whose body
    carries neither a usable `result` nor a numeric error code — the captive-portal case.
  - `no data` on the countdown line until the first successful fetch lands.

One layout serves all three screen sizes (240 / 260 / 280 px round). Every coordinate is
derived from `dc.getWidth()`/`getHeight()`, so there are no per-device resource overrides.
The date and clock rows are anchored to screen fractions; the epoch, countdown and status
rows below them are **stacked from measured `Graphics.getFontHeight()` values** plus a small
scaled gap, so no assumed font metric can make two rows collide. (`getFontHeight()` is
exactly ascent plus descent, per `api.mir`.)

`FONT_NUMBER_*` is reported to carry more padding above the ascent than its height implies,
so the clock digits may sit visibly low inside their row. That is the first thing to check on
real hardware; the rows below follow whatever the clock row does.

Every colour is an exact entry of the fenix 6 64-colour palette (each channel one of
`00/55/AA/FF`), so nothing dithers on the MIP display.

## Data flow

A watch face cannot make HTTP requests from the foreground, so:

1. `SolanaEpochApp` (`AppBase`, annotated `(:background)`) registers a temporal event via
   `Background.registerForTemporalEvent()`. The steady-state schedule is a repeating
   `Time.Duration`, not a computed `Moment`: a Duration is interval-counted by the system, so
   a clock jump cannot defer it and it can never decay into a stale past Moment. Default
   interval 15 minutes, clamped to 5..240.

   `onStart()` arms the schedule **only if nothing is registered yet** — re-arming a repeating
   Duration restarts its interval countdown, and `onStart()` runs on every foreground start as
   well as at the head of every background process, so an unconditional re-arm there would
   starve the event. On a fresh install with nothing stored it arms `Moment(Time.now())`
   instead, which triggers immediately rather than leaving a blank face for a whole interval.
   `onTemporalEvent()` and `onSettingsChanged()` register the Duration unconditionally; the
   first of those is what promotes the fresh-install one-shot onto the repeating schedule.
2. `BackgroundService` (`System.ServiceDelegate`) wakes up, registers the repeating interval
   first (so the schedule is safe even if the request hangs into the OS's 30 s force-kill),
   then POSTs `getEpochInfo` to the configured JSON-RPC endpoint and finishes with
   `Background.exit()` carrying a handful of small numbers.

   **One HTTP request per background process, ever.** There used to be a chained
   `getRecentPerformanceSamples` call to seed the slot-time calibration. It bought about 0.16%
   accuracy for the first 30 minutes — roughly 12 seconds on a two-day epoch — in exchange for
   a permanent-failure mode: the flag that decided whether to chain was derived from a Storage
   key only the *foreground* writes, so if the two-request cycle never reached
   `Background.exit()` nothing was stored and every later cycle chained and failed
   identically, forever. It also double-requested on every cycle for as long as the user had
   another watch face selected. It is gone.
3. `AppBase.onBackgroundData()` runs immediately if the face is active, otherwise the
   payload is cached and delivered right after the next `onStart()`. It performs the
   slot-time calibration, writes `Application.Storage` and calls `WatchUi.requestUpdate()`.
   This is the only writer of Storage. It does **not** reschedule anything — the repeating
   Duration keeps itself alive.
4. `SolanaEpochView.onUpdate()` extrapolates the current slot from the stored snapshot plus
   the calibrated slot time. No network, no `onPartialUpdate()`. Storage and Properties are
   read into a view-level cache rather than per draw, because `onUpdate()` runs about once a
   second for ten seconds after every wrist raise; the cache is refreshed in `onShow()` and
   whenever a version counter bumped by `onBackgroundData()`/`onSettingsChanged()` moves on.

Only `epoch`, `slotIndex` and `slotsInEpoch` are parsed. `transactionCount` (~5.5e11) and
`blockHeight` do not fit Monkey C's 32-bit signed `Number` and are never touched;
`absoluteSlot` is not read either, since it is exactly `epoch * slotsInEpoch + slotIndex`.

### Slot-time self-calibration

Mainnet's slot target moved to 350 ms (SIMD-0525) and the measured rate on 2026-09-18 was
0.3145 s/slot, so nothing is hardcoded to the old 400 ms. Storage holds exactly two keys:

| key | meaning |
|---|---|
| `state` | one Dictionary: `{epoch, slotIndex, slotsInEpoch, fetchTs, slotSecs}` |
| `err` | last error code, absent when the last fetch succeeded |

The five fields share one key on purpose. Five sequential `setValue` calls can half-succeed and
pair a new `epoch` with an old `fetchTs`, which the view reads as a huge `elapsed` and the
calibrator reads as an inflated `timeDelta`. One Dictionary, one `setValue`, so the update is
atomic — and the Dictionary is validated as a whole on read (`Se.readState()`): every field
present, correctly typed and in range, or it counts as no data at all. `err` keeps its own key
because it is written on a different path; a failed fetch leaves the last good state alone.

`fetchTs` is `Time.now().value()` taken **in the background process at fetch time** — see the
note below.

On each successful fetch, before the old state is overwritten:

```
slotDelta = (newEpoch - oldEpoch) * slotsInEpoch + (newSlotIndex - oldSlotIndex)
timeDelta = nowTs - oldFetchTs
```

`fetchTs` is deliberately stamped by the background process rather than by
`onBackgroundData()`. The payload is only delivered immediately when the watch face is
active; otherwise the system caches it until after the next `onStart()`, which on a
fenix 6 can be minutes later because the face is stopped during activities and other
apps. Timestamping at delivery would pair a `slotIndex` from time T with a clock reading
from T+delay, which lags the arc and — worse — poisons the calibration, since the accepted
measurement becomes `slotSecs * (deliveryDelta / fetchDelta)`. A 10-minute delivery lag on
one cycle of a 15-minute interval is enough to push a 0.315 estimate to 0.42 and make the
countdown hours wrong. This is a deliberate correction to spec §4.

A measurement is accepted only when `slotDelta > 300`, `timeDelta > 240` and
`timeDelta / slotDelta` lands in `[0.08, 1.5]`, then smoothed `0.5 * old + 0.5 * measured`.
Everything outside those guards (clock changes, epoch rollover glitches, a corrupt stored
epoch) is rejected. Long offline gaps are fine — the average over a long window is still an
average.

Those three numbers are chosen, not tuned:

- `[0.08, 1.5]` is deliberately wide around today's 0.315. With the chained seeding request gone
  there is no longer any path by which a bad slot time can enter storage, so the band only has
  to catch absurd values — and Solana has already gone 400 → 350 ms and publicly targets 200 ms,
  so a tight band would reject a real future slot-time cut.
- `timeDelta > 240` rather than 60, because over a minute-long window the one-second
  quantisation of the two timestamps dominates the quotient. It cannot be 600 either: the
  minimum refresh setting is 5 minutes, so a 600 s floor would reject every measurement at that
  setting and the face would never calibrate at all.
- Any in-band measurement is accepted and smoothed 0.5/0.5, which is what makes convergence from
  any starting state guaranteed.

The seed is the constant 0.315, and nothing else — the calibration takes over on the second
cycle.

## Settings

Edited in Garmin Connect Mobile, or in Garmin Express for a sideloaded build.

| property | type | default | notes |
|---|---|---|---|
| `RpcUrl` | string | `https://api.mainnet-beta.solana.com` | JSON-RPC endpoint. `https://solana-rpc.publicnode.com` also works and is faster. `https://rpc.ankr.com/solana` returns 403 without an API key. |
| `RefreshMinutes` | number | `15` | Poll interval. Clamped to 5..240 in code as well as in the settings UI. Below 5 throws `Background.InvalidBackgroundTimeException`; the upper clamp exists because a huge value would overflow the view's `refreshSecs * 3` staleness threshold into a negative and pin the stale marker on. |
| `AccentColor` | list | `11163135` (`0xAA55FF`) | Arc and epoch-label colour. Options: `11163135` purple (`0xAA55FF`, nearest palette entry to Solana purple `0x9945FF`), `65450` green (`0x00FFAA`, nearest to `0x14F195`), `16755200` orange (`0xFFAA00`), `43775` blue (`0x00AAFF`). Stored as decimal because the settings editor treats the value as a plain number. |

## Build

Use the script. It always builds release, and it checks each artifact against that device's own
watch-face memory pool and exits non-zero if anything would not fit:

```sh
cd /home/ubuntu/build/garmin-solana-epoch-watchface-tracker
./tools/build.sh
```

The equivalent by hand, if you want to see what it does:

```sh
cd /home/ubuntu/build/garmin-solana-epoch-watchface-tracker
SDK=~/.Garmin/ConnectIQ/Sdks/connectiq-sdk-lin-9.2.0
KEY=~/.Garmin/ConnectIQ/developer_key.der
rm -rf build && mkdir -p build

# per-device .prg, release (-r), strict type check (-l 3) with warnings shown (-w)
for d in fenix6 fenix6pro fenix6s fenix6spro fenix6xpro; do
  $SDK/bin/monkeyc -d $d -f monkey.jungle -o build/$d.prg -y $KEY -r -w -l 3 || echo "FAILED $d"
done

# store-ready package (-e = --package-app, -r = release)
$SDK/bin/monkeyc -f monkey.jungle -o build/solana-epoch.iq -y $KEY -e -r -w -l 3
```

All six invocations must print `BUILD SUCCESSFUL` with no warnings.

Note `-e` on `monkeyc` means `--package-app`, not "exclude annotations" — `excludeAnnotations`
is a jungle property, not a CLI flag.

`-r` is not optional, which is the whole reason `tools/build.sh` exists. The default (debug)
`.prg` is 105,052 bytes, almost all of it a symbol table the device never loads, and that
exceeds the smallest watch-face pool in the family (fenix6s and fenix6spro, 98,304 bytes)
outright, so it will not load. The release build is 13,436 bytes per device. Never sideload a
debug build, and if you find a roughly 100 KB `.prg` sitting in `build/`, something built
without `-r` and you should rerun the script before copying anything to a watch.

Two quirks worth knowing if you compare byte counts. A debug `.prg` embeds its own output path
in the symbol table, so building to a different directory changes its size by a few dozen bytes.
And the `.iq` package is not byte-reproducible between builds, because it carries per-build
signatures. The release `.prg` files themselves are deterministic.

The simulator that ships with SDK 9.2.0 is an x86-64 binary, so on an aarch64 host the
strict type check is the only verification available. `monkeyc` itself is pure Java and
runs fine.

### Regenerating the launcher icon

```sh
python3 tools/make_icon.py
```

Writes `resources/drawables/launcher_icon.png` (40×40, the size every fenix 6 product
declares). The script oversamples 8×, downsamples with Lanczos, then snaps every channel
to `00/55/AA/FF` so the device does not dither it. The committed PNG is the output of that
script; regenerate only if you change the artwork.

## Sideloading to a real watch

1. Build a `.prg` for your exact product (`fenix6`, `fenix6pro`, `fenix6s`, `fenix6spro`
   or `fenix6xpro`). quatix 6 / 6S ship under `fenix6pro`; quatix 6X and tactix Delta
   ship under `fenix6xpro`.
2. Connect the watch over USB. It mounts as a mass-storage volume named `GARMIN`.
3. Copy the `.prg` into `GARMIN/APPS/` on the watch.
4. Eject the volume and unplug. A self-signed developer key is fine for sideloading.
5. On the watch: hold the middle button → Watch Face → pick **Solana Epoch**.
6. Settings for a sideloaded face are edited in Garmin Express, not Garmin Connect Mobile.

The first fetch happens as soon as the face is selected; until it lands the countdown line
reads `no data`.

## Layout

```
manifest.xml                              watchface, minApiLevel 3.0.0, 5 fenix 6 products,
                                          Background + Communications permissions
monkey.jungle                             single build config, no per-device overrides
source/SolanaEpochApp.mc                  AppBase (:background), temporal event registration,
                                          the single atomic Storage write, slot-time
                                          calibration, module Se (keys, constants, palette,
                                          settings accessors, readState, scheduling)
source/BackgroundService.mc               ServiceDelegate (:background), the one JSON-RPC call,
                                          Background.exit
source/SolanaEpochView.mc                 WatchFace view, cached state, runtime-derived
                                          self-sizing layout, drawing
resources/strings/strings.xml
resources/settings/settings.xml           settings UI
resources/properties/properties.xml       setting defaults
resources/drawables/drawables.xml
resources/drawables/launcher_icon.png     40x40, generated
tools/make_icon.py                        launcher icon generator
```

## API-level notes

The fenix 6 family reports `deviceGroup = "API level 3.4"`, so 3.4 is a hard ceiling —
nothing newer may be called. A few consequences worth remembering when editing:

- `WatchUi.requestUpdate()` carries `disableBackgroundBeforeVersion = "5.1.0"` in the SDK
  API definition, and so does the whole `Graphics` module. Because `SolanaEpochApp` is
  `(:background)`, the calls that reach them are isolated behind
  `(:typecheck(disableBackgroundCheck))` (`requestFaceUpdate()` and `getInitialView()`),
  which is the documented escape hatch and is exactly how the SDK's own `BackgroundTimer`
  sample handles the same problem.
- `Background.getBackgroundData()` lives on the `Background` module, not on `AppBase`, and
  returns `null` from the foreground. It is not used here.
- `Background.exit()` throws `ExitDataSizeLimitException` above ~8 KB and then does not
  exit at all, so the payload is kept to a few numbers.
- JSON-RPC batching is impossible: a batch is a top-level JSON array, and
  `makeWebRequest` serialises a `Dictionary`. One method per request.
