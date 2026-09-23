# Recovered research

These files are the salvaged output of workflow `wf_9c11d8d4-0ab`, run 2026-09-11, which died
before its final "Gaps" critic stage completed. The run's own journal was partly corrupted by
interleaved concurrent writes, so the results were recovered on 2026-09-18 and copied here so they
outlive the session scratchpad.

- `DIGEST.md` — 3 of 5 research topics in full, the truncated 4th, and all 30 verified claims.
- `CORRECTIONS.md` — the 11 refuted claims with their corrections, plus the 19 confirmed ones. Read this before trusting DIGEST.md.
- `recovered.json`, `verify_rows.json` — the raw recovered structures.
- `recover.py`, `verify_prompts.py`, `digest.py` — the recovery scripts, in case more is ever needed from the original journal.

What was lost and never recovered: the full research notes for the `background-webrequest` topic
(truncated mid-write; its first 3 findings survive in DIGEST.md Part 2) and for the
`solana-epoch-rpc` topic (never reached the journal). Their 6 load-bearing claims each survive in
the verified-claims section, which is what SPEC.md was actually built from, and every load-bearing
number was independently re-verified live against mainnet RPC and the local device files on
2026-09-18.
