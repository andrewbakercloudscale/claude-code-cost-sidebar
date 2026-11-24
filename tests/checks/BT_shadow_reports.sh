# Check BT -- the shadow corpus's reports, and every way back to the full
# corpus.
#
# The helpers (bs_line, bs_add, bs_sync, bs_row, ...) are check BS's.
# Covered: the block proof (a gap of more than 5h after S, exactly 5h,
# none), the merge of the full run's older rows with the shadow's rows from
# the first exact day, weekly (Sunday start) and monthly sums with their
# model breakdowns, the panel's shared cache files, the report cache (no
# run when nothing moved, the shadow only for a new turn, the history on a
# new day), the merged report equal to the full one when the fixtures
# agree, and the fallbacks: PANEL_SHADOW=0, no collector, a failed shadow
# run, another process holding the shadow, and a block it cannot prove.
# The panel's globals (blk_cost, PANEL_FAKE_NOW, PANEL_SHADOW, ...) are set
# and read by the sourced panel, which shellcheck cannot follow.
# shellcheck disable=SC2034,SC2154
check_BT_shadow_reports() {
  sandbox_new BSR
  load_panel 10 12 ""
  local d18 d19 out p h i
  d18=$(local_midnight 2026-11-18)
  d19=$(local_midnight 2026-11-19)
  BS_S=$d18
  BS_NOW=$(( d19 + 15 * 3600 ))
  p="$HOME/.claude/projects/-bsr"
  mkdir -p "$p"

  # ---- the block proof ----
  # Activity every hour from before S to now: no gap of more than 5h after
  # S, so the active block's start cannot be proved from the shadow.
  for (( h = BS_S - 7200; h < BS_NOW; h += 3600 )); do
    bs_add "$p/busy.jsonl" "b$h" "$h" 1
  done
  out=$(bs_sync)
  assert_contains "continuous activity: the block is not provable" "ok 0 " "$out"
  # A gap of exactly 5h is not enough: ccusage starts a block only after
  # MORE than 5h.
  rm -rf "$p" "$SHADOW_DIR"; mkdir -p "$p"
  bs_add "$p/g.jsonl" g1 $(( BS_S + 3600 )) 1
  for (( h = BS_S + 6 * 3600; h < BS_NOW; h += 3600 )); do bs_add "$p/g.jsonl" "g$h" "$h" 1; done
  out=$(bs_sync)
  assert_contains "a gap of exactly 5h: not provable" "ok 0 " "$out"
  # Six hours: provable.
  rm -rf "$p" "$SHADOW_DIR"; mkdir -p "$p"
  bs_add "$p/g.jsonl" g1 $(( BS_S + 3600 )) 1
  for (( h = BS_S + 7 * 3600; h < BS_NOW; h += 3600 )); do bs_add "$p/g.jsonl" "g$h" "$h" 1; done
  out=$(bs_sync)
  assert_contains "a gap of 6h after S: provable" "ok 1 " "$out"
  # Nothing in the first 5h after S counts as a gap too.
  rm -rf "$p" "$SHADOW_DIR"; mkdir -p "$p"
  bs_add "$p/g.jsonl" g0 $(( BS_S - 600 )) 1
  for (( h = BS_S + 5 * 3600 + 120; h < BS_NOW; h += 3600 )); do bs_add "$p/g.jsonl" "g$h" "$h" 1; done
  out=$(bs_sync)
  assert_contains "the first 5h after S quiet: provable" "ok 1 " "$out"

  # ---- the merge, weekly and monthly ----
  rm -rf "$SHADOW_DIR"
  # History (the full run): its rows from the first exact day on are stale.
  # Shadow: its rows before the first exact day hold only part of the day.
  {
    printf '{"daily":['
    bs_row 2026-10-31 1 claude-opus-5-5; printf ','
    bs_row 2026-11-01 2 claude-opus-5-5; printf ','
    bs_row 2026-11-07 4 claude-sonnet-5; printf ','
    bs_row 2026-11-08 8 claude-opus-5-5; printf ','
    bs_row 2026-11-17 16 claude-sonnet-5; printf ','
    bs_row 2026-11-18 999 claude-opus-5-5
    printf ']}\n'
  } > "$CCUSAGE_FIXTURE_DIR/daily.json"
  {
    printf '{"daily":['
    bs_row 2026-11-17 777 claude-opus-5-5; printf ','
    bs_row 2026-11-18 32 claude-opus-5-5; printf ','
    bs_row 2026-11-19 64.5 claude-opus-5-5
    printf ']}\n'
  } > "$CCUSAGE_FIXTURE_DIR/shadow-daily.json"
  printf '{"blocks":[{"startTime":"%s","endTime":"%s","costUSD":3.5,"totalTokens":9,"burnRate":{"tokensPerMinute":1},"projection":{"totalCost":4,"totalTokens":10},"models":["claude-opus-5-5"]}]}\n' \
    "$(bs_iso $(( BS_NOW - 3600 )))" "$(bs_iso $(( BS_NOW + 4 * 3600 )))" > "$CCUSAGE_FIXTURE_DIR/shadow-blocks.json"
  : > "$CCUSAGE_CALL_LOG"
  PANEL_FAKE_NOW=$BS_NOW
  COLLECTOR_COMPUTE=1 shadow_refresh
  assert_eq "the shadow answered" "1 1" "$SHADOW_READY $SHADOW_BLOCKS"
  local od ow om
  od="$SHADOW_DIR/out-daily.json" ow="$SHADOW_DIR/out-weekly.json" om="$SHADOW_DIR/out-monthly.json"
  assert_eq "merged days: history before the 18th, shadow from it" \
    "2026-10-31=1 2026-11-01=2 2026-11-07=4 2026-11-08=8 2026-11-17=16 2026-11-18=32 2026-11-19=64.5" \
    "$(jq -r '[.daily[] | "\(.date)=\(.totalCost)"] | join(" ")' "$od")"
  assert_eq "merged totals" "127.5 1275" "$(jq -r '"\(.totals.totalCost) \(.totals.totalTokens)"' "$od")"
  assert_eq "weeks start on Sunday" \
    "2026-10-25=1 2026-11-01=6 2026-11-08=8 2026-11-15=112.5" \
    "$(jq -r '[.weekly[] | "\(.week)=\(.totalCost)"] | join(" ")' "$ow")"
  assert_eq "a week's models, biggest first, summed" \
    "claude-opus-5-5=96.5 claude-sonnet-5=16" \
    "$(jq -r '[.weekly[-1].modelBreakdowns[] | "\(.modelName)=\(.cost)"] | join(" ")' "$ow")"
  assert_eq "a week's tokens are its days'" "1125 225 787.5" \
    "$(jq -r '.weekly[-1] | "\(.totalTokens) \(.inputTokens) \(.cacheReadTokens)"' "$ow")"
  assert_eq "a week's models used" "claude-sonnet-5 claude-opus-5-5" \
    "$(jq -r '.weekly[-1].modelsUsed | join(" ")' "$ow")"
  assert_eq "months" "2026-10=1 2026-11=126.5" \
    "$(jq -r '[.monthly[] | "\(.month)=\(.totalCost)"] | join(" ")' "$om")"
  assert_eq "weekly and monthly totals are the daily totals" "127.5 127.5" \
    "$(jq -r '.totals.totalCost' "$ow") $(jq -r '.totals.totalCost' "$om")"
  # The runs: one full daily (history), one shadow daily, one shadow block.
  assert_eq "one full-corpus daily, for the history" "1" "$(calls_for daily)"
  assert_eq "no weekly or monthly run at all" "0 0" "$(calls_for weekly) $(calls_for monthly)"
  assert_eq "two shadow runs" "2" "$(grep -c '^shadow ' "$CCUSAGE_CALL_LOG")"
  assert_contains "pointed at the shadow" "shadow $SHADOW_DIR/root claude daily" "$(cat "$CCUSAGE_CALL_LOG")"
  # The panel's shared cache files carry them, for the status line.
  local kd kb
  panel_hash16_v kd "claude daily --json --offline"
  panel_hash16_v kb "claude blocks --active --json --offline"
  assert_eq "the shared daily is the merged one" "$(jq -cS . "$od")" "$(jq -cS . "$CCUSAGE_CACHE_DIR/$kd.json")"
  assert_eq "the shared block is the shadow's" "3.5" "$(jq -r '.blocks[0].costUSD' "$CCUSAGE_CACHE_DIR/$kb.json")"

  # What the panel reads: the shadow's, and no full run for any of it.
  : > "$CCUSAGE_CALL_LOG"
  recent_sections_fetch_v RECENT_JSON
  refresh_active_block
  assert_eq "the panel's daily rows are the merged ones" "127.5" "$(jq -r '[.daily[].totalCost] | add' <<<"$RECENT_JSON")"
  assert_eq "its week" "112.5" "$(jq -r '[.weekly[] | select(.period == "2026-11-15") | .totalCost][0]' <<<"$RECENT_JSON")"
  assert_eq "its month" "126.5" "$(jq -r '[.monthly[] | select(.period == "2026-11") | .totalCost][0]' <<<"$RECENT_JSON")"
  assert_eq "its block" "3.500000" "$blk_cost"
  assert_eq "and no ccusage run for any of it" "" "$(cat "$CCUSAGE_CALL_LOG")"

  # Nothing new: the reports are not run again.
  COLLECTOR_COMPUTE=1 shadow_refresh
  assert_eq "nothing new: no run" "" "$(cat "$CCUSAGE_CALL_LOG")"
  assert_contains "and it says so" "cached" "$(cat "$SHADOW_DIR/status")"
  # Nothing the reports read moved, so the shared answers are as good as of
  # now: their age is reset, and a status line does not rerun the corpus.
  touch -t "$(date -v-1H +%Y%m%d%H%M.%S)" "$CCUSAGE_CACHE_DIR/$kd.json"
  COLLECTOR_COMPUTE=1 shadow_refresh
  local km_age
  km_age=$(( $(date +%s) - $(stat -f %m "$CCUSAGE_CACHE_DIR/$kd.json") ))
  if (( km_age < 60 )); then _pass; else _fail "a cached run renews the shared daily's age" "under 60s" "${km_age}s"; fi
  # A turn lands: the shadow reports again, the history does not.
  bs_add "$p/g.jsonl" late $(( BS_NOW - 30 )) 1
  COLLECTOR_COMPUTE=1 shadow_refresh
  assert_eq "a turn: two shadow runs" "2" "$(grep -c '^shadow ' "$CCUSAGE_CALL_LOG")"
  assert_eq "and no full one" "0" "$(calls_for daily)"
  # The next local day: the history is fetched again.
  : > "$CCUSAGE_CALL_LOG"
  PANEL_FAKE_NOW=$(( BS_NOW + 86400 ))
  COLLECTOR_COMPUTE=1 shadow_refresh
  assert_eq "a new day: the history again" "1" "$(calls_for daily)"
  PANEL_FAKE_NOW=$BS_NOW
  rm -rf "$SHADOW_DIR"

  # ---- the same answer as the full corpus ----
  # When the fixtures agree (daily.json is the truth, the shadow has the
  # truth from the 17th on, wrong on the 17th itself, which the merge must
  # drop), the panel's merged report is the full one's.
  {
    printf '{"daily":['
    bs_row 2026-10-31 1.25 claude-opus-5-5; printf ','
    bs_row 2026-11-15 2 claude-sonnet-5; printf ','
    bs_row 2026-11-17 16 claude-sonnet-5; printf ','
    bs_row 2026-11-18 32 claude-opus-5-5; printf ','
    bs_row 2026-11-19 64 claude-opus-5-5
    printf ']}\n'
  } > "$CCUSAGE_FIXTURE_DIR/daily.json"
  jq -c '.daily |= map(if .date == "2026-11-17" then .totalCost = 1 else . end | select(.date >= "2026-11-17"))' \
    "$CCUSAGE_FIXTURE_DIR/daily.json" > "$CCUSAGE_FIXTURE_DIR/shadow-daily.json"
  printf '{"weekly":[%s,%s]}\n' \
    "$(bs_row 2026-10-25 1.25 claude-opus-5-5 | jq -c 'del(.date) | .week = "2026-10-25"')" \
    "$(jq -cn '{week: "2026-11-15", inputTokens: 228, outputTokens: 114, cacheCreationTokens: 0, cacheReadTokens: 798, totalTokens: 1140, totalCost: 114}')" \
    > "$CCUSAGE_FIXTURE_DIR/weekly.json"
  printf '{"monthly":[{"month":"2026-10","totalCost":1.25},{"month":"2026-11","totalCost":114}]}\n' > "$CCUSAGE_FIXTURE_DIR/monthly.json"
  local full shadow
  rm -f "$CCUSAGE_CACHE_DIR"/*.json
  full=$(PANEL_SHADOW=0; COLLECTOR_COMPUTE=1 shadow_refresh; recent_sections_fetch_v r; printf '%s' "$r")
  rm -f "$CCUSAGE_CACHE_DIR"/*.json
  shadow=$(COLLECTOR_COMPUTE=1 shadow_refresh; recent_sections_fetch_v r; printf '%s' "$r")
  assert_eq "daily rows: shadow and merge equal the full run" \
    "$(jq -cS '[.daily[] | del(.modelsUsed)]' <<<"$full")" "$(jq -cS '[.daily[] | del(.modelsUsed)]' <<<"$shadow")"
  assert_eq "weekly: the figures the panel reads" \
    "$(jq -c '[.weekly[] | [.period, .totalCost, .totalTokens, .inputTokens, .cacheReadTokens]]' <<<"$full")" \
    "$(jq -c '[.weekly[] | [.period, .totalCost, .totalTokens, .inputTokens, .cacheReadTokens]]' <<<"$shadow")"
  assert_eq "monthly: the same" \
    "$(jq -c '[.monthly[] | [.period, .totalCost]]' <<<"$full")" \
    "$(jq -c '[.monthly[] | [.period, .totalCost]]' <<<"$shadow")"

  # ---- every way back to the full corpus ----
  : > "$CCUSAGE_CALL_LOG"
  ( PANEL_SHADOW=0; COLLECTOR_COMPUTE=1 shadow_refresh; printf '%s' "$SHADOW_READY" > "$SBX/r" )
  assert_eq "PANEL_SHADOW=0: off" "0" "$(cat "$SBX/r")"
  assert_eq "PANEL_SHADOW=0: no shadow run" "0" "$(grep -c '^shadow ' "$CCUSAGE_CALL_LOG")"
  rm -rf "$SHADOW_DIR"
  shadow_refresh
  assert_eq "a panel with no collector does not touch the shadow" "0 absent" \
    "$SHADOW_READY $([ -e "$SHADOW_DIR" ] && echo present || echo absent)"
  ( export CCUSAGE_SHADOW_FAIL=1; COLLECTOR_COMPUTE=1 shadow_refresh; printf '%s' "$SHADOW_READY" > "$SBX/r" )
  assert_eq "a failed shadow run: full corpus" "0" "$(cat "$SBX/r")"
  assert_contains "and the status says why" "fallback" "$(cat "$SHADOW_DIR/status")"
  : > "$CCUSAGE_CALL_LOG"
  rm -f "$CCUSAGE_CACHE_DIR"/*.json
  SHADOW_READY=0 SHADOW_BLOCKS=0
  recent_sections_fetch_v RECENT_JSON
  refresh_active_block
  assert_eq "then the panel runs the full reports" "1 1 1 1" \
    "$(calls_for daily) $(calls_for weekly) $(calls_for monthly) $(calls_for blocks)"
  # Another process holding the shadow.
  python3 -c 'import fcntl,sys,time; f=open(sys.argv[1],"w"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(20)' \
    "$SHADOW_DIR/lock" "$SBX/held" &
  local holder=$!
  for (( i = 0; i < 100; i++ )); do [ -e "$SBX/held" ] && break; sleep 0.1; done
  COLLECTOR_COMPUTE=1 shadow_refresh
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  assert_eq "a shadow held by another process: full corpus" "0" "$SHADOW_READY"
  assert_contains "busy" "fallback busy" "$(cat "$SHADOW_DIR/status")"
  # A block that is not provable is the full corpus's.
  rm -rf "$p" "$SHADOW_DIR"; mkdir -p "$p"
  for (( h = BS_S - 7200; h < BS_NOW; h += 3600 )); do bs_add "$p/busy.jsonl" "b$h" "$h" 1; done
  : > "$CCUSAGE_CALL_LOG"
  rm -f "$CCUSAGE_CACHE_DIR"/*.json
  COLLECTOR_COMPUTE=1 shadow_refresh
  assert_eq "no provable block: reports yes, block no" "1 0" "$SHADOW_READY $SHADOW_BLOCKS"
  refresh_active_block
  assert_eq "and the block is the full corpus's run" "1" "$(calls_for blocks)"
  assert_eq "while the shadow ran daily only" "1" "$(grep -c '^shadow ' "$CCUSAGE_CALL_LOG")"
  unset PANEL_FAKE_NOW
}
