# Check K -- no section header may advertise a refresh rate it does not keep.
#
# The panel has shipped this bug before: a header read "refresh 5s" while the
# figures under it moved every 10, because the label was a hardcoded string
# and the rate was a variable. The fix was to derive every label from the
# variable that governs the data. This check keeps that true, and it is a
# source-level check on purpose -- the failure it guards is someone typing a
# literal, which no amount of rendering will reveal if the literal happens to
# be right on the day it is typed.
check_K_label_honesty() {
  sandbox_new K
  load_panel 10 12 ""

  assert_eq "fast label derives from REFRESH" "10s" "$RATE_FAST"
  assert_eq "slow label derives from SLOW_REFRESH" "2m" "$RATE_SLOW"

  # A header may never advertise a rate FASTER than the TTL governing its
  # data, or it is promising freshness the cache will not deliver.
  assert_eq "slow-tier TTL is not longer than the rate it advertises" "1" \
    "$([ "$CCUSAGE_CACHE_TTL" -le "$SLOW_REFRESH" ] && echo 1 || echo 0)"

  # Every rate_tag argument must be a variable, never a literal interval.
  local literals
  literals=$(grep -n 'rate_tag "' "$PANEL_SH" | grep -Ev 'rate_tag "\$(RATE_FAST|RATE_SLOW)"' || true)
  assert_eq "no rate_tag call passes a hardcoded interval" "" "$literals"

  # fmt_interval is the single source of those strings; spot-check its edges
  # so a label cannot be right for the wrong reason.
  assert_eq "fmt_interval seconds" "45s" "$(fmt_interval 45)"
  assert_eq "fmt_interval whole minutes" "15m" "$(fmt_interval 900)"
  assert_eq "fmt_interval mixed" "1m30s" "$(fmt_interval 90)"
}
