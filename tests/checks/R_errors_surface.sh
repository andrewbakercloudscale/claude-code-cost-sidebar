# Check R -- a failure has to reach the screen.
#
# Every figure in this panel is a number, and a number that failed to compute
# is indistinguishable from one that computed to zero. Nearly every call ends
# in `2>/dev/null` -- correctly, since a chatty stderr would shred a
# 1/3-width pane -- so without somewhere for failures to go, a dead query, an
# unparseable payload and a builder that died on an unbound variable all
# render as $0.00 and nothing else.
check_R_errors_surface() {
  sandbox_new R
  load_panel 10 12 ""
  : > "$PANEL_ERR_FILE"

  # A query that works, then the same query failing.
  cat > "$CCUSAGE_FIXTURE_DIR/daily.json" <<'JSON'
{"daily":[{"date":"2026-09-01","totalCost":7.5,"totalTokens":100}]}
JSON
  local good; good=$(ccusage_cached claude daily --json --offline)
  assert_eq "the good fetch is served" "7.5" "$(jq -r '.daily[0].totalCost' <<<"$good")"
  assert_eq "and reports nothing" "0" "$(wc -l < "$PANEL_ERR_FILE" | tr -d ' ')"

  # Break it. The stub exits 70 with a message on stderr when its fixture is
  # missing -- the same shape as ccusage failing for real.
  rm -f "$CCUSAGE_FIXTURE_DIR/daily.json"
  local f
  for f in "$CCUSAGE_CACHE_DIR_REAL"/*.json; do [ -e "$f" ] && age_file "$f" 6000; done
  touch "$HOME/.claude/projects/test-project/seed.jsonl"
  local after; after=$(ccusage_cached claude daily --json --offline)

  assert_ne "the failure is recorded" "" "$(cat "$PANEL_ERR_FILE")"
  assert_contains "naming the query" "claude daily" "$(cat "$PANEL_ERR_FILE")"
  assert_contains "and its exit status" "exit 70" "$(cat "$PANEL_ERR_FILE")"
  # The last good answer keeps being served -- a stale number beats a blank
  # one, but only because the failure is on screen next to it.
  assert_eq "the last good payload is still served" "7.5" \
    "$(jq -r '.daily[0].totalCost' <<<"$after" 2>/dev/null)"

  # The other half: a builder that dies must not vanish silently. The panel
  # runs under `set -u`, so a missing global aborts the subshell -- which is
  # precisely how build_summary produced a one-line stump during this
  # suite's own development.
  : > "$PANEL_ERR_FILE"
  ( unset RECENT_JSON; build_summary 2>>"$PANEL_ERR_FILE" >/dev/null ) || true
  assert_ne "a builder's crash is captured too" "" "$(cat "$PANEL_ERR_FILE")"

  # And it is rendered in the block that is never truncated, so a short pane
  # cannot hide it.
  assert_eq "errors render inside the guaranteed block" "1" \
    "$(grep -c 'guaranteed="\$summary_block"\${errs:+' "$PANEL_SH")"
  assert_eq "cleared once per slow tick, not accumulated" "1" \
    "$(grep -c ': > "\$PANEL_ERR_FILE"$' "$PANEL_SH")"
}
