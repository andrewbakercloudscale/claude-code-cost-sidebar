# Check AY -- the launcher's --dangerously-skip-permissions follows
# CLAUDE_PANEL_BYPASS_PERMISSIONS, and uninstall puts the line back.
#
# Some launchers hard-code the flag, which made the dashboard's "Start with
# bypass permissions" checkbox untrue for Finder windows. Setup turns it into
# an option: true adds it, false drops it, and with no key the launcher does
# what it did before. Runs setup's own step (cut out of the repo's
# claude-panel-setup.sh between its marker and the next section) against a
# fixture, then the uninstaller, so neither drifts from what ships.
check_AY_launcher_bypass() {
  sandbox_new AY
  case "$HOME" in "$SBX"/*) ;; *) _fail "HOME is the sandbox" "$SBX/..." "$HOME"; return ;; esac
  local setup="$HERE/../claude-panel-setup.sh" bin="$HOME/.local/bin"
  mkdir -p "$bin" "$HOME/.config/claude-panel"
  local step="$SBX/bp-step.sh"
  awk '/^GCL_BP_MARKER=/{on=1} on{print} on && /^fi$/{exit}' "$setup" > "$step"
  assert_contains "setup has the bypass step" 'PANEL_BYPASS_ARGS' "$(cat "$step")"

  local GCL="$bin/ghostty-claude-launcher" pin='"$CLAUDE" --session-id "$PIN_SID"'
  printf '%s\n' '#!/bin/bash' 'CLAUDE=claude' 'PIN_SID=s1' \
    'PANEL_RC_ARGS=()' '# caffeinate -i keeps the Mac awake.' \
    'caffeinate -i "$CLAUDE" --session-id "$PIN_SID" "${PANEL_RC_ARGS[@]}" --dangerously-skip-permissions' > "$GCL"
  (GCL="$GCL" GCL_PIN_LINE="$pin" bash "$step") >/dev/null
  assert_not_contains "the hard-coded flag is gone from the launch line" ' --dangerously-skip-permissions' "$(tail -1 "$GCL")"
  (GCL="$GCL" GCL_PIN_LINE="$pin" bash "$step") >/dev/null
  assert_eq "a second run adds nothing" "1" "$(grep -c 'CLAUDE_PANEL_BYPASS_PERMISSIONS (claude-panel' "$GCL")"

  # Run the patched launcher with caffeinate stubbed to print its arguments.
  local stub="$SBX/stub"; mkdir -p "$stub"
  printf '#!/bin/bash\nshift\necho "$*"\n' > "$stub/caffeinate"; chmod +x "$stub/caffeinate"
  local f="$HOME/.config/claude-panel/options"
  rm -f "$f"
  assert_eq "no key keeps the launcher's old flag" "claude --session-id s1 --dangerously-skip-permissions" "$(PATH="$stub:$PATH" bash "$GCL")"
  printf 'CLAUDE_PANEL_BYPASS_PERMISSIONS=false\n' > "$f"
  assert_eq "false drops it" "claude --session-id s1" "$(PATH="$stub:$PATH" bash "$GCL")"
  printf 'CLAUDE_PANEL_BYPASS_PERMISSIONS=true\n' > "$f"
  assert_eq "true adds it" "claude --session-id s1 --dangerously-skip-permissions" "$(PATH="$stub:$PATH" bash "$GCL")"

  # A launcher that never had the flag: no key leaves it off.
  printf '%s\n' '#!/bin/bash' 'CLAUDE=claude' 'PIN_SID=s1' 'caffeinate -i "$CLAUDE" --session-id "$PIN_SID"' > "$GCL"
  (GCL="$GCL" GCL_PIN_LINE="$pin" bash "$step") >/dev/null
  rm -f "$f"
  assert_eq "no flag before, none without a key" "claude --session-id s1" "$(PATH="$stub:$PATH" bash "$GCL")"
}
