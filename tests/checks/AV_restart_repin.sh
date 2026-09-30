# Check AV -- claude exited and started again in the same pane.
#
# The panel opens once per window, but a pane can run any number of claude
# sessions one after another. The pin the panel follows was written for the
# FIRST one, by the launcher; after an exit and a plain `claude`, only the
# SessionStart hook rewrote it, and where the hook could not (not installed,
# or an npm claude whose process is `node`) the panel stayed on the ended
# session and showed none of the new turns. The ~/.zshrc hook now re-pins
# every fresh interactive `claude` itself.
check_AV_restart_repin() {
  sandbox_new AV
  command -v zsh >/dev/null 2>&1 || { assert_eq "zsh available" "skip" "skip"; return 0; }
  local setup="$HERE/../claude-panel-setup.sh" block pins="$HOME/.cache/claude-panel-pin"
  block=$(awk '/<<.ZSHRC_EOF/{on=1;next} /^ZSHRC_EOF$/{on=0} on' "$setup")
  assert_contains "zshrc block found" "_ccusage_panel_autolaunch" "$block"
  printf '%s\n' "$block" > "$SBX/zblock"
  mkdir -p "$SBX/work" "$HOME/.cache"
  run() { # $1 = command line typed at the prompt
    ( cd "$SBX/work" && HOME="$HOME" CCUSAGE_PANE_TTY=ttyAV1 CCUSAGE_PANEL_LAUNCHED=1 \
        zsh -f -c 'source "$1"; _ccusage_panel_autolaunch "$2"' _ "$SBX/zblock" "$1" ) 2>&1
  }
  local key; key=$(cd "$SBX/work" && zsh -fc 'print -r -- $PWD' | tr '/' '-')

  run "claude"
  local sid1; sid1=$(cut -f1 "$pins/tty/ttyAV1" 2>/dev/null)
  assert_eq "a restart in an open pane writes a tty pin" "1" "$(is_uuid_like "$sid1")"
  assert_eq "and the directory handoff, naming the same session" "$sid1" "$(cut -f1 "$pins/$key" 2>/dev/null)"

  run "claude --dangerously-skip-permissions"
  local sid2; sid2=$(cut -f1 "$pins/tty/ttyAV1")
  assert_ne "a second restart gets a new session id" "$sid1" "$sid2"

  for cmd in "claude -p hello" "claude --resume" "claude -c" "claude mcp list" "claude --version"; do
    run "$cmd"
    assert_eq "'$cmd' does not re-pin the pane" "$sid2" "$(cut -f1 "$pins/tty/ttyAV1")"
  done
  run "caffeinate -i claude"
  assert_ne "a prefixed claude still re-pins" "$sid2" "$(cut -f1 "$pins/tty/ttyAV1")"
  assert_eq "no second panel is launched" "0" "$(grep -c 'claude-panel-launch' "$HOME/.cache/claude-panel-launch.log" 2>/dev/null || true)"
}
is_uuid_like() { [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] && echo 1 || echo 0; }
