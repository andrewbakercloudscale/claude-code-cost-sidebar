# Check M -- N concurrent Claude Code sessions must not cost N times.
#
# One panel is launched per session, so everything here multiplies by however
# many sessions are open. The shared cache directory plus the mkdir lock is
# what stops that, and this check holds it to it.
#
# It also pins down the one query that genuinely does NOT share: `statusline`
# is keyed on a payload carrying the session id and transcript path, so every
# session fetches its own -- at 2.11 CPU-s, the most expensive query the
# panel makes, multiplied by the session count. That is not a defect to fix
# here (the answer really is per-session); it is the measured reason Phase 2
# of SLOW-TIER-PLAN.md matters more the more sessions you run, and it is
# asserted so the cost stays visible rather than becoming folklore.
check_M_multi_session() {
  sandbox_new M
  cat > "$CCUSAGE_FIXTURE_DIR/sections.json" <<'JSON'
{"daily":[{"period":"2026-09-01","totalCost":1.5,"totalTokens":100}],"weekly":[],"monthly":[]}
JSON
  cat > "$CCUSAGE_FIXTURE_DIR/session.json" <<'JSON'
{"session":[{"period":"s1","totalCost":1.5,"totalTokens":100,"metadata":{"lastActivity":"2026-09-01T10:00:00.000Z"}}]}
JSON
  printf 'x' > "$CCUSAGE_FIXTURE_DIR/statusline.txt"

  # Three panels, three separate processes, one $HOME -- three sessions on
  # one machine.
  local i
  for i in 1 2 3; do
    ( load_panel 10 12 ""; recent_sections >/dev/null; all_sessions >/dev/null )
  done
  assert_eq "3 panels share ONE daily scan"   "1" "$(calls_for daily)"
  assert_eq "3 panels share ONE session scan" "1" "$(calls_for session)"

  # Same again after the entries lapse and the corpus moves: still one fetch
  # between them, because the jitter is key-derived and therefore identical
  # in every panel. Were it random or pid-derived they would stagger and
  # refetch one after another.
  local f
  touch "$HOME/.claude/projects/test-project/seed.jsonl"
  for f in "$HOME/.cache/ccusage-panel-cache"/*.json; do [ -e "$f" ] && age_file "$f" 600; done
  for i in 1 2 3; do
    ( load_panel 10 12 ""; recent_sections >/dev/null )
  done
  assert_eq "and share ONE refetch when it lapses" "2" "$(calls_for daily)"

  # Phase 2 removed the one query that could not be shared. An additional
  # session must now add ZERO ccusage invocations: everything a session
  # needs to know about ITSELF comes from parsing its own transcript, which
  # is local work proportional to what that session actually did rather
  # than a scan of the whole corpus.
  local tp before
  tp="$HOME/.claude/projects/test-project/sess.jsonl"
  printf '%s\n' '{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}}}' > "$tp"
  before=$(wc -l < "$CCUSAGE_CALL_LOG" | tr -d ' ')
  for i in 1 2 3; do
    ( load_panel 10 12 ""; latest="$tp"; session_stats_refresh )
  done
  assert_eq "3 more sessions add zero ccusage invocations" "$before" \
    "$(wc -l < "$CCUSAGE_CALL_LOG" | tr -d ' ')"
  assert_eq "and no statusline query exists to make" "0" "$(calls_for statusline)"
}
