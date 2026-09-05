# Check D -- N concurrent OpenCode panels share one fetch, the same property
# ccusage-panel.sh's cache dir already gives Claude Code. The cache lives in
# $HOME/.cache, keyed only on the query -- not on a pid or session id -- so
# it is shared by construction; this asserts that stays true rather than
# assuming it because "it's a directory".
check_D_shared_across_panels() {
  sandbox_new D
  local i
  for i in 1 2 3; do
    ( load_panel 5 12; opencode_cached stats --days 1 >/dev/null )
  done
  assert_eq "3 panels share ONE stats fetch" "1" "$(calls_for "stats --days 1")"

  # The TTL has not lapsed yet, so the cache is served from the TTL branch
  # without ever reaching the corpus gate -- correct, and not what this half
  # is testing. Age the entry past its TTL first, THEN move the db, so the
  # refetch below is provably the gate's doing and not a TTL coincidence.
  # $OC_CACHE_DIR is a plain (non-exported) variable set INSIDE the sourced
  # panel -- each `load_panel` above ran in its own subshell, so it never
  # existed in this shell to read. Its value is fixed and known ($HOME/.cache/
  # opencode-panel-cache), so build the path from that instead of depending
  # on a variable that was never in scope here.
  local key cache
  key=$(printf '%s' "stats --days 1" | shasum -a 256 | cut -c1-16)
  cache="$HOME/.cache/opencode-panel-cache/$key.json"
  touch -t "$(date -v-1H +%Y%m%d%H%M.%S)" "$cache"
  touch_db
  for i in 1 2 3; do
    ( load_panel 5 12; opencode_cached stats --days 1 >/dev/null )
  done
  assert_eq "and share ONE refetch when the db changes" "2" "$(calls_for "stats --days 1")"
}
