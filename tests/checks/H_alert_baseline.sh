# Check H -- the cost alert's baseline cannot be staled by the panel's buckets.
#
# claude-cost-alert-check.sh posts into the chat at 2x and 3x the 7-day
# average session cost, and it reads that average out of the SAME cache
# directory as the panel. If it ever shared the panel's `session` cache key,
# the history bucket would hand it a baseline up to a quarter of an hour old
# -- and because the hook throttles per session and per tier, an early fire
# on a stale-low baseline CONSUMES the tier, so the real crossing is never
# reported at all. Staleness there causes a wrong action, not a stale
# display, which is why it gets its own check rather than a comment.
#
# Today the hook queries `session --json --since <7d>` and the panel queries
# `session --json --offline`: different argument strings, therefore different
# cache keys, therefore independent TTLs. This asserts that stays true.
check_H_alert_baseline() {
  sandbox_new H
  local hook="$HOME_REAL_BIN/claude-cost-alert-check.sh"
  if [ ! -f "$hook" ]; then
    # Not installed on this machine: say so with an assertion rather than
    # silently skipping, or the check reports ok while testing nothing.
    assert_eq "cost-alert hook is present to be checked" "1" "0"
    return
  fi
  load_panel 10 12 ""

  local hook_args panel_args hook_key panel_key
  hook_args=$(grep -o 'cache_args="[^"]*"' "$hook" | head -1 | sed 's/cache_args="//; s/"$//')
  assert_ne "the hook's cache_args were found" "" "$hook_args"
  panel_args="session --json --offline"

  hook_key=$(printf '%s' "$hook_args" | shasum -a 256 | cut -c1-16)
  panel_key=$(printf '%s' "$panel_args" | shasum -a 256 | cut -c1-16)
  assert_ne "hook and panel do not share a session cache entry" "$hook_key" "$panel_key"

  # And the hook keeps its own short TTL rather than importing the panel's.
  assert_eq "the hook defines its own TTL" "1" \
    "$(grep -qE '^HOOK_CACHE_TTL=[0-9]+' "$hook" && echo 1 || echo 0)"
  assert_eq "which is no longer than the live bucket" "1" \
    "$(awk -F= '/^HOOK_CACHE_TTL=/{print ($2 <= '"$TTL_LIVE"'*2) ? 1 : 0; exit}' "$hook")"
  assert_eq "the hook never reads the history bucket's TTL" "0" \
    "$(grep -c 'TTL_HISTORY' "$hook" || true)"
}
