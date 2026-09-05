# Check P -- an unchanged frame is not written to the terminal again.
#
# Every write is also a repaint in the terminal emulator, charged to Ghostty
# once per open panel -- so this is the part of the fast tier that scales with
# the number of concurrent Claude Code sessions.
#
# Asserted at the source level rather than by driving the loop: the loop is an
# infinite render loop against a tty, and a test that fakes a tty to count
# escape sequences would be testing its own harness. What can regress here is
# someone reinstating an unconditional write, and that is visible in the text.
check_P_frame_elision() {
  sandbox_new P

  # The cursor-home must live INSIDE the guard. Left outside it, every tick
  # still writes an escape sequence and the terminal still repaints -- the
  # elision would look present and do nothing.
  local home_lines guarded
  home_lines=$(grep -c "printf '\\\\033\[H'" "$PANEL_SH")
  assert_eq "exactly one cursor-home write" "1" "$home_lines"
  guarded=$(awk '/if \[ "\$frame" != "\$last_frame" \]; then/{f=1} f && /033\[H/{print "yes"; exit}' "$PANEL_SH")
  assert_eq "and it sits inside the changed-frame guard" "yes" "$guarded"

  assert_eq "the previous frame is remembered" "1" \
    "$(grep -c '^last_frame=""' "$PANEL_SH")"
  assert_eq "and compared before writing" "1" \
    "$(grep -c 'if \[ "\$frame" != "\$last_frame" \]; then' "$PANEL_SH")"
  assert_eq "and updated only after a write" "1" \
    "$(grep -c '^    last_frame="\$frame"' "$PANEL_SH")"

  # The frame must include the trailing sections. Comparing only the
  # guaranteed block would freeze Recent and Top Sessions on screen.
  assert_contains "the compared frame covers both blocks" 'frame="$guaranteed"' \
    "$(grep 'frame="\$guaranteed"' "$PANEL_SH")"
}
