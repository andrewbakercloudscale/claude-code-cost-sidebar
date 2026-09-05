# Check C -- the panel may not contradict itself across a bucket boundary.
#
# Top Sessions Today comes from the history bucket; Today's total comes from
# the live one. So the two are computed from snapshots up to a quarter of an
# hour apart, and the ONLY reason that is safe is the direction of the skew:
# the sessions side is the stale one, so the ranking lags the day total and
# can never sum to more than it.
#
# Reverse the assignment -- daily stale, session fresh -- and the panel would
# display a set of sessions adding up to more than the day they belong to.
# That is the shape of the bug this check exists to prevent, so it asserts
# the direction, not merely the numbers.
check_C_bucket_coherence() {
  sandbox_new C
  local today; today="2026-09-01"
  cat > "$CCUSAGE_FIXTURE_DIR/daily.json" <<JSON
{"daily":[{"date":"$today","totalCost":10.00,"totalTokens":1000}],"weekly":[],"monthly":[]}
JSON
  cat > "$CCUSAGE_FIXTURE_DIR/session.json" <<JSON
{"sessions":[{"sessionId":"s1","totalCost":6.00,"totalTokens":600,"lastActivity":"${today}T10:00:00.000Z"},
            {"sessionId":"s2","totalCost":4.00,"totalTokens":400,"lastActivity":"${today}T11:00:00.000Z"}]}
JSON
  printf '{"blocks":[]}' > "$CCUSAGE_FIXTURE_DIR/blocks.json"
  printf '{}' > "$HOME/.cache/claude-hourly-buckets.json"
  load_panel 10 12 ""
  export PANEL_FAKE_NOW=$(( $(local_midnight "$today") + 43200 ))

  local day_total sess_total
  day_total=$(today_daily_shape "$(recent_sections_fetch)" | jq -r '.totals.totalCost')
  sess_total=$(sessions_window "$(all_sessions)" "$today" "" | jq -r '[.session[].totalCost] | add')
  assert_eq "baseline: the two agree before anything moves" "10.00" "$(num "$day_total")"
  assert_eq "and the sessions sum to the same" "10.00" "$(num "$sess_total")"

  # A turn lands. daily is live and picks it up; session is held by its
  # bucket. Cost the day $5 more without touching the session report.
  cat > "$CCUSAGE_FIXTURE_DIR/daily.json" <<JSON
{"daily":[{"date":"$today","totalCost":15.00,"totalTokens":1500}],"weekly":[],"monthly":[]}
JSON
  touch "$HOME/.claude/projects/test-project/seed.jsonl"
  local f
  for f in "$HOME/.cache/ccusage-panel-cache"/*.json; do [ -e "$f" ] && age_file "$f" 600; done

  day_total=$(today_daily_shape "$(recent_sections_fetch)" | jq -r '.totals.totalCost')
  sess_total=$(sessions_window "$(all_sessions)" "$today" "" | jq -r '[.session[].totalCost] | add')
  assert_eq "Today moved with the live bucket" "15.00" "$(num "$day_total")"
  assert_eq "the session ranking stayed on its own snapshot" "10.00" "$(num "$sess_total")"
  assert_eq "sessions never sum to more than the day they are in" "1" \
    "$(awk -v s="$sess_total" -v d="$day_total" 'BEGIN{print (s<=d)?1:0}')"

  unset PANEL_FAKE_NOW
}
