# ccusage-panel.sh: idle-cost optimization plan

Written 2026-09-05, after a live battery-drain investigation on the primary
dev machine traced part of the cost to this panel. Two instances of
`ccusage-panel.sh` had been running continuously for ~24h (one per
long-lived Claude Code session, auto-launched by `claude-panel-launch.sh`),
each showing **~47 minutes of accumulated CPU time** in `ps`. That's not
explained by the corpus-change gating already in the script (see below) —
that gating is real and working. The remaining cost is architectural: the
panel wakes up and does a bounded amount of fork/exec work every 10s,
**forever, regardless of whether anything has happened**, and that steady
drumbeat is itself part of what prevents the machine from ever reaching a
deep idle/sleep state.

Goal stated by the repo owner: **the panel should do zero work if no turns
have happened.** This plan gets as close to that as the "live countdown"
feature allows, in three tiers ordered by risk.

## What's already correct (don't re-break this)

Verified by reading the current script, not assumed:

- `ccusage_cached()` (line ~526) gates every `ccusage` invocation behind
  `corpus_changed_since()` (line ~505) — a `find ~/.claude/projects -newer
  <cache_file> -print -quit`, ~0.01 CPU-seconds, vs. ~3 CPU-seconds for a
  real `ccusage` call. `ccusage_query_is_gated()` is an intentional
  always-true stub (line ~523) — every query is a pure function of the
  transcript corpus, so nothing is exempt. **This is correct and already
  eliminates the expensive path when idle.**
- `turn_table_cached()` (line ~880), `session_identity_cached()` (line
  ~812), and `session_today_tokens_cached()` (line ~779) all key on
  `transcript_stamp()` (mtime+size) and skip their `python3`/`ccusage`
  invocation entirely on a cache hit.
- `block_clock_tick()` (line ~1319) is pure arithmetic (`awk`, no fetch) —
  it recomputes the countdown from the block's fixed start/end epochs, not
  from a re-fetch. This is *supposed* to run every fast tick; the countdown
  is genuinely live information, not wasted work. Any optimization below
  must not freeze this when a block is active — that exact regression was
  already fixed once (`ccusage_query_is_gated()`'s own comment describes
  it) and must not come back.
- `refresh_hourly_buckets()` (line ~307) is TTL-gated (900s) with an
  atomic-mkdir lock so concurrent panels don't duplicate the 30-day scan.
  Correct as-is.

None of the above needs to change. The gating logic is sound; don't rewrite
it defensively "for safety" — every one of these functions has a commit in
this repo's history fixing a real, previously-shipped bug in this exact
area (`7ba4fe5`, `3c71c2d`, `8648e0b`). Read `git log -p` on a function
before touching it.

## Tier 1 — dedupe redundant forks per tick (low risk, do first)

Every fast tick (10s), the same transcript file's mtime+size is
independently re-derived via `transcript_stamp()` up to 3 times in one
pass: once inside `turn_table_cached()`, once inside
`session_identity_cached()`, and once inside `session_today_tokens_cached()`
for whichever session(s) are checked that tick. `transcript_stamp()` itself
forks two `stat` processes. That's up to 6 `stat` forks a tick to answer
the same question about the same file multiple times.

**Change:** compute the stamp for the pane's own transcript once per tick,
in the main loop, and pass it into `turn_table_cached()` /
`session_identity_cached()` as a parameter instead of having each function
independently re-derive it. `session_today_tokens_cached()` is called once
per session-shown-in-Top-Sessions, so it necessarily stamps a different
file each time — leave that one alone.

Expected effect: modest, real reduction in per-tick fork count on an idle
pane (roughly halves the `stat` forks). Not the main win — see Tier 2 — but
essentially free to do and zero behavioral risk since it's a pure
call-site refactor of an already-correct cache key.

## Tier 2 — adaptive backoff when idle (the actual fix for "zero work")

This is the one that matters. Right now the main loop (`while true; do ...
sleep "$REFRESH" & wait $!; done`, line ~1900) wakes up every `$REFRESH`
(10s) unconditionally, for the life of the pane — there is no concept of
"nothing is happening, stop checking so often." That fixed cadence is what
keeps the process (and by extension the machine) from ever settling into a
longer idle interval, independent of how cheap each individual check is.

**Change:** track how many consecutive fast ticks have found no corpus
change (the same `corpus_changed_since`-style check already used for the
gate, applied to the pane's own transcript directory) and no active block.
Back off the sleep interval on a schedule, e.g.:

```
0–2 idle ticks:    10s  (unchanged — stay responsive right after activity)
3–11 idle ticks:   30s  (nothing happened for 30–60s)
12+ idle ticks:    60s  (nothing happened for 2+ minutes)
```

Reset to the 10s tier the instant `corpus_changed_since()` reports a change
(a new turn landed) or the terminal is resized. **Never back off while a
block is active and being shown with a live countdown** — the whole point
of `block_clock_tick()` is that it's live; backing off the tier while
`has_block=1` would reintroduce the exact "frozen countdown" bug
`ccusage_query_is_gated()`'s comment describes, just via a different
mechanism. Gate the backoff on `has_block` being unset/0.

This turns "8640 ticks/day, every one doing a bounded amount of work" into
"8640 ticks/day only while something is actually happening; an idle pane
with no active block drops to ~1440 ticks/day (60s cadence)" — a real ~6x
reduction in wakeups for the common case (pane open, nobody typing, no
block running), with no change in behavior anyone would notice: the
information shown doesn't change any faster than the corpus does anyway.

## Tier 3 — event-driven instead of polling (bigger change, do only if Tier 2 isn't enough)

The architecturally "true zero work" version doesn't poll on a timer at
all: it blocks on a filesystem watch (`fswatch` if installed, otherwise
`kqueue` via a small helper, otherwise fall back to today's polling) against
the project's transcript directory, with a timeout equal to whatever
redraw cadence the *live countdown* needs (only relevant when a block is
active). No active block and no filesystem event = the process is
genuinely asleep, not looping.

Flagged as Tier 3 (optional, do last, only if Tier 2's measured
improvement isn't sufficient) because:
- It's a materially bigger rewrite of the main loop's control flow, in a
  script whose git history shows this exact area (signal handling, tty
  restore, the refresh loop) has produced multiple subtle real bugs before
  (`44bc45e`, `8648e0b`). Higher blast radius for the same class of mistake.
- `fswatch` is not guaranteed installed; the kqueue fallback needs its own
  small compiled or `python3`-based helper, which is new surface area.
- Tier 2 likely captures most of the real-world win (the common case is
  "pane open, idle, no block") at a fraction of the risk.

## Suggested order of work

1. Ship Tier 1 + Tier 2 together (they touch the same loop, easy to review
   as one change). Test by: opening a pane, leaving it untouched for 5+
   minutes, confirming via `ps -o %cpu,time` that CPU time stops
   accumulating at the same rate, and confirming a new turn or an active
   block still updates within one tick of actually happening.
2. Measure. Re-check `ps` CPU-time accumulation over a few idle hours
   before deciding whether Tier 3 is worth its risk.
3. Only then consider Tier 3.

## Out of scope for this plan

- `opencode-panel-setup.sh` / `opencode-panel.sh` — not investigated here;
  the same idle-cost question likely applies but needs its own pass since
  it has a different backing CLI (`opencode stats`, not `ccusage`).
- claude-burst (the gateway) — unrelated finding from the same
  investigation: a critical-battery event (2%) caused macOS to kill and
  unload claude-burst's own LaunchAgent, which is now handled by a
  separate self-heal watchdog in that repo. Not a ccusage-panel concern.
