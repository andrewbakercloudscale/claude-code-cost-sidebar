# Check BL -- figures every panel shows are worked out once for all of them.
#
# Today's top turns and the summary's 30-day and week averages are the same
# in every panel, and each worked them out on its own slow tick. shared_memo
# keeps what the first one set for the others while it is fresh and from
# today.
check_BL_shared_figures() {
  sandbox_new BL
  load_panel 10 12 ""
  BL_RUNS=0
  bl_compute() { BL_RUNS=$(( BL_RUNS + 1 )); BL_A="one two"; BL_B=(x "y z"); }
  PANEL_SHARED_TTL=100
  shared_memo bl bl_compute BL_A BL_B
  BL_A=""; BL_B=()
  shared_memo bl bl_compute BL_A BL_B
  assert_eq "worked out once" "1" "$BL_RUNS"
  assert_eq "a string comes back whole" "one two" "$BL_A"
  assert_eq "and an array" "y z" "${BL_B[1]}"
  # Set as globals, though sourced inside a function.
  bl_reader() { shared_memo bl bl_compute BL_A BL_B; }
  BL_A=""; bl_reader
  assert_eq "inside a function too" "one two" "$BL_A"
  age_file "$CCUSAGE_CACHE_DIR/shared-bl.sh" 200
  shared_memo bl bl_compute BL_A BL_B
  assert_eq "worked out again once stale" "2" "$BL_RUNS"
  sed -i '' '1s/.*/# 2000-01-01/' "$CCUSAGE_CACHE_DIR/shared-bl.sh"
  shared_memo bl bl_compute BL_A BL_B
  assert_eq "and from another day" "3" "$BL_RUNS"
  PANEL_SHARED_TTL=0
  shared_memo bl bl_compute BL_A BL_B
  assert_eq "off at 0" "4" "$BL_RUNS"

  # build_trailing's figures, headless: a top-sessions table with tabs and
  # lines in it comes back as it went in.
  PANEL_SHARED_TTL=100
  # It reads rows into day, f and line, which once emptied shared_memo's own.
  build_trailing() { day=""; f=""; line=""; m=""; week_cost=12.5; month_cost=40; top_rows=$'aaa\t1.5\t100\tt1\nbbb\t2\t200\tt2'; echo text; }
  trailing_refresh
  week_cost=""; month_cost=""; top_rows=""
  build_trailing() { week_cost=99; }
  trailing_refresh
  assert_eq "trailing: week shared" "12.5" "$week_cost"
  assert_eq "trailing: month shared" "40" "$month_cost"
  assert_eq "trailing: top rows whole" $'aaa\t1.5\t100\tt1\nbbb\t2\t200\tt2' "$top_rows"
  assert_eq "trailing: its text goes nowhere" "" "$(trailing_refresh)"

  # session_stats_refresh splits its cache line with expansions now: an
  # empty field must not shift the ones after it.
  turn_table_series() { printf '#META\t1.25\t\t200000\t1\n#SERIES\ts1\ts2\nrow one\nrow two'; }
  latest=/x; session_stats_refresh
  assert_eq "stats: cost" "1.25" "$SESS_COST"
  assert_eq "stats: empty context stays empty" "" "$SESS_CTX"
  assert_eq "stats: window after it" "200000" "$SESS_WIN"
  assert_eq "stats: compacting" "1" "$SESS_COMPACTING"
  assert_eq "stats: series" $'s1\ts2' "$SESS_SERIES"
  assert_eq "stats: table" $'row one\nrow two' "$SESS_TABLE"
  turn_table_series() { printf '#META\t2\t5\t9\t0\n#SERIES\ts'; }
  session_stats_refresh
  assert_eq "stats: series alone, no table" "" "$SESS_TABLE"
  assert_eq "stats: series alone" "s" "$SESS_SERIES"
  turn_table_series() { printf 'old table'; }
  session_stats_refresh
  assert_eq "stats: old cache entry is the table" "old table" "$SESS_TABLE"
  assert_eq "stats: with no figures" "" "$SESS_COST"
  grep -q 'trailing_refresh 2>>' "$PANEL_SH" \
    && assert_eq "headless shares the trailing figures" "yes" "yes" \
    || assert_eq "headless shares the trailing figures" "yes" "no"
}
