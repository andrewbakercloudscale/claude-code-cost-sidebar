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
}
