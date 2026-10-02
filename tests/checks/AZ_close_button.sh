# Check AZ -- the [X] closes the panel on a left click on it, and only then.
#
# Clicks arrive as SGR mouse reports (ESC [ < button ; column ; row M, with
# m for the release). Every complete report is consumed so releases and
# other buttons never pile up, a report split across two reads is kept for
# the next one, and only a left press on row 1 at or right of the [X]'s
# first column counts. The option defaults to on: only an explicit false
# turns it off.
check_AZ_close_button() {
  sandbox_new AZ
  load_panel 10 12 ""
  local col
  col=$(panel_close_col 40)
  assert_eq "the [X] takes the last three columns" "38" "$col"

  _az() { PANEL_INBUF=$1; panel_clicked_close 40 && echo hit || echo miss; }
  assert_eq "left press on the X" hit "$(_az $'\e[<0;38;1M')"
  assert_eq "left press on its last column" hit "$(_az $'\e[<0;40;1M\e[<0;40;1m')"
  assert_eq "one column left of it" miss "$(_az $'\e[<0;37;1M')"
  assert_eq "the row below it" miss "$(_az $'\e[<0;39;2M')"
  assert_eq "the right button" miss "$(_az $'\e[<2;39;1M')"
  assert_eq "a release alone" miss "$(_az $'\e[<0;39;1m')"
  assert_eq "a hit after typing and an off-target click" hit "$(_az $'x\e[<0;1;1Mzz\e[<0;39;1M')"

  PANEL_INBUF=$'\e[<0;10;5M\e[<0;10;5m\e[<2;3;3M'
  panel_clicked_close 40
  assert_eq "complete reports are consumed" "" "$PANEL_INBUF"
  PANEL_INBUF=$'abc\e[<0;3'
  panel_clicked_close 40
  assert_eq "a report split across reads is kept" $'\e[<0;3' "$PANEL_INBUF"
  PANEL_INBUF+=$'9;1M'
  assert_eq "and completes on the next read" 0 "$(panel_clicked_close 40; echo $?)"

  local f="$HOME/.config/claude-panel/options"
  mkdir -p "$(dirname "$f")"
  rm -f "$f"
  assert_eq "no file leaves the button on" 1 "$(panel_option_off CLAUDE_PANEL_CLOSE_BUTTON; echo $?)"
  printf 'CLAUDE_PANEL_CLOSE_BUTTON=maybe\n' > "$f"
  assert_eq "an unrecognised value leaves it on" 1 "$(panel_option_off CLAUDE_PANEL_CLOSE_BUTTON; echo $?)"
  printf 'CLAUDE_PANEL_CLOSE_BUTTON=false\n' > "$f"
  assert_eq "false turns it off" 0 "$(panel_option_off CLAUDE_PANEL_CLOSE_BUTTON; echo $?)"
}
