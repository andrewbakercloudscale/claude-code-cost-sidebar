# Check A -- the two TTL buckets are real, and their boundary is where it says.
#
# Counting invocations rather than measuring CPU is deliberate: the count is
# exact and hermetic. A CPU-seconds gate would be flaky, and a flaky gate
# gets ignored, then disabled, then deleted.
check_A_ttl_bucketing() {
  sandbox_new A
  local TICKS=6
  cat > "$CCUSAGE_FIXTURE_DIR/daily.json" <<'JSON'
{"daily":[{"date":"2026-09-01","totalCost":1.5,"totalTokens":100}],"weekly":[],"monthly":[]}
JSON
  cat > "$CCUSAGE_FIXTURE_DIR/session.json" <<'JSON'
{"sessions":[{"sessionId":"sess-1","totalCost":1.5,"totalTokens":100,"lastActivity":"2026-09-01T10:00:00.000Z"}]}
JSON
  printf '{"blocks":[]}' > "$CCUSAGE_FIXTURE_DIR/blocks.json"
  printf '{}' > "$HOME/.cache/claude-hourly-buckets.json"
  load_panel 10 12 ""

  local i f
  # Age the caches to 600s: past the live bucket (90s), inside the history
  # bucket (900s, minus at most 14% jitter = 774s at worst). The corpus is
  # touched every tick, so the gate cannot be what holds anything back --
  # only the TTL can, which is what this is measuring.
  for (( i = 0; i < TICKS; i++ )); do
    touch "$HOME/.claude/projects/test-project/seed.jsonl"
    for f in "$HOME/.cache/ccusage-panel-cache"/*.json; do
      [ -e "$f" ] && age_file "$f" 600
    done
    recent_sections_fetch >/dev/null
    all_sessions >/dev/null
    ccusage_cached claude blocks --active --json --offline >/dev/null
  done

  # Live bucket: today's total rides in the daily payload, so it refetches
  # every tick. That is the cost of a Today figure that moves rather than
  # steps, and it is charged knowingly.
  assert_eq "daily is live: one scan per tick"  "$TICKS" "$(calls_for daily)"
  assert_eq "blocks is live: one scan per tick" "$TICKS" "$(calls_for blocks)"
  # History bucket: the day's session ranking, held across all six ticks.
  assert_eq "session is history: one scan for all $TICKS ticks" "1" "$(calls_for session)"

  # Past the history TTL as well (1000s > 900s even before jitter, which
  # only ever subtracts), session must refetch like anything else. Without
  # this the check above would also pass on a query that never refetches.
  local before; before=$(calls_for session)
  for (( i = 0; i < 3; i++ )); do
    touch "$HOME/.claude/projects/test-project/seed.jsonl"
    for f in "$HOME/.cache/ccusage-panel-cache"/*.json; do
      [ -e "$f" ] && age_file "$f" 1000
    done
    all_sessions >/dev/null
  done
  assert_eq "past its own TTL, session refetches too" "$(( before + 3 ))" "$(calls_for session)"

  # And with a static corpus, nothing costs anything -- the gate, not the
  # TTL, is still the arbiter for everything in the live bucket.
  local before_daily; before_daily=$(calls_for daily)
  age_corpus 1200
  for (( i = 0; i < TICKS; i++ )); do
    for f in "$HOME/.cache/ccusage-panel-cache"/*.json; do
      [ -e "$f" ] && age_file "$f" 600
    done
    recent_sections_fetch >/dev/null
  done
  assert_eq "an idle corpus costs zero scans over $TICKS ticks" "$before_daily" "$(calls_for daily)"
}
