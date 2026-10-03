# Check BC -- the summary rows written for Claude Burst's in-session mod.
#
# One file per session with the colours left in, replaced whole, never
# written without a session or a summary, and pruned after two days.
check_BC_band_file() {
  sandbox_new BC
  load_panel 10 12 ""
  local esc=$'\033'
  band_write aaa "${esc}[32mrow one${esc}[0m"$'\n'"row two"
  assert_eq "written with colours" "${esc}[32mrow one${esc}[0m"$'\n'"row two" "$(cat "$BAND_DIR/aaa.ansi")"
  band_write aaa "new"
  assert_eq "replaced, not appended" "new" "$(cat "$BAND_DIR/aaa.ansi")"
  band_write "" "x"
  band_write bbb ""
  assert_eq "nothing without a session or a summary" "aaa.ansi" "$(ls "$BAND_DIR")"
  touch -t "$(date -v-3d +%Y%m%d%H%M.%S)" "$BAND_DIR/aaa.ansi"
  band_write ccc "c"
  assert_eq "old files pruned" "ccc.ansi" "$(ls "$BAND_DIR")"
}
