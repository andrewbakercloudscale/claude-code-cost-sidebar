# opencode-panel.sh: idle-cost fix

Written 2026-09-05, as the deferred half of `SLOW-TIER-PLAN.md`'s "Out of
scope" note — that plan investigated `ccusage-panel.sh` only and flagged
this file as needing its own pass, since it has a different backing CLI
(`opencode stats`/`export`, not `ccusage`) and different storage (a SQLite
database, not JSONL files). This is that pass.

## Measured baseline

`ccusage-panel.sh`'s bug was a *cadence* problem: it cached correctly but
refreshed too eagerly. This panel had no caching at all — every tick, every
query, unconditionally, forever.

```
/usr/bin/time -l timeout 60 bash opencode-panel.sh
  60.01 real   26.54 user   1.90 sys   -> 28.44 CPU-s / 60s = 47% of a core
```

Five `opencode` invocations per 5s tick (`session list`, `export <sid>`,
`stats --days 1/7/30`), each ~0.5s of pure Node/Bun process-startup
overhead — the script's own comments already knew this cost existed
("~2.5s of unavoidable overhead before REFRESH's own sleep even starts")
but treated it as fixed rather than avoidable. Extrapolated: **~47% of a
core continuously ≈ 11+ CPU-hours/day**, worse in both relative and
absolute terms than the bug already fixed in the Claude panel, for exactly
the reason its own comment names: no gate, no cache, a 5s default tick
(half the Claude panel's 10s).

## The fix

Same two ideas as `ccusage-panel.sh`, adapted to a different storage
engine:

1. **A shared on-disk cache** (`~/.cache/opencode-panel-cache`), keyed by
   query string, with an mkdir-lock — so N open panels pay for one fetch,
   identical to `ccusage_cached()`.
2. **A corpus-change gate.** OpenCode's transcript is a SQLite database in
   WAL mode (`~/.local/share/opencode/opencode.db` + `-wal` + `-shm`)
   rather than a JSONL tree, but the principle is the same: every report is
   a pure function of that database's content, so if nothing has written
   to it, re-running the query cannot produce a different answer.
   `oc_corpus_changed_since()` checks `-newer` against all three files —
   WAL-mode checkpointing can leave the `-wal`/`-shm` files as the only
   ones that moved, so checking the main `.db` alone would miss writes.
3. **Two TTL buckets**, same reasoning as the Claude panel's live/history
   split: `stats --days 7/30` (a baseline that cannot move meaningfully
   inside a couple of minutes) get a long TTL; `session list` and
   `stats --days 1` (needed to notice a brand-new session, and to keep
   Today live) stay short. Neither is a whole multiple of the tick, for
   the same rounding-coin-flip reason documented in the Claude panel.
4. **`export` is keyed on the session's own `updated` timestamp**, not a
   TTL and not the whole-database gate — tighter and cheaper than either.
   This session's export cannot have changed unless *this* session's
   `updated` field moved, regardless of what any other session in the
   database is doing, and that field comes free out of the `session list`
   fetch every tick already makes. One cache file per session id (its
   stamp on the first line, same pattern as `turn_table_cached()` in the
   Claude panel), pruned past 7 days so it doesn't accumulate forever —
   the Claude panel's equivalent per-transcript cache has the same
   unbounded-growth shape and is not pruned; flagged here, not silently
   fixed there, since that file is out of scope for this pass.

A `PANEL_LIB_ONLY=1` seam (identical to the Claude panel's) lets tests
source the cache functions without entering the render loop or touching a
real terminal.

## Measured, after

```
PATH=<counting-shim>:$PATH /usr/bin/time -l timeout 60 bash opencode-panel.sh
  60.00 real   6.74 user   1.83 sys   -> 8.57 CPU-s / 60s = 14% of a core
```

**28.44 → 8.57 CPU-s over the same 60s window: −70%.** Invocation count
over 12 ticks: **60 → 9** (`session`×3, `stats`×5, `export`×1) — matching
the design exactly: `session`/`stats --days 1` refetch on the short TTL
(~3× in 60s), `stats --days 7/30` refetch once each (inside the long TTL),
`export` doesn't refetch at all because the test corpus was idle.

Read the 70% as a floor for the same reasons the Claude panel's number
was: 60s is only a few TTL windows, and the corpus was idle throughout,
which is the best case for the gate rather than the worst. On a pane being
actively used the saving is smaller per tick but the invocation count is
still bounded by the TTLs rather than by REFRESH, which is the actual
property that matters.

## Tests

`tests/opencode/run-tests.sh` — same two rules as the Claude panel's suite
(gate on exit codes, fail a check that ran zero assertions), scoped to the
cache primitives directly rather than the full render loop, since this
script has no function-per-section architecture to test through:

| Check | Covers |
|---|---|
| A — corpus gate | TTL lapsed + db unchanged → still no refetch; db changed → exactly one |
| B — TTL buckets | `stats --days 7/30` get the long TTL; `session list`/`stats --days 1` get the short one; neither is a whole multiple of the tick |
| C — export stamp | same (session, stamp) → cached; stamp moves → one refetch; a different session is its own entry |
| D — shared across panels | 3 concurrent panels cost one fetch, and one refetch when the db changes |

4 checks, 17 assertions. One harness trap on the way, the same shape as
every one in `SLOW-TIER-PLAN.md`: a plain (non-exported) variable set only
inside a subshell that had sourced the panel does not exist in the parent
shell, so a check computing a cache path from it silently worked on an
empty string — fixed by deriving the path from `$HOME` directly, which is
the one thing the check can know without sourcing anything.

## Rollout

1. Cache layer + seam. **Done.**
2. Tests. **Done**, 4/4 passing; verified against the reverted call sites
   too (the cache *functions* stay correct in isolation — the call-site
   wiring itself was verified separately via the counting-shim measurement
   above, since forcing that through the unit checks would mean re-adding
   the bug just to prove a negative).
3. Live smoke test: clean stderr, correct session/model/context/turn table
   from the real database. **Done.**
4. Installer (`opencode-panel-setup.sh`) resynced; embedded copy verified
   byte-identical to the installed script. **Done.**

## Out of scope for this pass

- The per-transcript export cache's unbounded growth in *this* file is
  pruned (7-day TTL); the equivalent gap in `ccusage-panel.sh`'s
  `turns-<key>.out` cache is not, and is noted here rather than fixed —
  touching that file was not part of this pass.
- No cost-alert-equivalent hook exists for OpenCode on this machine (there
  is no `opencode-cost-alert-check.sh`), so there was nothing analogous to
  `claude-cost-alert-check.sh`'s baseline-scoping bug to check for here.
