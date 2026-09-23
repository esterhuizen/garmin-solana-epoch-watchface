# Solana Epoch watch face — implementation spec

Target: Garmin fenix 6 family, Connect IQ API level 3.4 (hard ceiling), Monkey C.
Build host: headless Ubuntu aarch64. No simulator (x86-64 only). Verification = `monkeyc -w -l 3` compile for all 5 devices.

## 1. Ground truth (verified locally 2026-09-18, not assumed)

Device files at `~/.Garmin/ConnectIQ/Devices/<id>/compiler.json`:

| product id | deviceFamily | screen | watchFace mem | background mem |
|---|---|---|---|---|
| fenix6 | round-260x260 | 260x260 | 114688 | 32768 |
| fenix6pro | round-260x260 | 260x260 | 114688 | 32768 |
| fenix6s | round-240x240 | 240x240 | 98304 | 32768 |
| fenix6spro | round-240x240 | 240x240 | 98304 | 32768 |
| fenix6xpro | round-280x280 | 280x280 | 131072 | 32768 |

All five: `deviceGroup = "API level 3.4"`, MIP display, 8 bpp, 64-colour palette
(every combination of 00/55/AA/FF per channel), `alphaBlendingSupport = false`,
`screenRotationSupport = false`, launcherIcon 40x40.

Background process gets 32768 bytes declared; assume ~28 KB usable (VM reserves ~4 KB working space).

Live Solana mainnet-beta, checked 2026-09-18 from this box:

- `getEpochSchedule` -> `{slotsPerEpoch: 432000, warmup: false, firstNormalEpoch: 0, firstNormalSlot: 0, leaderScheduleSlotOffset: 432000}`.
  Because warmup is false and firstNormalSlot is 0, `slotIndex == absoluteSlot % slotsInEpoch` and slotIndex is zero-based. No warmup-epoch branch is needed.
- `getEpochInfo` -> `{absoluteSlot, blockHeight, epoch, slotIndex, slotsInEpoch, transactionCount}`. Body is 171 bytes.
- `getRecentPerformanceSamples` with `params:[5]` -> 598 bytes, 5 samples, each `{slot, numSlots, samplePeriodSecs, numTransactions, numNonVoteTransactions}`.
  Measured slot time: sum(samplePeriodSecs)/sum(numSlots) = 300/954 = **0.3145 s/slot**. This is
  where `DEFAULT_SLOT_SECS = 0.315` comes from; the face itself no longer calls this method (§3).
- Reachable endpoints from this box: `https://api.mainnet-beta.solana.com` (HTTP 200, ~1.0 s) and
  `https://solana-rpc.publicnode.com` (HTTP 200, ~0.3 s). `https://rpc.ankr.com/solana` returns 403 (needs an API key) — do not use.

Do NOT hardcode 400 ms/slot. Mainnet moved to a 350 ms target at epoch ~1020 (Aug 2026, SIMD-0525) and the observed rate is ~315 ms. The face must self-calibrate (section 4).

## 2. Data flow (the Garmin-sanctioned pattern)

A watch face cannot do foreground HTTP. Use a background service:

1. `SolanaEpochApp extends Application.AppBase`, annotated `(:background)`, implements
   `getServiceDelegate()` returning `[new BackgroundService()]`.
2. The steady-state schedule is a **repeating `Time.Duration`**, not a computed `Moment`.
   `registerForTemporalEvent()` takes either (`$SDK/doc/Toybox/Background.html`, since 2.3.0);
   a Duration is interval-counted by the system, so a clock jump cannot defer it and it can
   never decay into a stale past Moment. The SDK's own `samples/Notifications` registers a
   Duration straight from `onStart()`. Minimum interval is 5 minutes (a shorter Duration throws
   `InvalidBackgroundTimeException`); only one event may be registered at a time and
   re-registering overwrites. Default refresh = 15 minutes. The three call sites:
   - `onStart()` — **only if `Background.getTemporalEventRegisteredTime() == null`.** Re-arming a
     repeating Duration restarts its interval countdown, and `onStart()` runs on every
     foreground start *and* at the head of every background process, so an unconditional
     re-arm here would starve the event. With nothing stored yet it registers
     `Moment(Time.now())`, which triggers immediately so a fresh install does not show a
     blank face for a whole interval; otherwise it registers the Duration. This is the only
     place a past Moment is used, and it is deliberate.
   - `onTemporalEvent()` — registers the Duration unconditionally, at the top. This is what
     promotes the fresh-install one-shot Moment onto the repeating schedule, and it keeps the
     schedule alive if the request hangs into the 30 s force-kill. Legal because the
     documented throws are "occurs less than five minutes after the last temporal event" and
     "has a duration of less than five minutes", and a clamped interval of ≥ 5 minutes
     satisfies both.
   - `onSettingsChanged()` — registers the Duration unconditionally; `RefreshMinutes` may have
     changed, and this is a rare user-driven event rather than something that fires on every
     wrist raise.

   `onBackgroundData()` does **not** reschedule. There is no chain to keep alive.
   Every registration stays wrapped in try/catch.
3. `BackgroundService extends System.ServiceDelegate`, annotated `(:background)` on the class.
   It POSTs JSON-RPC and finishes with `Background.exit(dict)`.
   The process is force-killed after 30 s if it never exits.
   There is no per-method annotation: a grep across the whole SDK 9.2.0 tree finds no
   `(:background_method)`, and the SDK's own `BackgroundTimer` sample marks only the class.
   The real guarantee is that `(:background)` on the class plus a clean `-l 3` build makes the
   compiler verify that everything reachable from the background process is legal there.
4. `Background.exit()` payload limit is ~8 KB; over it throws `Background.ExitDataSizeLimitException`
   and the process does NOT exit. Our payload is a handful of small numbers, so this is not a risk,
   but never put `transactionCount` or raw sample arrays in it.
5. `AppBase.onBackgroundData(data)` runs immediately when the face is active, otherwise the payload
   is cached and delivered right after the next `onStart()`. It writes Storage and calls
   `WatchUi.requestUpdate()`.
6. Note: `getBackgroundData()` lives on the `Background` module, NOT on `AppBase`, and returns null
   when called from the foreground. Only call it from the background process.

Both processes read settings via `Application.Properties.getValue()` — the background service
needs `RpcUrl` and `RefreshMinutes`, and the view legitimately needs `AccentColor` and
`RefreshMinutes` (for the staleness threshold). Every such call is wrapped in try/catch:
`api.mir` documents `Properties.InvalidKeyException` when the key is absent from the settings
XML, and two of these calls sit on the `onUpdate()` path where an uncaught throw kills the face.

Only the foreground app writes `Application.Storage`.

## 3. RPC requests

`Communications.makeWebRequest(url, params, options, callback)` where params is the JSON-RPC
Dictionary and options are:

```
{
  :method => Communications.HTTP_REQUEST_METHOD_POST,
  :headers => { "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON },
  :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
}
```

With `REQUEST_CONTENT_TYPE_JSON` the params Dictionary is serialised as the JSON request body.
A JSON-RPC *batch* is a top-level array, which a Dictionary cannot express, so batching is not
available. Send one method per request.

**Invariant: one HTTP request per background process, ever.** Per temporal event the service
sends exactly `{"jsonrpc"=>"2.0", "id"=>1, "method"=>"getEpochInfo"}` and then exits.

There is deliberately no chained `getRecentPerformanceSamples` seeding request. It bought about
0.16% accuracy for the first 30 minutes — roughly 12 seconds on a two-day epoch — at the cost of
a *permanent* failure mode: the flag deciding whether to chain was derived from a Storage key
that only the foreground writes, so if the two-request cycle never reached `Background.exit()`
nothing was stored, and every later cycle chained and failed identically, forever. The same
coupling double-requested on every cycle for as long as the user had another watch face
selected. `DEFAULT_SLOT_SECS = 0.315` is now the only seed; the epoch-delta calibration in §4
takes over on the second cycle. There is consequently no sample array to iterate and no cap to
add.

Callback signature is `(responseCode as Number, data as Dictionary or String or Null)`.
Treat any `responseCode != 200` as an error: exit with `{"err" => responseCode}` so the face can
show it. Known negative codes worth naming in a comment: -101 BLE host timeout, -300 request timed
out, -400 invalid HTTP body, -402 response too large, -403 response out of memory.

On a 200 whose body carries no usable `result`, read `error.code` and exit with that instead of
`ERR_BAD_BODY`. The number spaces do not collide — JSON-RPC uses -32768..-32000, Connect IQ
transport uses -101/-300/-400/-402/-403, HTTP uses 1xx..5xx — so the view can print the code
verbatim and needs no code-to-text table. `ERR_BAD_BODY = 1` stays as the fallback for a body
with neither a `result` nor a numeric error code, which is the real captive-portal case.

Parse only these fields, all small enough for Monkey C's 32-bit `Number`:
`epoch` (~1036), `slotIndex` (0..431999), `slotsInEpoch` (432000).
Never read `transactionCount` (5.5e11, exceeds 32-bit) or `blockHeight`.
Do not read `absoluteSlot` either; derive it when needed as `epoch * slotsInEpoch + slotIndex`
(verified exact today: 1036*432000+406443 = 447958443).

## 4. Slot-time self-calibration

Stored state lives under exactly **two** `Application.Storage` keys:

| key | meaning |
|---|---|
| `state` | one Dictionary: `{epoch, slotIndex, slotsInEpoch, fetchTs, slotSecs}` |
| `err` | last error code, absent when the last fetch succeeded |

Five sequential `setValue` calls can half-succeed and pair a new `epoch` with an old `fetchTs`,
which the view then reads as a huge `elapsed` and the calibrator as an inflated `timeDelta`. So
the five fields go into one Dictionary written with a single `setValue`, which makes the update
atomic, and the whole Dictionary is validated as a unit on read: every field present, of the
right type and in range, or it is treated as no data at all. That one validator
(`Se.readState()`) is the only place the per-field checks live, and the view reads it once per
cache refresh instead of six times per draw.

`err` keeps its own key because it is written on a different path: a failed fetch leaves the last
good state alone.

`fetchTs` is stamped by the background process at fetch time, not by `onBackgroundData()` —
delivery can lag the fetch by minutes whenever the face was not active, and timestamping at
delivery would pair a `slotIndex` from time T with a clock reading from T+delay, which lags the
arc and poisons the calibration.

On each successful fetch, `Se.readState()` runs **before** the new Dictionary is written, so the
measurement is taken against the old state:

```
slotDelta = (newEpoch - oldEpoch) * slotsInEpoch + (newSlotIndex - oldSlotIndex)
timeDelta = nowTs - oldFetchTs
```

Accept a new measurement only when `slotDelta > 300` and `timeDelta > 240` and the quotient
`timeDelta / slotDelta` lands in **[0.08, 1.5]**. Then smooth: `slotSecs = 0.5*old + 0.5*measured`.
Any in-band measurement is accepted, which is what makes convergence from any starting state
guaranteed. Reject anything outside those guards (clock changes, epoch rollover glitches); long
offline gaps are still fine, because the average over a long window is still an average.

The three numbers are chosen, not tuned:

- **Band [0.08, 1.5]**, not a tight band around today's 0.315. Deleting the chained seeding
  request removed the only path by which a bad slot time could enter storage, so the latch risk
  is largely gone — while Solana has already gone 400 → 350 ms and publicly targets 200 ms, so a
  tight band would reject a real future slot-time cut. The band only has to catch absurd values.
- **`timeDelta > 240`**, not 60: over a minute-long window the one-second quantisation of the two
  timestamps dominates the quotient. It must *not* be 600 either — the minimum refresh setting is
  5 minutes, so a 600 s floor would reject every measurement at that setting and the face would
  never calibrate at all.
- **`slotDelta > 300`** unchanged.

Seed value when nothing is stored: **0.315** (the measured 2026-09-18 mainnet rate). It is the
only seed there is; see §3.

## 5. Rendering

No `onPartialUpdate`. The countdown only needs minute resolution, `onUpdate` already runs at the
top of every minute in low-power mode, and skipping partial updates removes the whole 20-30 ms
power-budget risk (the real limit is undocumented; read `executionTimeLimit` at runtime if it is
ever added). `onEnterSleep`/`onExitSleep` are implemented as genuinely empty no-ops rather than
flipping a flag: the face renders identically in both power modes, so nothing would ever read such
a flag, and `-l 3` correctly flags a write-only member.

One layout for all three screen sizes. Never hardcode 260. Read `dc.getWidth()`/`dc.getHeight()`
and derive every coordinate. Measure text with `Graphics.getFontHeight()`; per-device font pixel
heights are not published. `api.mir` documents `getFontHeight()` as exactly ascent plus descent —
it does *not* also include internal leading. `FONT_NUMBER_MEDIUM` is a real public constant
(value 6) — the earlier claim that it is undocumented was wrong.

`onUpdate()` runs about once a second for ten seconds after every wrist raise, so Storage and
Properties are read into a view-level cache rather than per draw. The cache is refreshed in
`onShow()` and whenever a module-level version counter — bumped by `onBackgroundData()` and
`onSettingsChanged()` — no longer matches the cached copy. A stale accent colour for one draw is
not a problem.

Estimated current position, computed in `onUpdate`:

```
elapsed   = now - fetchTs                       // seconds
estIndex  = slotIndex + (elapsed / slotSecs)    // may exceed slotsInEpoch
remaining = slotsInEpoch - estIndex             // slots
secsLeft  = remaining * slotSecs
progress  = estIndex / slotsInEpoch             // clamp to 0.0 .. 1.0
```

Clamp `estIndex` to `slotsInEpoch` so `secsLeft` never goes negative. When it clamps, show the
countdown as `"rollover"` rather than `0m`, because the real epoch has almost certainly advanced
and we have not refetched yet.

Layout, round screen, centre `(cx, cy)`, radius `r = w/2 - 5`:

- Full dark-grey circle at `r`, pen width `max(6, w/28)`, as the ring track.
- Accent arc over it, same radius and pen width, `Graphics.ARC_CLOCKWISE` starting at 90 degrees
  (12 o'clock) sweeping `progress * 360` degrees. Remember 0 degrees is 3 o'clock.
  `drawArc()` truncates every parameter towards zero, so add 0.5 before `.toNumber()` and the
  sweep rounds instead of losing up to a whole degree on every draw. A sweep that rounds up to
  360 must be drawn as a full circle, not handed to `drawArc()`: equal start and end angles draw
  a complete circle, so 90..90 would be indistinguishable from "no progress at all".
- Text stack, all `TEXT_JUSTIFY_CENTER`. Only the top two rows are anchored to screen fractions;
  the lower three are **stacked from measured font heights**, because computed centre-to-centre
  gaps of 26 and 24 px on the 240 px screen leave only 3-5 px of clearance against the commonly
  reported fenix 6 font metrics, and none of that can be verified without hardware. Self-sizing
  beats tuned:
  - `cy - 0.27h`: date, e.g. `THU 18 SEP`, FONT_XTINY, light grey.
  - `cy - 0.09h`: time `HH:MM`, FONT_NUMBER_MEDIUM, white. Respect
    `System.getDeviceSettings().is24Hour`; in 12-hour mode strip the leading zero.
    `FONT_NUMBER_*` is reported to carry more padding above the ascent than `getFontHeight()`
    implies, so the digits may sit visibly low inside their row. **This is the first thing to
    check on real hardware**; the stack below follows whatever this row does.
  - Then, walking downward from the measured bottom of the clock row, each row placed at
    `cursor + getFontHeight(font)/2` and the cursor advanced by `getFontHeight(font) + gap`,
    where `gap = max(3, w/70)` (3 px at 240 and 260, 4 px at 280):
    - `EPOCH 1036`, FONT_SMALL, accent colour.
    - countdown, e.g. `2h 14m left`, FONT_TINY, white.
    - `94.1%` plus status glyph, FONT_XTINY, grey.

  No assumed font metric can make two rows collide under this scheme.

Countdown format, adaptive: `Xd Yh` above one day, `Xh Ym` above one hour, `Ym` above one minute,
and `<1m left` below that — never `0m left`, because there is still time on the clock.

Status glyph on the bottom line:
- data older than 3x the refresh interval -> append ` !` and draw the line in orange,
- `System.getDeviceSettings().phoneConnected == false` -> append ` x`,
- a stored `err` -> show `RPC <code>` in place of the percent, in orange. The code is printed
  verbatim and may be a JSON-RPC `error.code` (-32768..-32000), a Connect IQ transport code, an
  HTTP status, or `1` for a body with neither a result nor a numeric error code.

Colours must come from the 64-entry palette or they dither. Use `0x000000` background,
`0xFFFFFF` primary text, `0xAAAAAA` secondary, `0x555555` ring track, `0xFFAA00` warning.
Accent default `0xAA55FF` (nearest palette entry to Solana purple `0x9945FF`); the green option is
`0x00FFAA` (nearest to `0x14F195`).

## 6. Settings

`resources/settings/settings.xml` + `resources/properties/properties.xml`:

| property | type | default |
|---|---|---|
| `RpcUrl` | string | `https://api.mainnet-beta.solana.com` |
| `RefreshMinutes` | number | 15 |
| `AccentColor` | list | `0xAA55FF` purple, `0x00FFAA` green, `0xFFAA00` orange, `0x00AAFF` blue |

Clamp `RefreshMinutes` in code to a minimum of 5, because anything less throws
`Background.InvalidBackgroundTimeException`, **and to a maximum of 240**. It is untrusted input
from the same source as `RpcUrl`, and a huge value overflows the view's `refreshSecs * 3`
staleness threshold into a negative, which pins the stale marker on permanently.

Wrap every `Properties.getValue()` call in try/catch: `api.mir` documents
`Properties.InvalidKeyException` when the key is absent from the settings XML.

## 7. Manifest and jungle

`manifest.xml`: `<iq:application type="watchface" minApiLevel="3.0.0">`, the 5 product ids above,
permissions `Background` and `Communications`, launcherIcon pointing at a 40x40 drawable.
There is no separate quatix 6 or tactix Delta product id — those ship under `fenix6pro` and
`fenix6xpro`, so the 5 ids already cover them.

`monkey.jungle`: single `project.manifest = manifest.xml` plus the default source and resource
paths. No per-device resource overrides are needed because the layout is computed at runtime.
Note `excludeAnnotations` is a jungle property, not a CLI flag, and `-e` on monkeyc means
`--package-app`, not "exclude annotations".

## 8. Build and verify

```
SDK=~/.Garmin/ConnectIQ/Sdks/connectiq-sdk-lin-9.2.0
KEY=~/.Garmin/ConnectIQ/developer_key.der
rm -rf build && mkdir -p build
for d in fenix6 fenix6pro fenix6s fenix6spro fenix6xpro; do
  $SDK/bin/monkeyc -d $d -f monkey.jungle -o build/$d.prg -y $KEY -r -w -l 3 || echo "FAILED $d"
done
$SDK/bin/monkeyc -f monkey.jungle -o build/solana-epoch.iq -y $KEY -e -r -w -l 3
```

The build must be clean at `-l 3` (strict type check) with `-w` warnings shown. Strict type check
is the only verification available on this box, so treat every warning as something to fix or
explicitly justify in a comment.

Note the `-r` on the per-device loop. Without it the debug `.prg` is 103,596 bytes — almost all of
it a symbol table the device never loads — which exceeds the fenix6s and fenix6spro 98,304-byte
watch-face pool outright and will not load. With `-r` it is about 13 KB. Never sideload a debug
build.

Sideloading to a real watch: USB mass storage, copy the `.prg` into `GARMIN/APPS/`, eject, then pick
the face on the watch. A self-generated key is fine for sideloading.
