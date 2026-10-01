# Check AX -- the panel remembers the width it was dragged to.
#
# Every new window opened the panel at the launcher's fixed 30% and it had
# to be widened by hand each time (2026-10-01). The panel now saves its share
# of the panel+claude pair once that pair has held still for two ticks, and
# the launcher opens the next one at that share.
check_AX_panel_width_memory() {
  sandbox_new AX
  load_panel 10 12 ""
  local f="$HOME/.config/claude-panel/width-pct" fake_cc=70
  stty() { [ "$1" = -f ] && printf '40 %s\n' "$fake_cc" || command stty "$@"; }

  PANE_CLAUDE_TTY=""
  remember_panel_width 30; remember_panel_width 30
  assert_eq "unpaired: nothing saved" "" "$(cat "$f" 2>/dev/null)"

  PANE_CLAUDE_TTY=ttysAX
  remember_panel_width 30
  assert_eq "one tick is not a choice (the launcher may still be shrinking it)" "" "$(cat "$f" 2>/dev/null)"
  remember_panel_width 30
  assert_eq "two still ticks save the share" "30" "$(cat "$f")"
  fake_cc=55; remember_panel_width 45; remember_panel_width 45
  assert_eq "a drag to 45/55 is remembered" "45" "$(cat "$f")"
  fake_cc=20; remember_panel_width 80; remember_panel_width 80
  assert_eq "capped at half (the launcher only shrinks from 50/50)" "50" "$(cat "$f")"
  unset -f stty

  local launch
  launch=$(awk '/<<.LAUNCH_EOF/{on=1;next} /^LAUNCH_EOF$/{on=0} on' "$HERE/../claude-panel-setup.sh" \
    | grep -E '^_saved_pct=|^case "\$_saved_pct"|^\(\( _saved_pct|^PANEL_WIDTH_PCT=')
  assert_eq "the launcher reads it" "45" \
    "$(printf '45\n' > "$f"; bash -c "$launch"$'\n''echo $PANEL_WIDTH_PCT')"
  assert_eq "garbage falls back to 30" "30" \
    "$(printf 'wide\n' > "$f"; bash -c "$launch"$'\n''echo $PANEL_WIDTH_PCT')"
  assert_eq "the environment still wins" "40" \
    "$(PANEL_WIDTH_PCT=40 bash -c "$launch"$'\n''echo $PANEL_WIDTH_PCT')"
}
