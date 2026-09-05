# Check D -- the clock-slice invariant. The highest-value check in the suite.
#
# ccusage_query_is_gated() asserts that every query is a pure function of the
# transcript corpus. That is true of the PAYLOADS. It is not true of what the
# panel displays: today_daily_shape() and the Top Sessions filter slice the
# cached payload with $(panel_date +%Y-%m-%d) evaluated at RENDER time, and
# the 7/30-day windows are recomputed from the clock every tick.
#
# So the panel is correct across midnight today -- by construction, not by
# accident: the payload is cached, the slice is not. Nothing guards that. Any
# future optimisation that caches a SLICED result silently starts showing
# yesterday's money as today's, and only until someone happens to type does
# anything correct it. This check is that guard.
check_D_clock_slice() {
  sandbox_new D
  local d1="2026-09-01" d2="2026-09-02"
  cat > "$CCUSAGE_FIXTURE_DIR/daily.json" <<JSON
{"daily":[{"date":"$d1","totalCost":12.34,"totalTokens":1000}],"weekly":[],"monthly":[]}
JSON
  load_panel 10 12 ""

  # 10 seconds before local midnight ending $d1.
  export PANEL_FAKE_NOW=$(( $(local_midnight "$d2") - 10 ))
  local payload before_7d
  payload=$(recent_sections_fetch)
  assert_eq "today is d1's row before midnight" "12.34" \
    "$(today_daily_shape "$payload" | jq -r '.totals.totalCost')"
  before_7d=$(panel_date -v-7d +%Y-%m-%d)
  local calls_before; calls_before=$(calls_for daily)

  # 10 seconds after the same midnight. The corpus has NOT changed.
  export PANEL_FAKE_NOW=$(( $(local_midnight "$d2") + 10 ))
  payload=$(recent_sections_fetch)
  assert_eq "today resets to 0 after midnight" "0" \
    "$(today_daily_shape "$payload" | jq -r '.totals.totalCost')"
  assert_eq "yesterday's row is not carried forward" "0" \
    "$(today_daily_shape "$payload" | jq -r '.daily | length')"

  # The point: it re-SLICED, it did not refetch. If this ever starts
  # refetching, the panel is paying a corpus scan to answer a clock question.
  assert_eq "no refetch was needed to cross midnight" "$calls_before" "$(calls_for daily)"

  # Every derived window must move with the clock too, or the 7/30-day
  # baselines silently keep yesterday's bounds.
  assert_ne "the 7-day window moved across midnight" "$before_7d" "$(panel_date -v-7d +%Y-%m-%d)"
  assert_eq "and moved by exactly one day" "2026-08-26" \
    "$(panel_date -v-7d +%Y-%m-%d)"

  unset PANEL_FAKE_NOW
}
