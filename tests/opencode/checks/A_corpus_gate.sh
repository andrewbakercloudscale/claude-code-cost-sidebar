# Check A -- an idle database costs nothing past the first fetch.
#
# Every query used to run unconditionally, every tick, forever: measured at
# 26.54 CPU-s over 60s of real activity, 44% of a core continuously. The gate
# mirrors ccusage-panel.sh's corpus_changed_since() against opencode's own
# storage (a SQLite db in WAL mode) instead of a JSONL tree.
check_A_corpus_gate() {
  sandbox_new A
  load_panel 5 12

  opencode_cached session list --format json >/dev/null
  assert_eq "first call fetches" "1" "$(calls_for "session list")"
  opencode_cached session list --format json >/dev/null
  assert_eq "second call inside TTL is cached" "1" "$(calls_for "session list")"

  local key cache
  key=$(printf '%s' "session list --format json" | shasum -a 256 | cut -c1-16)
  cache="$OC_CACHE_DIR/$key.json"
  touch -t "$(date -v-1H +%Y%m%d%H%M.%S)" "$cache"
  opencode_cached session list --format json >/dev/null
  assert_eq "TTL lapsed but db unchanged: still no refetch" "1" "$(calls_for "session list")"

  touch_db
  opencode_cached session list --format json >/dev/null
  assert_eq "db changed: exactly one refetch" "2" "$(calls_for "session list")"
}
