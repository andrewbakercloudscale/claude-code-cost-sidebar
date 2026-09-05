# ccusage-panel.sh: slow-tier efficiency plan

Written 2026-09-05. Supersedes the Tier 1/2/3 proposal in
`OPTIMIZATION-PLAN.md`, which correctly identified the cost but attributed it
to the wrong tier. Everything below was measured on this machine against the
live 653MB / 347-file corpus with `ccusage` 20.0.20; nothing here is
estimated from reading the code.

The goal is unchanged: **stop the panel burning ~47 CPU-minutes a day while
showing numbers nobody is watching change.** What changed is where the cost
turned out to live, and therefore what is worth doing.

---

## 1. Decision summary

| Phase | Change | Saving | Risk |
|---|---|---|---|
| **1** | Split one global cache TTL into two coherence buckets | ~7 min/day | Low |
| **2** | Drop the `ccusage statusline` fetch; compose that line from data already on hand | ~25 min/day | Medium |
| **3** | Incremental rollup replacing ccusage in the hot path | most of the rest | High — deferred, not scheduled |

Phase 1 alone is **not** worth shipping on its own merits (~7 min of ~47). It
is worth shipping first anyway, because it builds the test harness and the
staleness discipline that Phase 2 needs in order to be safe. Phase 2 is the
main event.

Do **not** slow the fast tier. It is 5 of the 47 minutes and it is the only
thing in the panel anyone actually watches move.

---

## 2. Measured baseline

### 2.1 Method, and one trap to avoid repeating

`ps -o time` reports a process's **own** CPU only — it excludes reaped
children. The panel's work is almost entirely in forked `node`/`python3`/`jq`
children, so `ps` under-reports it by ~30x: the live panel process shows
~0.09 CPU-s over 87s (≈1 min/day) while the true figure is ~49 min/day.

`OPTIMIZATION-PLAN.md`'s "~47 minutes of accumulated CPU time in `ps`" is the
right total attributed to the wrong place. **Always measure with
`/usr/bin/time -l`, which sums children.** This is the same class of mistake
as gating on the absence of matched output: the tool answered a question, it
just wasn't the question asked.

### 2.2 End-to-end

```
/usr/bin/time -l timeout 150 bash ccusage-panel.sh 10 12 <sid>
  150.44 real   3.17 user   1.99 sys   -> 5.16 CPU-s / 150s
```

**3.4% of one core = 2963 CPU-s/day ≈ 49 min/day.** This reproduces the
originally observed ~47 min, so the premise of the original plan is sound.

### 2.3 Tier split

Isolated by pinning `SLOW_REFRESH=99999` and varying `REFRESH`:

| Run | Wall | CPU |
|---|---|---|
| `REFRESH=10`, slow tier off | 60s | 1.44s |
| `REFRESH=1`, slow tier off | 60s | 3.38s |

Marginal fast tick = (3.38 − 1.44) / 54 = **0.036 CPU-s**.

| Tier | Ticks/day | Cost each | Cost/day |
|---|---|---|---|
| Fast (10s) | 8640 | 0.036s | **311s ≈ 5 min** |
| Slow (120s) | 720 | ~2.3s avg | **~2660s ≈ 44 min** |

**~90% of the panel's CPU is the slow tier.** The original Tier 2 (back off
the fast tick) had a ceiling of ~5 min/day and cost live responsiveness to
get it.

Caveat on 0.036: measured with stdout redirected, so `stty size` failed and
`drain_stdin` short-circuited on an unset `ORIG_STTY`. In a real tty pane the
fast tick is somewhat more expensive. It does not change the ordering.

### 2.4 Per-query cost — the number that decides the plan

Each query, run cold, CPU-s (user+sys):

| Query | Call site | CPU-s | Feeds |
|---|---|---|---|
| `statusline -B text` | 1566 | **2.11** | Model, Session $, Today $, Block $ + time left, burn rate, Context % |
| `daily --sections daily,weekly,monthly` | 672 | 1.03 | 7d avg, 30d spend, trends, week/month totals, Last 3 days |
| `blocks --active` | 1283 | 0.73 | Active block cost/tokens |
| `session` | 682 | 0.71 | Top 5 sessions today, 7d/prev-7d session baselines |

Full-miss slow tick = **4.58 CPU-s**. Observed average is ~2.3, i.e. roughly
half the queries are served from cache in practice (shared with the second
panel, or held by the corpus gate).

**`statusline` alone is 46% of a full-miss slow tick** — more than any other
query, and more than the entire fast tier costs in a day.

---

## 3. Dead ends — measured, do not retry

Recorded so the next person doesn't spend the afternoon I spent.

| Idea | Result | Why |
|---|---|---|
| `--since` to bound the scan window | 1.02 CPU-s vs 1.02 full — **0%** | Filters after loading. Also moot: 630MB of the 653MB corpus is inside 30 days. |
| Fold `session` into `--sections` (3 scans → 2) | 1.70 vs 1.74 — **2%** | Output byte-identical (verified with `jq -S`), so it is *correct* — just not faster. The corpus load is shared; per-section aggregation is not, and that is the cost. |
| `--by-agent` to get Claude-only figures from one scan | `byAgent: null` in every row | Non-functional on ccusage 20.0.20, with and without `--sections`. |
| `ccusage claude ...` for scoping | Same 1.01 CPU-s | No perf change. Has a **correctness** implication — see §9. |

The lesson that generalises: on this corpus the scan is ~0.7 CPU-s and the
aggregation is the rest. Anything that shares a load without sharing the
aggregation buys nothing.

---

## 4. Design: coherence buckets

The current cache has **one** TTL for all queries:

```sh
CCUSAGE_CACHE_TTL=$(( SLOW_REFRESH * 3 / 4 ))   # 90s
```

and its comment (line 465) is explicit that this is deliberate: the TTL's
only job is to stop N panels stampeding the same query, while
`corpus_changed_since()` is the real arbiter — *refetch iff the answer can
actually have changed*.

**Per-query TTLs break that principle on purpose,** and it must be stated
plainly rather than slipped in: a 900s TTL serves a stale answer **even when
the corpus has changed and the answer is known to be different.** That is a
new behaviour for this panel. Everything in §6 exists because of it.

The organising rule is not "how fast does this change" but:

> **Coherence rule — numbers that are compared, summed, or read against each
> other on screen must be computed from the same snapshot.**
>
> A TTL boundary is therefore a boundary between groups of figures that never
> need to agree. Splitting a group is how the panel starts contradicting
> itself.

### Buckets

| Bucket | TTL | Queries | Rationale |
|---|---|---|---|
| **live** | 90s (unchanged) | `blocks --active`, `statusline`¹, `daily --sections ...` | Tied to money accruing right now |
| **history** | 900s | `session` | The day's session ranking and the 7-day session baselines. A ranking does not reorder inside a quarter of an hour. |

¹ `statusline` is in the live bucket only until Phase 2 deletes it.

**`daily` was moved back to the live bucket during implementation, and the
reason is worth recording.** The same payload that carries the 7/30-day
baselines also carries **today's total** — one of the two or three numbers
this panel exists to watch climb. Deferring it 15 minutes would make Today
*step* rather than move, and only while turns are landing, which is exactly
when someone is looking at it. The baselines would happily be deferred; they
just do not arrive on their own.

So **the freshness of Today is what actually costs here**, and no arrangement
of TTLs changes that: it is one corpus scan per tick, or a stale number.
Phases 2 and 3 are the levers on it. Phase 1 is not, and its saving is
correspondingly smaller than this plan first claimed.

That leaves `session` and `daily` in *different* buckets, which the coherence
rule warns about — and it is safe here **only because of the direction of the
skew**. The sessions side is the stale one, so "Top Sessions Today" lags the
day total and can never sum to more than it. Reverse the assignment and the
panel would show a set of sessions adding up to more than the day they belong
to. Check C asserts the direction, not merely the numbers.

### Projection

Worst case (corpus changing continuously, i.e. the multi-session case that
produced the original report):

| | live bucket | history bucket | fast tier | total |
|---|---|---|---|---|
| Now | (2.11+1.03+0.73)×720 = 2786s | (0.71)×720 = 511s | 311s | **~60 min/day**² |
| Phase 1 | 2786s | 0.71×96 = 68s | 311s | **~53 min/day** |
| Phase 1+2 | (1.03+0.73)×720 = 1267s | 68s | ~350s | **~28 min/day** |

² Worst case exceeds the observed 49 min because the observation includes
corpus-gate and cross-panel cache hits. Use it for ranking, not forecasting.

**Phase 1 buys ~7 min/day worst case (~4 realistic). Phase 2 buys ~25 more.**
Phase 1's honest justification is not its saving; it is the harness and the
staleness discipline that make Phase 2 safe to attempt.

### 4.1 Concurrent sessions

One panel is launched per Claude Code session, so everything above multiplies
by the session count — except what the shared cache absorbs. Measured, and
asserted in check M:

| Cost | Shared across sessions? |
|---|---|
| `daily`, `session`, `blocks` | **Yes** — one filesystem cache keyed by the query string, with an mkdir lock. Three panels cost one scan. |
| Hourly buckets (30-day scan) | **Yes** — its own lock, same pattern. |
| Cost-alert baseline | **Yes** — the hook's key carries no session id. |
| `statusline` | **No.** Its key includes the session id and transcript path, because the answer genuinely is per-session. |

So **each additional concurrent session costs ~25 CPU-min/day on its own**
(720 statusline fetches × 2.11 CPU-s), plus ~5 min for its own fast tier.
Nothing else scales with session count.

Two consequences:

1. **Phase 2 matters more the more sessions you run.** It is worth ~25
   min/day for one session and ~25 min/day *per session* after that. On the
   two-panel machine this investigation started from, that is the majority of
   the total.
2. **The jitter must be derived from the cache key, never from `$RANDOM` or
   the pid.** Every panel has to compute the *same* expiry for the same
   query, or N panels stagger into N separate fetches of one shared entry and
   the cross-panel cache stops being a cache. Check M asserts three panels
   share one refetch.

---

## 5. Phase 1 — per-query TTL buckets

### 5.1 Changes

1. `ccusage_cached()` and `ccusage_cached_stdin()` take a TTL rather than
   reading the global. Resolve it from the query, not from the call site, so
   two callers of the same query cannot disagree:

   ```sh
   # Bucket a query by its ccusage subcommand + flags. Unknown queries fall
   # into the live bucket: a new query that nobody has classified must be
   # WRONGLY EXPENSIVE, never wrongly stale.
   ccusage_ttl_for() {
     case "$1" in
       blocks|statusline) printf '%s' "$TTL_LIVE" ;;
       daily|session)     printf '%s' "$TTL_HISTORY" ;;
       *)                 printf '%s' "$TTL_LIVE" ;;
     esac
   }
   ```

2. Preserve the "never equal to the tick" invariant that line 465 documents,
   for **every** bucket, not just the old global one:

   ```sh
   TTL_LIVE=$(( SLOW_REFRESH * 3 / 4 ))          # 90s
   TTL_HISTORY=$(( SLOW_REFRESH * 15 * 3 / 4 ))  # 1350s at SLOW_REFRESH=120
   ```

   Both stay a proper fraction of the tick, so a slow tick always finds the
   TTL lapsed and always defers to the corpus gate. An exact multiple
   reintroduces the coin-flip that produced "an observed 240s effective
   refresh on a header advertising 120s".

3. **Jitter.** Every cache entry is seeded when the panel starts, so without
   jitter all history entries expire on the same tick, forever — one lurch
   and one CPU spike rather than several small ones, synchronised across
   panels. Apply a deterministic per-key offset, not `$RANDOM`, so the value
   is stable across ticks for a given key:

   ```sh
   # 0..14% of the TTL, derived from the cache key, so each query flushes on
   # its own schedule and two panels agree on when that is.
   jitter=$(( 0x$(printf '%s' "$key" | cut -c1-2) % 15 ))
   ttl=$(( ttl + ttl * jitter / 100 ))
   ```

4. **Label honesty.** `rate_tag` on each section must be derived from the TTL
   that actually governs that section's data, not from `RATE_SLOW`. Sections
   fed by the history bucket say `15m`; the block section says `2m`. The
   panel has shipped a lying rate label before (header said 5s while figures
   moved every 10) and the fix was to derive the label from the variable —
   the same fix applies here, per bucket.

### 5.2 Explicitly out of scope for Phase 1

- Anything touching `REFRESH` or the fast tier.
- The four `all_sessions` calls per slow tick (lines 1467, 1491, 1694, 1830):
  three are cache **hits**, but each still re-reads and re-parses a 131KB
  payload. Memoising it in a shell variable for the duration of one tick is
  worth ~0.1 CPU-s/tick and is a clean, separate change. Do it after the
  harness exists.

---

## 6. Staleness: flush, drift, and rebaseline

This is the part that turns a saving into a bug, and it is the reason Phase 1
ships with tests rather than after them.

### 6.1 Drift — the panel contradicting itself within one frame

With two buckets, a frame is assembled from two snapshots up to 15 minutes
apart. Concrete incoherences, in the order a user would notice them:

| Symptom | Mechanism | Handling |
|---|---|---|
| "This Session" shows $5.49 but "Today" shows less | Session table is fast-tier (10s); Today is history (15m) | **Accept, and label.** Today's tag says `15m`; the session line says `10s`. Honest, and the sum only misleads if both claim to be current. |
| Top 5 sessions sum > Today total | Would need `session` and `daily` in different buckets | **Prevent.** Coherence rule — they share a bucket. Tested (check C). |
| Block value > Today value | Block is live (90s), Today is history (15m) | **Prevent by ordering:** clamp the displayed Today to `max(today, block)` — never render an impossible pair. Log, don't silently clamp, if the clamp fires more than once an hour: that means a bucket is mis-assigned. |
| Burn rate normal, session cost red | Alert tiers compare a live session cost to a stale 7-day baseline | See §6.3 |

The rule for anything not in that table: **if two numbers on screen can be
subtracted or summed by eye, they belong in one bucket.**

### 6.2 Flush — the step change when a long TTL lapses

A 15-minute bucket does not drift gently. It sits still for 15 minutes and
then jumps by 15 minutes' worth of accumulated spend in a single frame.

Consequences and handling:

- **Step change reads as a glitch.** Acceptable given an honest `15m` label;
  a user who sees "15m" expects a 15-minute step. Do not smooth or
  interpolate — a fabricated intermediate value is worse than a visible step.
- **Δ columns must never straddle a flush.** Any "change since last refresh"
  figure computed across a flush reports 15 minutes of change as if it were
  one tick's worth. Audit every Δ on screen; the per-turn table's Δ is
  fast-tier and transcript-derived, so it is safe, but this must be asserted
  (check F) rather than assumed to stay that way.
- **Convoy.** Without jitter, every history entry flushes on the same tick,
  in every panel, forever. With jitter (§5.1.3) they spread over ~2 minutes.
  Tested (check G).
- **Cold start is a full miss by definition.** A newly opened pane pays 4.58
  CPU-s. That is correct and should stay: a fresh panel showing 15-minute-old
  numbers on its first frame would be the worse bug.

### 6.3 Rebaseline — derived baselines shifting under the figures they colour

The panel's traffic lights are computed against baselines that themselves
come out of cache: 7-day average session cost, previous-7-day average, 30-day
spend, previous-30-day spend, and the 900s hourly buckets behind "Today's
Predicted Value".

Three distinct hazards:

1. **A colour flips with no change in behaviour.** When the 7-day baseline
   rebaselines, a session cost that has not moved can cross from green to
   amber. The panel is not wrong, but it looks like something happened.
   *Handling:* baselines move to the history bucket, so they change at most
   every 15 minutes, and the tag says so. A colour change is then attributable
   to a visible event rather than an invisible one.

2. **The cost-alert hook fires on a stale denominator.** `claude-cost-alert-check.sh`
   posts into the chat at 2x and 3x the 7-day average session cost. It reads
   the same shared cache. A stale-low baseline makes the tiers fire early; a
   stale-high one makes them fire late — and the hook throttles per session,
   so an early fire *consumes* the tier and the real crossing is never
   reported. **This is the one place where staleness causes a wrong action
   rather than a stale display.**
   *Handling:* the hook must read the baseline with `TTL_LIVE`, not
   `TTL_HISTORY` — it runs once per prompt, not 720 times a day, so its share
   of the cost is negligible and correctness wins outright. Tested (check H).

3. **Clock-dependent slicing is not corpus-dependent.** `ccusage_query_is_gated()`
   asserts "every query is a pure function of the transcript corpus". True of
   the raw payloads. **Not** true of what the panel displays: `daily_window`
   (line 731) and the Top Sessions filter (line 1830) slice the cached payload
   with `$(date +%Y-%m-%d)` evaluated *at render time*, and the 7/30-day
   windows are recomputed from the clock on every tick.

   Today this is correct — and correct by construction, not by accident: the
   payload is cached, the slice is not. At midnight, with no activity, "Today"
   re-slices to the new date and correctly reads $0 rather than carrying
   yesterday's total forward.

   **It is also completely unguarded.** Any future optimisation that caches a
   *sliced* result — an obvious next step for someone chasing the same CPU —
   silently breaks it, and the failure mode is a panel that shows yesterday's
   money as today's until someone happens to type. Longer TTLs widen that
   window from 90s to 15 minutes.
   *Handling:* make the invariant explicit in a comment at both slice sites,
   and test it (check D). This is the single highest-value test in the plan:
   it guards a property that is currently right, that nothing else protects,
   and whose violation is silent.

### 6.4 Block-boundary expiry

`blocks --active` returns the current 5-hour billing block. When a block ends
and no new turn has landed, the corpus has not changed — so the gate holds the
cached entry and the panel keeps rendering a countdown for a block that is
over, at "0m left", indefinitely.

This is a **pre-existing** bug, not one this plan introduces, and the same
clock-vs-corpus confusion as §6.3. Fix it here because this plan is what makes
it worse: invalidate the block entry when `now > endTime`, regardless of the
corpus gate. Tested (check E).

---

## 7. Phase 2 — delete the `statusline` fetch

### 7.1 Why it is available

`ccusage statusline` costs 2.11 CPU-s to return six fields. The panel already
holds, or can cheaply derive, every one:

| Field | Where it already exists |
|---|---|
| Model name | `resolve_session()` — already parsed from the transcript |
| Session $ | The per-turn table prices every turn of this session (fast tier, 0.036 CPU-s) |
| Today $ | `recent_sections` — already fetched |
| Block $ + time left | `blocks --active` + `block_clock_tick()` — already fetched, already computed locally |
| Burn rate $/hr | Derived from the block, as `block_clock_tick()` already does |
| Context % | Context tokens are already in the turn table; only the **window size** denominator is missing |

So Phase 2 is mostly a composition change, not new computation. The only new
data is a model → context-window table, alongside the `PRICES` table the panel
already carries and maintains for exactly the same reason.

### 7.2 What it actually took — done 2026-09-05

Smaller than this section expected, because two of the three fields were
already in hand:

- **Model name** was never ccusage's to give. The panel resolved it from the
  transcript and *passed it into* the statusline payload, then read it back
  out of the rendered string it came home in.
- **Session cost and context tokens** were both already computed by the
  turn-table parser as a by-product of pricing each turn — they simply were
  not emitted. The parser now prints a `#META` line the shell strips before
  the table reaches the screen, and `session_stats_refresh()` splits it into
  `SESS_COST` / `SESS_CTX` / `SESS_WIN` on every fast tick, before either
  builder runs, so the slow-tier summary and the fast-tier table read the
  same session from the same parse.
- **The context window** turned out to be duplicated: `context_window_size()`
  existed in the bash panel *and* in the python parser, "kept in sync
  manually", both computing a denominator for the same displayed percentage.
  The window now travels in the metadata line from the newest turn's own
  model, and the bash copy is deleted. One rule, one copy — and it is the
  model that actually served that context, not whatever `resolve_session`
  last saw, which differ across a mid-session model switch.

`ccusage_cached_stdin()` was left with no callers and is deleted too (61
lines). Dead code that still looks live is a hazard: the next person needing
a stdin query would find a tested-looking path that had not run in months.

**The unknown-model rule was open here, and closed in §9.2.** This section
originally called for `Context —` on an unmapped model but left
`context_window_size()` defaulting to 1M for anything it did not recognise —
turning it into an allowlist meant asserting context windows for models this
plan could not verify at the time. §9.2 verified the full table against the
`claude-api` skill and closed it: the function is now an allowlist keyed on
`PRICES`, an unknown id returns 0, and the panel renders `Context Usage: N/A`
rather than guessing. See §9.2 and §9.3 for what that verification pass also
caught (two missing models, a divide-by-zero, and a parser crash that served
a stale table silently).

### 7.3 Verification

Check J asserts the arithmetic exactly rather than within a tolerance — the
fixture's token counts and Anthropic's published rates are both exact:

```
m1 = (100*5 + 50*25 + 1000*5*0.1 + 200*5*1.25) / 1e6 = 0.003500
m2 = (200*5 + 100*25 + 2000*5*0.1 + 400*5*1.25) / 1e6 = 0.007000
                                          SESS_COST = 0.010500
```

plus: the context figure is the newest turn's occupancy, the window comes
from the same parse, neither costs a ccusage query, and `#META` never reaches
the screen. It also covers the upgrade path — a cache entry written before
the metadata line existed stays valid (it is keyed on the transcript's
mtime+size) and stays served, so the figures must come back **empty** and the
summary print `--`, rather than being parsed out of a table row and rendered
as money.

---

## 8. Test plan

There is **no test infrastructure in this repo today**. Phase 1 creates it.
This is a deliberate cost: the changes in §5–§7 trade correctness for CPU in
ways that fail silently, which is precisely the class of bug this codebase has
been bitten by repeatedly.

### 8.1 Seams needed (small, in the panel)

Both are prerequisites, and both are independently worth having:

1. **`panel_now()` / `panel_date()`** wrapping every `date` call used for
   windowing, honouring `PANEL_FAKE_NOW` when set. Without this, day- and
   block-boundary behaviour cannot be tested at all — it can only be waited
   for.
2. **`$HOME` already works as the corpus seam** (`$HOME/.claude/projects`,
   `$HOME/.cache/...`), so tests point `HOME` at a fixture tree. No change
   needed — but document it, because it is load-bearing.

### 8.2 Harness

`tests/run-tests.sh`, following this repo's stated discipline:

- **Gate on exit codes, never on the absence of matched output.**
- **Every check reports how many assertions it ran**, and the harness fails if
  any check reports zero. A check that has quietly stopped covering anything
  must be visible, not reassuring.
- A **stub `ccusage`** placed first on `PATH`, returning fixture JSON and
  appending one line per invocation to a counter file. Invocation counts are
  the primary assertion for everything in §5 — they are exact, fast, and
  hermetic, where CPU seconds are none of those.
- A **fixture corpus** of synthetic JSONL with known token counts, so expected
  costs are exact numbers rather than tolerances.

### 8.3 Checks

| # | Check | Assertion |
|---|---|---|
| **A** | TTL bucketing | Over 30 simulated slow ticks: `blocks` invoked exactly 30x, `daily`/`session` exactly 2x each. Exact counts, not "fewer than before". |
| **B** | Corpus gate still governs | No corpus change → 0 refetches after the first. `touch` one transcript → exactly 1 refetch per gated query, not 2. |
| **C** | Bucket coherence | Across a turn landing mid-window: sum(Top 5 today) ≤ Today total, in every frame. Fails if `session` and `daily` are ever split. |
| **D** | Clock-slice invariant (§6.3) | `PANEL_FAKE_NOW` = 23:59:50 → tick → 00:00:10 → tick, with **no corpus change**. Today must read 0.00, not yesterday's total. 7d/30d windows must shift by one day. **The highest-value check here.** |
| **E** | Block expiry (§6.4) | Fake now past `endTime`, corpus unchanged → panel must not render an active block. |
| **F** | No Δ straddles a flush | Every rendered Δ is fast-tier/transcript-derived. Enumerate Δ call sites; fail on any reading a history-bucket value. |
| **G** | Flush convoy | Over 1000 simulated ticks, assert no tick flushes more than one history key — i.e. jitter works and is deterministic. |
| **H** | Alert baseline freshness (§6.3.2) | `claude-cost-alert-check.sh` reads the 7d baseline at `TTL_LIVE`. Simulate a session crossing 2x with a 14-minute-stale baseline: the alert must still fire at the true crossing. |
| **I** | Unknown model (§7.2) | Transcript with an unmapped model id → output contains `Context —` and **no** `%` on that line. |
| **J** | Phase 2 parity | Locally composed statusline fields vs `ccusage statusline`, over the fixture corpus: every field within 1%. Blocks the deletion in §7.3. |
| **K** | Label honesty (§5.1.4) | For each section, the rendered `rate_tag` equals the TTL governing that section's data. Guards the panel's oldest recurring bug. |
| **L** | Invocation budget | A 30-tick run makes ≤ N ccusage invocations. A cheap, deterministic stand-in for a CPU regression test. |

### 8.4 What is deliberately not tested

Wall-clock CPU. It is machine- and load-dependent and would produce a flaky
gate that gets ignored, then disabled, then removed. Invocation counts (check
L) are the proxy; real CPU is measured by hand at rollout (§10) and recorded
in this file.

---

## 9. Scoping to Claude Code — done 2026-09-05

`ccusage daily` means *every detected agent CLI*. Measured simultaneously,
with the unscoped run repeated either side of the scoped one and giving the
identical figure both times:

- all-agent: **$6823.37** (before **and** after)
- Claude-only: **$6809.21**

A real **$14.16** being reported by a panel titled "Claude Code Usage".

`ccusage claude` rejects `--sections`, so the one combined load becomes three.
That is affordable only because of where each lands: `daily` carries Today and
stays in the live bucket at the same ~1.01 CPU-s the combined call cost, while
`weekly` (0.73) and `monthly` (0.72) move to the history bucket — 96 fetches a
day instead of 720, about **+2.3 CPU-min/day** for the correctness.

### 9.1 The trap in it, and why the suite did not catch it

**The scoped reports do not use the unified report's key names.**

| unified (`--sections`) | scoped (`claude <sub>`) |
|---|---|
| `.daily[].period` | `.daily[].date` |
| `.weekly[].period` | `.weekly[].week` |
| `.monthly[].period` | `.monthly[].month` |
| `.session[]` | `.sessions[]` |
| `.session[].period` (id) | `.sessions[].sessionId` |
| `.session[].metadata.lastActivity` | `.sessions[].lastActivity` |

Nothing errors on any of that. `select(.period == $t)` matches no row, and
**Today, Folder and 30-Day Value each render a confident $0.00** — which is
exactly what the panel did, while all fourteen checks reported green.

They reported green because every fixture had been written in the *old*
shape. **A fixture that does not match what the real tool emits is not a
test; it is a second copy of the bug.** All fixtures are now the real shapes,
verified against live output, and check Q covers the adapter directly —
removing the rename now fails C, D and Q.

It was the **live smoke test** that caught this, not the suite. That is why
the smoke run is a numbered step in the rollout below rather than a nicety.

## 9.2 Model table — verified, and two models were missing

Checked against the `claude-api` skill's model table (cached 2026-06-24). All
nine existing prices were correct. Two current models were **absent**:
`claude-fable-5-1` and `claude-mythos-5-1`, both $10/$50.

A turn served by either was priced at `DEFAULT_PRICE` ($3/$15) — **under-reported
3.3x**, and indistinguishable from any other row. Both added.

The same table confirms every context window: 1M for everything except Haiku
4.5 at 200K. That closes §7.2's open item, and closes it with facts rather
than guesses:

- `context_window_size()` is now an allowlist keyed on `PRICES`. An id it does
  not know returns **0**, and the panel renders `Context Usage: N/A` rather
  than dividing by a window nobody knows. (It also returned 1M for anything
  unrecognised *before* Phase 2 — this was a pre-existing gap, not a new one.)
- An unpriced model is still charged at `DEFAULT_PRICE`, because excluding it
  would silently understate the session total, which is worse. But the table
  now prints `* estimated at default rates, model not in price table: <id>`
  underneath. Add the id and the line goes away.
- Check N asserts the two duplicated `PRICES` tables (one per python heredoc,
  a documented manual sync) still agree, and spot-checks the rates that would
  be expensive to get wrong.

## 9.3 Two bugs found while doing the above

- **A crashed parser served a stale turn table forever.** `{ ... } > tmp && mv`
  skipped the `mv` on failure, then `tail` ran unconditionally on the previous
  file — so a parse that died showed a correct-looking, arbitrarily old table
  with nothing to indicate either. It now prints `turn table unavailable:
  transcript parse failed` and leaves the cache untouched. Same failure shape
  as every gate in this project that reported OK while measuring the wrong
  thing.
- **Row colouring divided by the context window without checking it.**
  Returning 0 for an unrecognised model turned that into a hard crash on the
  first such turn — found by check I, before it could ship.

## 9.4 Frame elision

Between slow ticks nothing in the pane can move unless a turn landed: the
summary and trailing sections are rebuilt on the slow tier, and the header's
clock string with them. So eleven of every twelve fast ticks composed a frame
identical to the one already on screen and wrote it anyway.

The frame is now compared before it is written. The saving is mostly **not**
the panel's: every write is a repaint in the terminal emulator, charged to
Ghostty, **once per open panel** — so it is the part of the fast tier that
scales with the number of concurrent sessions. No separate periodic repaint is
needed: a slow tick rebuilds the header with a new clock string, so the frame
differs at least once every `SLOW_REFRESH` and the pane cannot sit stale after
an external scribble.

## 10. Rollout

1. **Seams + harness + checks A, B, D, E, K** — no behaviour change. D and E
   should fail on the current code (E is a live bug); fix E, confirm D passes.

   **Done 2026-09-05.** `panel_now()`/`panel_date()` route all 47 wall-clock
   reads and honour `PANEL_FAKE_NOW`; `PANEL_LIB_ONLY=1` sources the file
   without entering the render loop. `tests/run-tests.sh` runs 5 checks / 29
   assertions against the installed panel (`PANEL_SH=` to point elsewhere).
   The block-expiry bug (§6.4) is fixed in `block_clock_tick()`, and check E
   was verified to fail against the same panel with only that fix removed —
   rendering `Current Block: $4.50 (0h 00m left)`, the symptom itself. D
   passes: crossing local midnight with an unchanged corpus re-slices Today
   to 0.00 and refetches nothing.

   Two traps hit while writing the checks, both worth knowing before adding
   more: `corpus_changed_since()` has no `-type` filter, so a fixture that
   backdates only its files leaves the DIRECTORIES at "now" and the gate
   fires on those; and the panel runs under `set -u` with globals that
   `resolve_session()` sets, so calling `build_summary()` directly yields a
   one-line stump that silently satisfies any `assert_not_contains`. Both
   produced a check that passed while measuring nothing. Hence
   `panel_tick_slow()` (drive the loop's real order) and the positive
   control in E.
2. **Phase 1**, with checks C, G, H, L. **Done.**
3. **Phase 2** (§7). **Done** — check J asserts the arithmetic exactly rather
   than needing a day of parity logging.
4. **`ccusage claude` scoping** (§9). **Done**, and it moved ahead of the
   re-measurement because Phase 2 had already paid for it.
5. **Run the panel and read it.** Not optional, and not last: the shape drift
   in §9.1 rendered three headline figures as $0.00 with the entire suite
   green. Every step above ends with
   `timeout 30 bash ~/.local/bin/ccusage-panel.sh 10 12 <sid>` from the
   project directory, and with looking at what it prints.
6. **Measure.** `/usr/bin/time -l` (never `ps` — see §2.1), same corpus, cold
   cache, **nothing else running**: a live panel sharing the cache directory
   silently serves the run under measurement and the numbers become
   meaningless. Record below.
7. **Phase 3** only against that number, not against this plan's projections.

### Measured, 2026-09-05

420s per side, sequential, cold cache, no other panel running:

| | CPU over 420s | corpus scans |
|---|---|---|
| before (`45f9f73`) | 15.76 user + 8.41 sys = **24.17 s** | 16 |
| final | 10.68 user + 6.34 sys = **17.02 s** | 10 |
| | **−30%** | **−37%** |

Read that as a floor, not a ceiling, for three reasons — all of which push the
steady-state saving higher than the window shows:

- **420s is 3.5 slow ticks**, and both sides pay a full cold-cache fetch of
  every query at t=0. The startup is a fixed cost the "before" panel amortises
  over the same short window.
- **The history bucket's 900s TTL cannot expire inside 420s**, so its benefit
  appears once rather than repeatedly.
- **The corpus was changing throughout** (this session was working), which is
  the worst case for the corpus gate and the case the original report came
  from.

Three of the "final" run's ten scans are bare, unscoped `session` calls — the
cost-alert hook, which was still unscoped when this ran and has since been
scoped too (§9.5). The panel's own share is 7.

**Rollback:** `rollback-cost-panel.sh` restores the previous
`ccusage-panel.sh`. Every phase is independently revertible; Phase 2 is the
only one that deletes anything, and it is gated on a day of parity evidence.

---

## 9.5 The cost-alert hook was unscoped too

Found in the measurement's own scan log: three bare `session` calls the panel
does not make. `claude-cost-alert-check.sh` computed its 7-day average from
**all-agent** session data, so the 2x/3x thresholds it posts into the chat
were measured against a denominator diluted by every other agent CLI — and
because it throttles per session and per tier, firing at the wrong time
consumes the tier and the real crossing is never reported.

Now scoped, with the same `.sessions` → `.session` adapter the panel uses.
Baseline before and after the change: $12.09, against the $12.07 the hook
itself last reported — unchanged in practice here, but no longer by luck.

## 10.1 Errors reach the screen

Every figure in this panel is a number, and a number that failed to compute is
indistinguishable from one that computed to zero. Nearly every call ends in
`2>/dev/null` — correctly, since a chatty stderr would shred a 1/3-width pane
— so a dead query, an unparseable payload, and a builder that died on an
unbound variable all rendered as `$0.00` and nothing else.

There is now one channel for that. A **file**, not a variable, because the
section builders run inside `$(...)` and a global set in there cannot be read
back out. `ccusage_cached` records any non-zero exit **or empty output** (an
empty payload parses to nothing while looking like a quiet day) and keeps
serving the last good answer rather than replacing it with the failure — but
the failure is on screen next to it. The three builders have their stderr
redirected into the same file, which is the general catch: it does not need to
know what broke to report that something did.

Rendered inside the guaranteed block, so a short pane cannot hide it; capped
at three lines with an "and N more" tail, so a burst cannot push the turn
table off screen; cleared once per slow tick, so it shows what is failing now
rather than everything that ever has.

Verified end to end by putting a `ccusage` on `PATH` that exits 3. The panel
renders:

```
  ! ccusage claude blocks failed (exit 3): boom: simulated
  ! ccusage claude daily failed (exit 3): boom: simulated c
  ! ccusage claude monthly failed (exit 3): boom: simulated
  ! and 2 more failure(s)
```

— and, because Phase 2 moved this session's own figures out of ccusage, it
still shows Session, Burn, Context Usage and the full per-turn table with the
tool completely dead.

## 11. Phase 3 — incremental rollup (deferred, not scheduled)

The honest answer to "surely not much data changes": in a 10-minute window,
**0.9MB across 1 file changed out of 653MB**. Per 120s tick that is ~0.03% —
ccusage re-reads roughly **3000x more data than has changed**, every time.

A rollup keyed on (file, byte offset) with running totals would make the slow
tier nearly free at any cadence, and the machinery half-exists: the panel
already owns a per-model `PRICES` table and a python corpus parser
(`refresh_hourly_buckets`).

It stays deferred because it means reimplementing ccusage's deduplication and
pricing semantics, and getting those subtly wrong produces **plausible wrong
money figures** — the failure class this codebase keeps paying for. If it is
ever done: keep ccusage as a periodic cross-check and fail loudly on
divergence, rather than replacing it outright.

Revisit only if the post-Phase-2 measurement (step 4) justifies it.
