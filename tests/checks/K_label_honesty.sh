# Check K -- no section header may advertise a refresh rate it does not keep.
#
# The panel has shipped this bug before: a header read "refresh 5s" while the
# figures under it moved every 10, because the label was a hardcoded string
# and the rate was a variable. The fix was to derive every label from the
# variable that governs the data. Two TTL buckets give that bug somewhere new
# to live -- a section fed by the history bucket while labelled with the tick
# rate -- so the check now covers the buckets as well as the literals.
check_K_label_honesty() {
  sandbox_new K
  load_panel 10 12 ""

  assert_eq "fast label derives from REFRESH"        "10s" "$RATE_FAST"
  assert_eq "slow label derives from SLOW_REFRESH"   "2m"  "$RATE_SLOW"
  assert_eq "history label derives from TTL_HISTORY" "$(fmt_interval "$TTL_HISTORY")" "$RATE_HISTORY"

  # A header may never advertise a rate FASTER than the TTL governing its
  # data, or it promises freshness the cache will not deliver.
  assert_eq "the live bucket is no slower than the tick it rides on" "1" \
    "$([ "$TTL_LIVE" -le "$SLOW_REFRESH" ] && echo 1 || echo 0)"
  assert_eq "the history bucket is slower than the live one" "1" \
    "$([ "$TTL_HISTORY" -gt "$TTL_LIVE" ] && echo 1 || echo 0)"

  # Neither bucket may be a whole multiple of the tick. At exactly N ticks an
  # entry is aged exactly its TTL and `age < TTL` becomes a coin flip decided
  # by a second's rounding -- which once produced an observed 240s refresh
  # under a header advertising 120s.
  assert_ne "live TTL is not a whole multiple of the tick"    "0" "$(( TTL_LIVE % SLOW_REFRESH ))"
  assert_ne "history TTL is not a whole multiple of the tick" "0" "$(( TTL_HISTORY % SLOW_REFRESH ))"

  # Every rate_tag argument must be a variable, never a literal interval.
  local literals
  literals=$(grep -n 'rate_tag "' "$PANEL_SH" | grep -Ev 'rate_tag "\$(RATE_FAST|RATE_SLOW|RATE_HISTORY)"' || true)
  assert_eq "no rate_tag call passes a hardcoded interval" "" "$literals"

  # The section fed by the history bucket must say so.
  assert_eq "Top Sessions Today advertises the history rate" "1" \
    "$(grep -c 'Top Sessions Today \$(rate_tag "\$RATE_HISTORY")' "$PANEL_SH")"

  # fmt_interval is the single source of those strings; spot-check its edges
  # so a label cannot be right for the wrong reason.
  assert_eq "fmt_interval seconds"       "45s"    "$(fmt_interval 45)"
  assert_eq "fmt_interval whole minutes" "15m"    "$(fmt_interval 900)"
  assert_eq "fmt_interval mixed"         "1m30s"  "$(fmt_interval 90)"
}
