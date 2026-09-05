# Check A -- how many corpus scans a slow tick actually costs.
#
# This encodes the CURRENT contract: one shared TTL, so every ccusage-backed
# query is refetched once per slow tick while the corpus is changing. Phase 1
# of SLOW-TIER-PLAN.md splits that into a live bucket and a history bucket;
# when it lands, the EXPECT_* constants below change and this check becomes
# the thing that proves the buckets are real rather than aspirational.
#
# Counting invocations rather than measuring CPU is deliberate: the count is
# exact and hermetic. A CPU-seconds gate would be flaky, and a flaky gate
# gets ignored, then disabled, then deleted.
check_A_ttl_bucketing() {
  sandbox_new A
  local TICKS=6
  # Current behaviour: every query shares CCUSAGE_CACHE_TTL, so a corpus that
  # changes every tick means one fetch per query per tick.
  local EXPECT_DAILY=$TICKS EXPECT_SESSION=$TICKS EXPECT_BLOCKS=$TICKS

  cat > "$CCUSAGE_FIXTURE_DIR/sections.json" <<'JSON'
{"daily":[{"period":"2026-09-01","totalCost":1.5,"totalTokens":100}],"weekly":[],"monthly":[]}
JSON
  cat > "$CCUSAGE_FIXTURE_DIR/session.json" <<'JSON'
{"session":[{"period":"sess-1","totalCost":1.5,"totalTokens":100,"metadata":{"lastActivity":"2026-09-01T10:00:00.000Z"}}]}
JSON
  cat > "$CCUSAGE_FIXTURE_DIR/blocks.json" <<'JSON'
{"blocks":[]}
JSON
  printf '{}' > "$HOME/.cache/claude-hourly-buckets.json"
  load_panel 10 12 ""

  local i
  for (( i = 0; i < TICKS; i++ )); do
    # A turn lands, then a slow tick fetches. Both caches must be past their
    # TTL for the tick to consult the gate at all -- age them rather than
    # sleep for them.
    touch "$HOME/.claude/projects/test-project/seed.jsonl"
    local f
    for f in "$HOME/.cache/ccusage-panel-cache"/*.json; do
      [ -e "$f" ] && age_file "$f" 600
    done
    recent_sections >/dev/null
    all_sessions >/dev/null
    ccusage_cached blocks --active --json --offline >/dev/null
  done

  assert_eq "daily+weekly+monthly scans over $TICKS ticks"  "$EXPECT_DAILY"   "$(calls_for daily)"
  assert_eq "session scans over $TICKS ticks"               "$EXPECT_SESSION" "$(calls_for session)"
  assert_eq "blocks scans over $TICKS ticks"                "$EXPECT_BLOCKS"  "$(calls_for blocks)"

  # The other half of the contract: with a static corpus the same $TICKS
  # ticks must cost nothing at all. If this regresses, an idle pane is paying
  # a full corpus scan per tick again.
  local before_daily; before_daily=$(calls_for daily)
  age_corpus 1200
  for (( i = 0; i < TICKS; i++ )); do
    # Caches lapse, but stay NEWER than the last transcript write -- which is
    # exactly the idle pane this gate exists for.
    for f in "$HOME/.cache/ccusage-panel-cache"/*.json; do
      [ -e "$f" ] && age_file "$f" 600
    done
    recent_sections >/dev/null
  done
  assert_eq "an idle corpus costs zero scans over $TICKS ticks" "$before_daily" "$(calls_for daily)"
}
