# Check J -- this session's cost and context come from its own transcript.
#
# Phase 2's acceptance test. `ccusage statusline` supplied exactly two
# numbers the panel could not otherwise reach -- session cost and context
# tokens -- at 2.11 CPU-s a fetch, and its cache key carried the session id,
# so unlike every other query it could not be shared between panels: every
# additional Claude Code session paid it again in full.
#
# Both now fall out of the transcript parse the fast tier was already doing,
# so this asserts the arithmetic exactly (not within a tolerance -- the
# fixture's token counts and the published rates are both exact) and asserts
# that producing them costs no query at all.
check_J_session_stats_local() {
  sandbox_new J
  local tp="$HOME/.claude/projects/test-project/sess.jsonl"
  cat > "$tp" <<'JSON'
{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}}}
{"type":"assistant","timestamp":"2026-09-01T10:05:00.000Z","message":{"id":"m2","model":"claude-opus-5","usage":{"input_tokens":200,"output_tokens":100,"cache_read_input_tokens":2000,"cache_creation_input_tokens":400}}}
JSON
  load_panel 10 12 ""
  latest="$tp"

  local before; before=$(wc -l < "$CCUSAGE_CALL_LOG" | tr -d ' ')
  session_stats_refresh

  # Opus 5 at $5/$25 per 1M, cache read 0.1x input, 5-minute cache write
  # 1.25x input:
  #   m1 = (100*5 + 50*25 + 1000*5*0.1 + 200*5*1.25) / 1e6 = 0.003500
  #   m2 = (200*5 + 100*25 + 2000*5*0.1 + 400*5*1.25) / 1e6 = 0.007000
  assert_eq "session cost is the sum of its priced turns" "0.010500" "$SESS_COST"
  # Context is the NEWEST turn's window occupancy, not a running total:
  #   200 input + 2000 cache read + 400 cache write = 2600
  assert_eq "context is the newest turn's occupancy" "2600" "$SESS_CTX"
  # The window travels with the tokens it divides, from the newest turn's
  # own model, so the table's row colours and the Context Usage line cannot
  # be computed against different denominators.
  assert_eq "and its window comes from the same parse" "1000000" "$SESS_WIN"

  assert_eq "and neither cost a ccusage query" "$before" \
    "$(wc -l < "$CCUSAGE_CALL_LOG" | tr -d ' ')"
  assert_not_contains "the metadata line never reaches the screen" "#META" "$SESS_TABLE"
  assert_contains "the turn table still renders" "Turn" "$SESS_TABLE"

  # A cache entry written before the metadata line existed stays valid (it
  # is keyed on the transcript's mtime+size) and stays served. The figures
  # must come back EMPTY so the summary prints "--", rather than being
  # parsed out of a table row and rendered as money.
  local key cache
  key=$(printf '%s' "$tp $TURN_ROWS $C_BOLD$C_CYAN $C_RESET $C_CYAN $C_CYAN $C_GREEN $C_BLUE $C_RED $C_YELLOW $C_MAGENTA $CTX_YELLOW $CTX_RED $CTX_PURPLE $TIER_YELLOW_MULT $TIER_RED_MULT $MIN_DELTA_ALERT $C_DIM" | shasum -a 256 | cut -c1-16)
  cache="$CCUSAGE_CACHE_DIR_REAL/turns-$key.out"
  if [ -f "$cache" ]; then
    { head -1 "$cache"; tail -n +3 "$cache"; } > "$cache.legacy" && mv "$cache.legacy" "$cache"
    session_stats_refresh
    assert_eq "a pre-metadata cache entry yields no cost figure" "" "$SESS_COST"
    assert_ne "but the table is still rendered" "" "$SESS_TABLE"
  else
    assert_eq "the turn cache file was found at its expected key" "1" "0"
  fi
}
