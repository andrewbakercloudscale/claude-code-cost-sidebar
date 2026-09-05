# Check B -- stats --days 7/30 get the long TTL; everything else gets the
# short one. A 7/30-day average cannot move meaningfully inside a couple of
# minutes; today's total and the session list (which is how a brand-new
# session gets noticed at all) must stay responsive.
check_B_ttl_buckets() {
  sandbox_new B
  load_panel 5 12
  assert_eq "stats --days 7 is history"       "$TTL_HISTORY" "$(oc_ttl_for stats --days 7)"
  assert_eq "stats --days 30 is history"      "$TTL_HISTORY" "$(oc_ttl_for stats --days 30)"
  assert_eq "stats --days 1 is live"          "$TTL_LIVE" "$(oc_ttl_for stats --days 1)"
  assert_eq "session list is live"            "$TTL_LIVE" "$(oc_ttl_for session list --format json)"
  assert_eq "history is the longer bucket"    "1" "$(( TTL_HISTORY > TTL_LIVE ? 1 : 0 ))"
  assert_ne "live TTL is not a multiple of a 5s tick"    "0" "$(( TTL_LIVE % 5 == 0 ? 0 : 1 ))"
}
