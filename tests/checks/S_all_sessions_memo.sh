# Check S -- build_summary fetches the session report once per frame.
#
# Three of its sections are three views of one report (the 7-day baseline,
# the previous 7 days it is compared against, and this project's share), and
# each used to ask for it separately. Counting ccusage INVOCATIONS cannot
# see that: inside the TTL every one of those was already a cache hit, so
# the redundant calls never reached the stub. What they reached was a
# re-read and a re-parse of a 150KB payload, and -- on a tick where the TTL
# had lapsed -- a corpus_changed_since walk each. So the counter goes on
# all_sessions() itself, which is exactly the boundary being deduplicated.
#
# Two traps on the way here, both of which produced a green check measuring
# less than it claimed:
#
#   * The counter is a FILE. Every call site is `$(all_sessions)`, its own
#     subshell, so a counter variable incremented in there cannot be read
#     back out -- it reported one call no matter what the panel did. This is
#     the same subshell trap the panel's own PANEL_ERR_FILE comment
#     describes, and it is why the fix under test is a call-site refactor
#     rather than a memo inside all_sessions(): a memo variable would have
#     been just as invisible, and would have saved nothing at all.
#   * cols/rows/COLS are set by the render loop, not by resolve_session, so
#     build_summary called without them dies on an unbound variable at the
#     Context Usage line -- BEFORE the third call site, having emitted a
#     plausible-looking eight-line frame. The count was then over two of
#     three sections while reading as all of them. Hence the Folder
#     assertion below: it is the section the third call feeds, so it is the
#     only thing that proves the third call was reached.
check_S_all_sessions_memo() {
  sandbox_new S
  local today; today=$(date +%Y-%m-%d)
  cat > "$CCUSAGE_FIXTURE_DIR/session.json" <<JSON
{"sessions":[{"sessionId":"s1","totalCost":6.00,"totalTokens":600,"lastActivity":"${today}T10:00:00.000Z"},
             {"sessionId":"s2","totalCost":4.00,"totalTokens":400,"lastActivity":"${today}T11:00:00.000Z"}]}
JSON
  cat > "$CCUSAGE_FIXTURE_DIR/daily.json" <<JSON
{"daily":[{"date":"$today","totalCost":10.00,"totalTokens":1000}],"weekly":[],"monthly":[]}
JSON
  printf '{"blocks":[]}' > "$CCUSAGE_FIXTURE_DIR/blocks.json"
  printf '{}' > "$HOME/.cache/claude-hourly-buckets.json"
  load_panel 10 12 ""
  # What the render loop sets before it calls either builder. Without these
  # the function under test stops a third of the way through.
  cols=100; rows=40; export COLS=100
  seed_recent
  panel_tick_slow

  local COUNT="$SBX/all-sessions-calls"
  : > "$COUNT"
  eval "orig_all_sessions() $(declare -f all_sessions | tail -n +2)"
  all_sessions() { printf 'x\n' >> "$COUNT"; orig_all_sessions "$@"; }

  local frame; frame=$(build_summary 2>/dev/null)
  assert_eq "build_summary asks for the session report once" "1" \
    "$(wc -l < "$COUNT" | tr -d ' ')"

  # Positive controls: one line per section the shared payload feeds, so a
  # frame that died early cannot satisfy the count above.
  assert_contains "the frame is a frame" "Claude Code Usage" "$frame"
  assert_contains "the 7-day baseline section rendered" "30-Day Value" "$frame"
  assert_contains "and so did the project section, the LAST of the three" \
    "Folder:" "$frame"

  # The payload the three sections share must be the real one -- a refactor
  # that hoisted the fetch but dropped its result would also pass the count.
  assert_eq "the shared payload carries both sessions" "10.00" \
    "$(num "$(orig_all_sessions | jq -r '[.session[].totalCost] | add')")"

  # Once per FRAME, not once per process: the next slow tick must fetch
  # again, or the baselines freeze for the life of the pane.
  : > "$COUNT"
  build_summary >/dev/null 2>&1
  assert_eq "the next frame asks again" "1" "$(wc -l < "$COUNT" | tr -d ' ')"
}
