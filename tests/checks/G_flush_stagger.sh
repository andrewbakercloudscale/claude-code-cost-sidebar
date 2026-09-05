# Check G -- expiries are spread, and every panel agrees on where.
#
# Without jitter every cache entry is seeded when a panel starts and they all
# lapse on the same tick for the life of the pane: one lurching frame and one
# CPU spike instead of several small ones, in every open panel at once.
#
# The jitter is derived from the CACHE KEY rather than $RANDOM or the pid,
# and that is the load-bearing part. Two panels must compute the SAME expiry
# for the same query, or N panels stagger into N separate fetches of one
# shared entry and the cross-panel cache stops being a cache.
check_G_flush_stagger() {
  sandbox_new G
  load_panel 10 12 ""

  local k1="00aa11bb22cc33dd" k2="e910ff0011223344"
  assert_eq "same key, same TTL (a panel must not drift against itself)" \
    "$(ccusage_ttl_jittered session "$k1")" "$(ccusage_ttl_jittered session "$k1")"
  assert_ne "different keys land on different expiries" \
    "$(ccusage_ttl_jittered session "$k1")" "$(ccusage_ttl_jittered session "$k2")"

  # Never over-promise: a section advertising 15m must not be served an
  # entry older than 15m. Jitter subtracts, so this holds by construction --
  # assert it, because "by construction" is how the last one got through.
  local k ttl over=0 under=0
  for k in 00 11 2f 3c 4d 5e 6f 7a 8b 9c ad be cf d0 e1 f2; do
    ttl=$(ccusage_ttl_jittered session "${k}00000000000000")
    (( ttl > TTL_HISTORY )) && over=$(( over + 1 ))
    (( ttl < TTL_HISTORY )) && under=$(( under + 1 ))
  done
  assert_eq "no key is served staler than its label promises" "0" "$over"
  assert_eq "and the spread is real, not a no-op" "1" "$(( under > 0 ? 1 : 0 ))"
}
