# Check AN -- the red restart warning appears at the configured context size.
#
# CLAUDE_PANEL_RESTART_TOKENS in ~/.config/claude-panel/options sets the
# threshold (default 400000, 0 = off). An unparseable value falls back to the
# default rather than switching the warning off.
check_AN_restart_banner() {
  sandbox_new AN
  load_panel 10 12 ""
  local f="$HOME/.config/claude-panel/options" msg="RESTART DUE TO HIGH CONTEXT"

  assert_eq "below the default 400k: no warning" "" "$(restart_banner 399999)"
  assert_contains "at the default 400k: warning" "$msg" "$(restart_banner 400000)"
  assert_contains "in red" $'\033[31m' "$(restart_banner 400000)"
  assert_contains "flashing" $'\033[5m' "$(restart_banner 400000)"

  mkdir -p "$(dirname "$f")"
  printf 'CLAUDE_PANEL_RESTART_TOKENS=250000\n' > "$f"
  assert_contains "a configured threshold is honoured" "$msg" "$(restart_banner 250000)"
  assert_eq "and nothing below it" "" "$(restart_banner 249999)"

  printf 'CLAUDE_PANEL_RESTART_TOKENS=0\n' > "$f"
  assert_eq "0 turns it off" "" "$(restart_banner 5000000)"

  printf 'CLAUDE_PANEL_RESTART_TOKENS=lots\n' > "$f"
  assert_contains "garbage falls back to the default, not off" "$msg" "$(restart_banner 400000)"

  assert_eq "the environment overrides the file" "" \
    "$(CLAUDE_PANEL_RESTART_TOKENS=900000 restart_banner 400000)"
}
