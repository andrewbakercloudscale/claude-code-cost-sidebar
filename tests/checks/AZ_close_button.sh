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

  # [View] ends the Proxy State line; the frame below puts it on row 3
  # at columns 35-40 (the emoji is two columns wide).
  _gw() { PANEL_INBUF=$1; panel_read_clicks 40; echo "${PANEL_CLICK:-none}"; }
  panel_locate_view $'Claude Code Usage: 07:37:20\n  x\n  \U1F500 Proxy State: \e[32mPRIMARY (oauth)\e[0m \e[1m[View]\e[0m\n  License: Max'
  assert_eq "View row found" 3 "$PANEL_GW_ROW"
  assert_eq "View column found" 35 "$PANEL_GW_COL"
  PANEL_GW_URL=""
  assert_eq "no Burst, no View button" none "$(_gw $'\e[<0;36;3M')"
  PANEL_GW_URL="http://127.0.0.1:7788/"
  assert_eq "View, first column" gateway "$(_gw $'\e[<0;35;3M')"
  assert_eq "View, last column" gateway "$(_gw $'\e[<0;40;3M')"
  assert_eq "right of View" none "$(_gw $'\e[<0;41;3M')"
  assert_eq "left of View" none "$(_gw $'\e[<0;34;3M')"
  assert_eq "View's columns on another row" none "$(_gw $'\e[<0;36;2M')"
  assert_eq "close wins over View in one read" close "$(_gw $'\e[<0;39;1M\e[<0;36;3M')"
  panel_locate_view $'Claude Code Usage\n  \U1F500 Proxy State: PRIMARY'
  assert_eq "no [View] on the line, no button" 0 "$PANEL_GW_ROW"

  local stub="$SBX/bin" cfg="$HOME/.config/claude-burst/config.json"
  mkdir -p "$stub" "$(dirname "$cfg")"
  assert_eq "no claude-burst, no URL" "" "$(PATH="/usr/bin:/bin" panel_gateway_url)"
  printf '#!/bin/sh\n' > "$stub/claude-burst"; chmod +x "$stub/claude-burst"
  printf '{}\n' > "$cfg"
  assert_eq "the default dashboard address" "http://127.0.0.1:7788/" "$(PATH="$stub:$PATH" panel_gateway_url)"
  printf '{"admin_listen":"127.0.0.1:9999"}\n' > "$cfg"
  assert_eq "admin_listen from config.json" "http://127.0.0.1:9999/" "$(PATH="$stub:$PATH" panel_gateway_url)"
  printf '{"admin_listen":"off"}\n' > "$cfg"
  assert_eq "a dashboard turned off has no button" "" "$(PATH="$stub:$PATH" panel_gateway_url)"

  # Focus in (ESC [ I) asks for a redraw and never reads as a click; focus
  # out does neither; a click beside them still counts.
  _focus() { PANEL_REDRAW=0; PANEL_INBUF=$1; panel_read_clicks 40; echo "$PANEL_REDRAW ${PANEL_CLICK:-none} ${#PANEL_INBUF}"; }
  assert_eq "focus in redraws" "1 none 0" "$(_focus $'\e[I')"
  assert_eq "focus out does not" "0 none 0" "$(_focus $'\e[O')"
  assert_eq "focus in beside a close click" "1 close 0" "$(_focus $'\e[I\e[<0;40;1M\e[O')"

  local f="$HOME/.config/claude-panel/options"
  mkdir -p "$(dirname "$f")"
  rm -f "$f"
  assert_eq "no file leaves the button on" 1 "$(panel_option_off CLAUDE_PANEL_CLOSE_BUTTON; echo $?)"
  printf 'CLAUDE_PANEL_CLOSE_BUTTON=maybe\n' > "$f"
  assert_eq "an unrecognised value leaves it on" 1 "$(panel_option_off CLAUDE_PANEL_CLOSE_BUTTON; echo $?)"
  printf 'CLAUDE_PANEL_CLOSE_BUTTON=false\n' > "$f"
  assert_eq "false turns it off" 0 "$(panel_option_off CLAUDE_PANEL_CLOSE_BUTTON; echo $?)"
}
