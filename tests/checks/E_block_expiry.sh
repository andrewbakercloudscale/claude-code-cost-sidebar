# Check E -- an ended 5h block must stop being rendered as active.
#
# This guards a bug that was live when the check was written. `blocks
# --active` is cached and gated on the corpus; when a block ends and no new
# turn lands, the corpus has NOT changed, so the gate correctly holds the
# entry, nothing refetches, and the panel renders a countdown pinned at
# "0m left" for as long as the pane stays open.
#
# It is the same clock-vs-corpus confusion as check D: the answer depends on
# the wall clock, and corpus_changed_since() cannot see the wall clock. The
# fix retires the block locally, from the end epoch the panel already holds.
check_E_block_expiry() {
  sandbox_new E
  local start_e end_e
  start_e=$(( $(local_midnight "2026-09-01") + 36000 ))   # 10:00 local
  end_e=$(( start_e + 18000 ))                            # +5h
  cat > "$CCUSAGE_FIXTURE_DIR/blocks.json" <<JSON
{"blocks":[{"startTime":"$(date -u -r $start_e +%Y-%m-%dT%H:%M:%S).000Z",
            "endTime":"$(date -u -r $end_e +%Y-%m-%dT%H:%M:%S).000Z",
            "costUSD":4.50,"totalTokens":50000,
            "burnRate":{"tokensPerMinute":120},
            "projection":{"totalCost":9.0,"totalTokens":100000},
            "models":["claude-opus-5"]}]}
JSON
  # build_summary reads all three reports. Without these the stub exits 70,
  # the summary comes back a stump, and the "no Current Block line"
  # assertion below passes for a reason that has nothing to do with the bug
  # -- which is how a check ends up guarding nothing while reporting ok.
  cat > "$CCUSAGE_FIXTURE_DIR/daily.json" <<'JSON'
{"daily":[{"date":"2026-09-01","totalCost":6.0,"totalTokens":500}],"weekly":[],"monthly":[]}
JSON
  cat > "$CCUSAGE_FIXTURE_DIR/session.json" <<'JSON'
{"sessions":[{"sessionId":"sess-1","totalCost":6.0,"totalTokens":500,"lastActivity":"2026-09-01T10:00:00.000Z"}]}
JSON
  # The hourly-bucket rebuild is a slow-tier concern of its own and is not
  # what this check is about; a fresh cache file keeps it out of the way.
  mkdir -p "$HOME/.cache"; printf '{}' > "$HOME/.cache/claude-hourly-buckets.json"
  load_panel 10 12 ""

  # Inside the block: rendered, with time left.
  export PANEL_FAKE_NOW=$(( end_e - 600 ))
  panel_tick_slow
  assert_eq "block is active 10 minutes before it ends" "1" "${has_block:-0}"
  assert_eq "and shows 10 minutes left" "10" "${blk_rem:-}"
  # Positive control. Without it, the negative assertion at the end proves
  # only that build_summary produced no Current Block line -- which an empty
  # summary satisfies just as well as a correct one.
  local live_summary; live_summary=$(build_summary 2>/dev/null)
  assert_contains "an active block IS rendered while it runs" "Current Block" "$live_summary"

  # Past the end, corpus untouched. The cache legitimately still holds the
  # old payload -- that is the gate working, not failing.
  local calls_before; calls_before=$(calls_for blocks)
  export PANEL_FAKE_NOW=$(( end_e + 60 ))
  panel_tick_slow
  assert_eq "no refetch happened (the gate correctly held)" "$calls_before" "$(calls_for blocks)"
  assert_eq "but the ended block is no longer active" "0" "${has_block:-0}"

  # And it must not render. This is what a user would actually have seen.
  local summary; summary=$(build_summary 2>/dev/null)
  assert_not_contains "no Current Block line for an ended block" "Current Block" "$summary"

  unset PANEL_FAKE_NOW
}
