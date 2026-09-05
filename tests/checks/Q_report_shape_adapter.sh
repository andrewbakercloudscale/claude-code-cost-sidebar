# Check Q -- the scoped reports' key names are normalised, once, on the way in.
#
# This check exists because its absence cost a working panel. `ccusage claude
# <sub>` does not use the unified `--sections` report's key names: the period
# a row covers is `date`, `week` and `month` rather than `period`, and the
# session report nests under `.sessions` with `sessionId` and a top-level
# `lastActivity`.
#
# Nothing errors on any of that. `select(.period == $t)` matches no row and
# Today, Folder and 30-Day Value each render a confident $0.00 -- which is
# what the panel did, while the whole suite reported green, because every
# fixture here had been written in the OLD shape. A fixture that does not
# match what the real tool emits is not a test; it is a second copy of the
# bug. These are the real shapes, verified against live output.
check_Q_report_shape_adapter() {
  sandbox_new Q
  cat > "$CCUSAGE_FIXTURE_DIR/daily.json" <<'JSON'
{"daily":[{"date":"2026-09-01","totalCost":3.5,"totalTokens":100}],"totals":{"totalCost":3.5}}
JSON
  cat > "$CCUSAGE_FIXTURE_DIR/weekly.json" <<'JSON'
{"weekly":[{"week":"2026-08-31","totalCost":9.5,"totalTokens":300}],"totals":{"totalCost":9.5}}
JSON
  cat > "$CCUSAGE_FIXTURE_DIR/monthly.json" <<'JSON'
{"monthly":[{"month":"2026-09","totalCost":21.0,"totalTokens":900}],"totals":{"totalCost":21.0}}
JSON
  cat > "$CCUSAGE_FIXTURE_DIR/session.json" <<'JSON'
{"sessions":[{"sessionId":"sess-abc","totalCost":3.5,"totalTokens":100,"lastActivity":"2026-09-01T10:00:00.000Z"}],"totals":{"totalCost":3.5}}
JSON
  load_panel 10 12 ""
  seed_recent

  local r; r=$(recent_sections)
  assert_eq "daily rows carry .period"   "2026-09-01" "$(jq -r '.daily[0].period' <<<"$r")"
  assert_eq "weekly rows carry .period"  "2026-08-31" "$(jq -r '.weekly[0].period' <<<"$r")"
  assert_eq "monthly rows carry .period" "2026-09"    "$(jq -r '.monthly[0].period' <<<"$r")"
  assert_eq "and the values survive the rename" "3.5" "$(jq -r '.daily[0].totalCost' <<<"$r")"

  # The failure this reproduces: today's slice against the live clock.
  export PANEL_FAKE_NOW=$(( $(local_midnight "2026-09-01") + 43200 ))
  assert_eq "Today resolves rather than reading 0.00" "3.5" \
    "$(today_daily_shape "$r" | jq -r '.totals.totalCost')"
  unset PANEL_FAKE_NOW

  local sj; sj=$(all_sessions)
  assert_eq "sessions are nested under .session" "1" "$(jq -r '.session | length' <<<"$sj")"
  assert_eq "the id is exposed as .period" "sess-abc" "$(jq -r '.session[0].period' <<<"$sj")"
  assert_eq "lastActivity moves under .metadata" "2026-09-01T10:00:00.000Z" \
    "$(jq -r '.session[0].metadata.lastActivity' <<<"$sj")"

  # sessions_window filters on that metadata date; a missing rename would
  # silently drop every session out of every window.
  assert_eq "and a day window still selects the session" "1" \
    "$(sessions_window "$sj" "2026-09-01" "" | jq -r '.session | length')"
}
