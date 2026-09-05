# Check T -- the per-session caches are pruned, and the prune stops there.
#
# Three of the panel's caches are keyed by session and one by process id, so
# unlike the `<key>.json` query cache they never converge on a fixed set of
# files: one entry per session that has ever been shown, one per panel that
# has ever run, kept forever. The prune runs at file scope, so load_panel is
# what triggers it.
#
# The second half matters as much as the first. A prune that also swept the
# query cache would be invisible -- every figure would still be correct --
# while silently forcing a full ccusage refetch of every report, which is
# the exact cost this whole effort exists to avoid.
check_T_cache_pruning() {
  sandbox_new T
  local CD="$HOME/.cache/ccusage-panel-cache"
  mkdir -p "$CD"

  # 8 days: past the 7-day cutoff. A cache entry is only rewritten on a
  # miss, so an entry this old means the session behind it has not been
  # touched in a week, and deleting it costs one refetch if it ever is.
  local OLD=691200 stale fresh
  for stale in turns-aaaa.out sessid-aaaa.tsv todaytok-aaaa.tsv errors-99999.log; do
    printf 'stale\n' > "$CD/$stale"
    age_file "$CD/$stale" "$OLD"
  done
  # Fresh siblings of every family, and the query cache. None may be touched.
  for fresh in turns-bbbb.out sessid-bbbb.tsv todaytok-bbbb.tsv errors-88888.log; do
    printf 'fresh\n' > "$CD/$fresh"
  done
  # The query cache is governed by its TTL and the corpus gate, not by age
  # on disk -- an old one is a CORRECT one when the corpus has not moved.
  printf '{"sessions":[]}\n' > "$CD/0123456789abcdef.json"
  age_file "$CD/0123456789abcdef.json" "$OLD"
  printf 'MIT\n' > "$CD/license.txt"
  age_file "$CD/license.txt" "$OLD"

  load_panel 10 12 ""

  local gone=0 kept=0 f
  for f in turns-aaaa.out sessid-aaaa.tsv todaytok-aaaa.tsv errors-99999.log; do
    [ -e "$CD/$f" ] || gone=$(( gone + 1 ))
  done
  assert_eq "all four stale families are pruned" "4" "$gone"

  for f in turns-bbbb.out sessid-bbbb.tsv todaytok-bbbb.tsv errors-88888.log; do
    [ -e "$CD/$f" ] && kept=$(( kept + 1 ))
  done
  assert_eq "and their fresh siblings are not" "4" "$kept"

  assert_eq "an aged query cache survives -- it is the gate's to expire" "1" \
    "$( [ -e "$CD/0123456789abcdef.json" ] && echo 1 || echo 0 )"
  assert_eq "and so does anything else in the directory" "1" \
    "$( [ -e "$CD/license.txt" ] && echo 1 || echo 0 )"

  # This panel's OWN error log is created after the prune and must exist, or
  # panel_error() would be writing into a file nothing ever reads. A prune
  # placed one line later would break exactly this and nothing else.
  assert_eq "the running panel's error log is in place afterwards" "1" \
    "$( [ -e "$PANEL_ERR_FILE" ] && echo 1 || echo 0 )"
}
