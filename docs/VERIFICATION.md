# Verification evidence

## 1. Epoch countdown math, cross-checked against an independent source

Run from this box on 2026-09-18, using the same formula the watch face implements
(`remaining = (slotsInEpoch - slotIndex) * slotSecs`, with `slotSecs` derived from
`sum(samplePeriodSecs)/sum(numSlots)` over 5 recent performance samples):

```
epoch=1036 slotIndex=407564/432000
progress=94.34%
slot_secs=0.3151  remaining_slots=24436  secs_left=7700  -> 2h 8m
derived absoluteSlot=447959564 vs reported 447959564  match=True
```

Independent check, `https://api.stakewiz.com/epoch_info`, fetched seconds later:

```
{"epoch":1036,"start_slot":447552000,"slot_height":407530,
 "duration_seconds":136936,"elapsed_seconds":129199,"remaining_seconds":7737}
```

Our 7700 s against their 7737 s is a 0.48% difference, and 34 of those slots are simply their
reading being slightly behind ours (407530 vs 407564), worth about 11 s. The formula is sound.

`derived absoluteSlot == reported absoluteSlot` also confirms the spec's assumption that
`slotIndex == absoluteSlot % slotsInEpoch` holds on mainnet-beta, which follows from
`getEpochSchedule` reporting `warmup: false` and `firstNormalSlot: 0`.

## 2. What could NOT be verified on this box

The Connect IQ simulator is an x86-64 binary and this is an aarch64 host, so nothing was ever
rendered or executed. There are no screenshots and no runtime test of the background service, the
web request, or the drawing code. Verification is limited to:

- a strict-type-check compile (`monkeyc -w -l 3`) for all five fenix 6 product ids,
- the `.iq` store package building,
- the epoch math checked independently in Python against live mainnet RPC and a third-party API, as above.

Anything about on-watch behaviour (layout legibility, background fetch actually firing on a real
fenix 6, power draw) is unproven until the `.prg` is sideloaded onto hardware.

## 3. Independent review pass, 2026-09-18

A second agent reviewed the code without having written it, re-derived the epoch arithmetic in
Python rather than reading it off the source, and checked every API claim against the SDK's own
machine-readable metadata at `$SDK/bin/api.mir` and the offline docs at `$SDK/doc/`, not from
memory. What it confirmed:

- **The epoch and countdown math is correct.** It reproduced section 1 above exactly, and separately
  verified three cases the live check could not reach. Across an epoch boundary, old state
  `(1036, 431000)` plus 900 s at 0.315 gives new state `(1037, 1857)`, a slot delta of 2857, and a
  recovered rate of 0.315016. Over a consistent 14-day offline gap the recovered rate is 0.315000.
  A clock pushed forward a year clamps, shows `rollover`, and raises the stale flag.
- **No integer-division traps.** Every intended float division is a float division and every
  intended integer division is an integer division, checked one at a time.
- **No reachable division by zero, and no 32-bit overflow.** The worst case of the calibration
  multiply is 1000 * 2,000,000 + 2,000,000 = 2,002,000,000, against a 2,147,483,647 ceiling, and the
  epoch-delta bound is checked before the multiply rather than after.
- **Arc geometry is correct**, with the sweep matching progress to within one degree across 10,000
  sampled values, and the degenerate start-equals-end case that would have drawn a full ring at zero
  progress is correctly guarded.
- **`Application.Storage` really is readable from the background process at API 3.4.** This was an
  open assumption in the original research. `api.mir` shows `getValue` carrying only
  `minSdk = "2.4.0"` with no background restriction at all.
- **The `(:background)` annotation coverage is compiler-verified, not asserted.** Garmin's shipped
  Backgrounding article states that at type-check level informative or above the compiler detects a
  background reference to an unannotated symbol. The build runs at strict, which is above
  informative, and is clean.
- **Nothing newer than API 3.4 is reachable.** Spot-checked since-levels: `drawArc` and the font
  metric calls 1.2.0, `makeWebRequest` 1.3.0, `Storage` 2.4.0,
  `getTemporalEventRegisteredTime` 3.0.0.
- **Palette conformance is exact**, including every pixel of the launcher icon and the decimal
  encodings of all four accent options in the settings file.

It also found real defects, the most serious being a permanent-failure mode in the first-run chained
request: the flag controlling the chain was derived from a Storage key only the foreground writes, so
a background process killed mid-chain would leave that key unset and re-enter the same failing path
on every later cycle. That, the scheduling lifecycle, and eight smaller issues were fixed in a
second pass. The chained request was deleted outright, since it bought about 12 seconds of accuracy
on a two-day epoch.

## 4. Still unverifiable without hardware

Vertical placement of the clock row. Garmin's `FONT_NUMBER_*` fonts carry more padding above the
glyphs than their reported ascent implies, so the clock may render visually low, and the computed
row gaps on the 240 px screen leave only a few pixels of clearance against the commonly reported
font metrics. The layout was changed to stack the lower rows from measured font heights so that no
assumed metric can make two rows collide, but how it actually looks is the first thing to check on a
real watch.

## 5. Final shipped state, verified 2026-09-18

Rebuilt from an empty `build/` directory with `-r -w -l 3`. All five devices and the store package
succeeded with zero errors and zero warnings.

| artifact | bytes | watchFace budget | used |
|---|---|---|---|
| fenix6.prg | 13436 | 114688 | 11.7% |
| fenix6pro.prg | 13436 | 114688 | 11.7% |
| fenix6s.prg | 13436 | 98304 | 13.7% |
| fenix6spro.prg | 13436 | 98304 | 13.7% |
| fenix6xpro.prg | 13436 | 131072 | 10.3% |
| solana-epoch.iq | 304005 | n/a | 20 device variants |

All five files are byte-identical, which is expected rather than a build fault: there are no
per-device resources, the layout is derived from the drawing context at runtime, and all five
products share the same device group and icon.

Container formats check out. The `.prg` files start with the Garmin `D0 00 D0 00` magic, and the
`.iq` is a valid 7-zip container, which is what a Garmin store package is.

One last live check of the seed constant. The face ships with 0.315 s/slot as its starting estimate;
mainnet measured 0.3202 s/slot at the time of this build, a 1.6% difference. That is the seed doing
its only job, covering the gap until the second fetch calibrates from real observations, and it is
also a reminder of why the value is not trusted as a constant: it drifted 1.6% in the few hours
between the first measurement in section 1 and this one.

## 6. A build-directory clobber, and the guard added because of it

After section 5 was written, a stale agent process woke up, re-ran the build without `-r`, and
replaced the verified 13,436-byte release artifacts with 105,052-byte debug builds. No source file
was touched, only the outputs. The debug build exceeds the fenix6s and fenix6spro pool of 98,304
bytes outright, so for a while `build/` held five files that could not have loaded on two of the
five target watches, under exactly the names the documentation tells a reader to copy onto a watch.

Caught by re-checking the artifacts rather than trusting the report, then fixed by rebuilding.

To stop it recurring, `tools/build.sh` is now the documented way to build. It always passes `-r`,
and after building it reads each device's own `watchFace` memory pool out of
`~/.Garmin/ConnectIQ/Devices/<id>/compiler.json` and exits non-zero if any artifact does not fit.
A size check that reads the real per-device limit cannot drift the way a number typed into a
README can.

Two incidental facts established while confirming this, both worth knowing before comparing byte
counts across runs:

- A debug `.prg` embeds its own output path in the symbol section, so the same source built to a
  different directory differs by a few dozen bytes. Debug sizes are only comparable alongside the
  path they were built to.
- The `.iq` package is not byte-reproducible between builds, because it carries per-build
  signatures. Observed 304,005 / 304,046 / 304,059 / 304,062 bytes across passes of identical
  source. The release `.prg` files are deterministic; three consecutive builds are byte-identical.
