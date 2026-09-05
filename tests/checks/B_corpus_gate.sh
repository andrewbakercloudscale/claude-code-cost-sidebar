# Check B -- the corpus-change gate still governs refetching.
#
# ccusage_cached() serves a cache entry past its TTL when no transcript has
# been written since the entry was produced, on the grounds that a ccusage
# report is a pure function of the transcript corpus. That gate is what makes
# an idle pane free, so it is the first thing any TTL work must not break.
check_B_corpus_gate() {
  sandbox_new B
  cat > "$CCUSAGE_FIXTURE_DIR/daily.json" <<'JSON'
{"daily":[{"date":"2026-09-01","totalCost":1.5,"totalTokens":100}],"weekly":[],"monthly":[]}
JSON
  load_panel 10 12 ""

  recent_sections_fetch >/dev/null
  assert_eq "first call fetches" 1 "$(calls_for daily)"

  recent_sections_fetch >/dev/null
  assert_eq "second call inside TTL is served from cache" 1 "$(calls_for daily)"

  # TTL lapsed, corpus untouched: the gate -- not the TTL -- must hold it.
  local key cache
  key=$(printf '%s' "claude daily --json --offline" | shasum -a 256 | cut -c1-16)
  cache="$CCUSAGE_CACHE_DIR_REAL/$key.json"
  assert_eq "cache file exists at the expected key" 1 "$([ -f "$cache" ] && echo 1 || echo 0)"
  age_file "$cache" 600
  recent_sections_fetch >/dev/null
  assert_eq "TTL lapsed but corpus unchanged: still no refetch" 1 "$(calls_for daily)"

  # A transcript write is the one thing that can change the answer.
  touch "$HOME/.claude/projects/test-project/seed.jsonl"
  recent_sections_fetch >/dev/null
  assert_eq "corpus changed: exactly one refetch" 2 "$(calls_for daily)"

  recent_sections_fetch >/dev/null
  assert_eq "and the refetched entry is itself cached" 2 "$(calls_for daily)"
}
