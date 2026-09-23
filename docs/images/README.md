# Images

`mockup-*.png` are **drawings, not screenshots.** Nothing in this repo has ever been executed: the
Connect IQ simulator Garmin ships is an x86-64 binary and the build host is aarch64.

`../../tools/make_mockup.py` re-implements the layout arithmetic of `source/SolanaEpochView.mc` in
Python, using the real per-device font sizes Garmin ships in
`~/.Garmin/ConnectIQ/Devices/<id>/simulator.json`, and snaps the result to the 64-colour fenix 6
palette. So the composition, the proportions, the row positions and the colours are faithful.

Three things are not faithful:

- **Typeface.** The device uses Roboto Bold for text and Garmin's condensed "Bionic" family for
  numbers. Neither is available here, so DejaVu Sans Bold stands in. Real digits are narrower.
- **Antialiasing.** fenix 6 reports `alphaBlendingSupport = false`, so real text has hard edges.
- **The clock row's vertical placement**, which is the one thing `../VERIFICATION.md` calls out as
  unverified, because `FONT_NUMBER_*` glyph boxes carry more padding above the ascent than the
  reported font height implies.

Regenerate with a live chain state:

```sh
python3 tools/make_mockup.py state.json docs/images
```
