# Check E -- with the usage-panel mod installed, the launcher opens no split.
#
# The mod draws the panel as a sidebar inside Claude Code, so the split and
# every keystroke it types are not needed. The marker file says the mod is
# installed; CLAUDE_PANEL_SPLIT=true, in the environment or the options file,
# opens the split anyway.
check_E_mod_stands_aside() {
  import_fn split_stands_aside || return 1
  local real_home="$HOME" sbx
  sbx=$(mktemp -d "${TMPDIR:-/tmp}/launch-E.XXXXXX")
  HOME="$sbx"
  mkdir -p "$HOME/.config/claude-panel"

  split_stands_aside && _fail "no mod, so the split opens" "opens" "stands aside" || _pass
  touch "$HOME/.config/claude-panel/mod-installed"
  split_stands_aside && _pass || _fail "the mod is installed, so no split" "stands aside" "opens"
  CLAUDE_PANEL_SPLIT=true split_stands_aside && _fail "CLAUDE_PANEL_SPLIT=true opens it anyway" "opens" "stands aside" || _pass
  printf 'CLAUDE_PANEL_SPLIT="on"\n' > "$HOME/.config/claude-panel/options"
  split_stands_aside && _fail "so does the options file" "opens" "stands aside" || _pass
  printf 'CLAUDE_PANEL_SPLIT=false\n' > "$HOME/.config/claude-panel/options"
  split_stands_aside && _pass || _fail "false leaves the mod in charge" "stands aside" "opens"

  HOME="$real_home"
  rm -rf "$sbx"
}
