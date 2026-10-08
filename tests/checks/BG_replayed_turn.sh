# Check BG -- a turn whose context rose by far more than it wrote is shown
# as a replay, with the rise, not with the few tokens it wrote.
#
# On 2026-10-06, after a 26 minute pause, Anthropic answered 404
# thread_not_found and Claude Code sent its whole own copy of the
# conversation: 138k became 240k with 5 tokens written, and the row read
# "240k (+5)". Runs the panel's own function, so it cannot drift.
check_BG_replayed_turn() {
  local fn got
  fn=$(awk '/^def replayed_tokens\(/{on=1} on&&/^$/{exit} on' "$PANEL_SH")
  assert_eq "the replay function is in the panel" "1" "$(printf '%s' "$fn" | grep -c '^def replayed_tokens')"
  got=$(FN="$fn" python3 -c '
import os
exec(os.environ["FN"])
for prev, ctx, delta in ((138008, 239965, 5), (136954, 138008, 1052), (148086, 50809, 20107),
                         (0, 60114, 29412), (204000, 290000, 86000), (20000, 45000, 2000), (400000, 425000, 3000)):
    print(replayed_tokens(prev, ctx, delta))
')
  assert_eq "the replay, then ordinary growth, a compaction, a first turn and a large write" \
    "101957
0
0
0
0" "$(printf '%s\n' "$got" | sed -n '1,5p')"
  assert_eq "a small session's 23k rise is a replay, a large session's 22k is not" "25000
0" "$(printf '%s\n' "$got" | sed -n '6,7p')"
  # The other way, a compaction: the whole row in the Cache column's blue.
  assert_contains "a turn whose context shrank is drawn whole in blue" \
    'print(f"  {col_cache}{turn_no:<5}{label:<10}{cost_cell:>7} {pad}{total_str} ({sign}{delta_str}){cache_pct:>5.0f}%{c_reset}")' "$(cat "$PANEL_SH")"
  # The Δ is always in k: tenths under a thousand, 0k when too small to show.
  fn=$(awk '/^def fmt_dk\(/{on=1} on&&/^$/{exit} on' "$PANEL_SH")
  got=$(FN="$fn" python3 -c '
import os
exec(os.environ["FN"])
print(" ".join(fmt_dk(n) for n in (3, 49, 50, 446, 682, 949, 950, 1049, 5400, 101957)))
')
  assert_eq "a turn's delta is always in k" "0k 0k 0.1k 0.4k 0.7k 0.9k 1k 1k 5k 102k" "$got"
  assert_contains "the row is followed by a line that says so" 'Replayed in full: {fmt_k(replayed)} sent again' "$(cat "$PANEL_SH")"
}
