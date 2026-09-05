# Check L -- a slow tick's corpus scans, budgeted.
#
# Stands in for a CPU regression test. Real CPU seconds are machine- and
# load-dependent, and a flaky gate gets ignored, then disabled, then deleted;
# an invocation count is exact. The budget below is what 30 ticks of an
# ACTIVE corpus costs today. If a change pushes it up, that is a decision
# somebody should be making on purpose.
check_L_invocation_budget() {
  sandbox_new L
  local TICKS=30
  # 30 live-bucket ticks (daily + blocks) and, at 600s of ageing per tick,
  # a single history fetch held across all of them.
  local BUDGET=$(( TICKS * 2 + 1 ))

  cat > "$CCUSAGE_FIXTURE_DIR/sections.json" <<'JSON'
{"daily":[{"period":"2026-09-01","totalCost":1.5,"totalTokens":100}],"weekly":[],"monthly":[]}
JSON
  cat > "$CCUSAGE_FIXTURE_DIR/session.json" <<'JSON'
{"session":[{"period":"s1","totalCost":1.5,"totalTokens":100,"metadata":{"lastActivity":"2026-09-01T10:00:00.000Z"}}]}
JSON
  printf '{"blocks":[]}' > "$CCUSAGE_FIXTURE_DIR/blocks.json"
  printf '{}' > "$HOME/.cache/claude-hourly-buckets.json"
  load_panel 10 12 ""

  local i f
  for (( i = 0; i < TICKS; i++ )); do
    touch "$HOME/.claude/projects/test-project/seed.jsonl"
    for f in "$HOME/.cache/ccusage-panel-cache"/*.json; do
      [ -e "$f" ] && age_file "$f" 600
    done
    recent_sections >/dev/null
    all_sessions >/dev/null
    ccusage_cached blocks --active --json --offline >/dev/null
  done

  local total; total=$(wc -l < "$CCUSAGE_CALL_LOG" | tr -d ' ')
  assert_eq "an active corpus stays within budget over $TICKS ticks" "1" \
    "$(( total <= BUDGET ? 1 : 0 ))"
  # State the number, so a budget that has quietly stopped binding is visible.
  assert_eq "and the count is exactly what it should be" "$BUDGET" "$total"
}
