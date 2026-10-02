# Check AR -- claude-panel-uninstall.sh removes the panel and nothing else.
#
# The uninstaller edits three files the user also owns (~/.zshrc,
# ~/.claude/settings.json, ~/.local/bin/ghostty-claude-launcher), so the
# check is that each comes back exactly as it was before setup touched it:
# the user's own lines, hooks and launch command intact. Fixtures are the
# shapes setup writes (markers, hook commands, the launcher patch), built by
# hand so the check needs no clang and runs in a moment. Runs the repo's
# copy, not an installed one: the uninstaller is never deployed.
check_AR_uninstall() {
  sandbox_new AR
  local u="${PANEL_UNINSTALL:-$HERE/../claude-panel-uninstall.sh}"
  local bin="$HOME/.local/bin"
  case "$HOME" in "$SBX"/*) ;; *) _fail "HOME is the sandbox" "$SBX/..." "$HOME"; return ;; esac
  mkdir -p "$bin" "$HOME/.config/claude-panel" "$HOME/.config/ghostty" "$HOME/.cache/ccusage-panel-cache" "$HOME/.cache/claude-panel-pin"

  printf 'export FOO=1\n' > "$SBX/zshrc.orig"
  printf 'alias ll="ls -l"\n' >> "$SBX/zshrc.orig"
  { cat "$SBX/zshrc.orig"; printf '\n%s\n%s\n%s\n' \
      "# --- ccusage split-panel autolaunch (installed by claude-panel-setup.sh) ---" \
      "claude() { command claude \"\$@\"; }" \
      "# --- end ccusage split-panel autolaunch ---"; } > "$HOME/.zshrc"

  local mine='{"model":"opus","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"~/mine.sh"}]}]}}'
  printf '%s\n' "$mine" | jq --arg s "~/.local/bin/claude-panel-session-hook.sh" --arg a "~/.local/bin/claude-cost-alert-check.sh" '
    .hooks.SessionStart += [{"hooks":[{"type":"command","command":$s,"timeout":5}]}]
    | .hooks.UserPromptSubmit = [{"hooks":[{"type":"command","command":$a,"timeout":5}]}]' > "$HOME/.claude/settings.json"

  printf '%s\n' '#!/bin/bash' 'cd "$1"' '# caffeinate -i keeps the Mac awake.' \
    'caffeinate -i "$CLAUDE" --dangerously-skip-permissions' > "$SBX/gcl.orig"
  { head -2 "$SBX/gcl.orig"
    printf '%s\n' '' '# Auto-open the live ccusage stats panel in a right-hand split, pinned to' \
      '# the exact session ID.' \
      "PIN_SID=\"\$(uuidgen | tr '[:upper:]' '[:lower:]')\"" \
      '[ -x "$HOME/.local/bin/claude-panel-launch.sh" ] && "$HOME/.local/bin/claude-panel-launch.sh" "$PIN_SID" &' \
      '# CLAUDE_PANEL_REMOTE_CONTROL (claude-panel options)' 'PANEL_RC_ARGS=()' \
      "rc_opt=\"\$(grep -E '^CLAUDE_PANEL_REMOTE_CONTROL=' \"\$HOME/.config/claude-panel/options\" 2>/dev/null | tail -1)\"" \
      "rc_opt=\"\$(printf '%s' \"\${rc_opt#*=}\" | tr -d \"\\\"' \" | tr '[:upper:]' '[:lower:]')\"" \
      'case "$rc_opt" in true|1|yes|on) PANEL_RC_ARGS=(--remote-control) ;; esac' \
      '# caffeinate -i keeps the Mac awake.' \
      'caffeinate -i "$CLAUDE" --session-id "$PIN_SID" "${PANEL_RC_ARGS[@]}" --dangerously-skip-permissions'
  } > "$bin/ghostty-claude-launcher"

  # sandbox_new SYMLINKS the real claude-day-projection.sh into the sandbox
  # (the panel sources it), so writing a fixture through that name would
  # overwrite the developer's real file. It did, once. Unlink first; the
  # uninstaller then removes a plain file, as it would on a real install.
  local f
  for f in ccusage-panel.sh claude-panel-launch.sh claude-panel-keyblock claude-panel-overlay claude-panel-keysend \
           claude-panel-session-hook.sh claude-cost-alert-check.sh claude-day-projection.sh; do
    rm -f "$bin/$f"
    printf 'x\n' > "$bin/$f"
  done
  printf 'CLAUDE_PANEL_REMOTE_CONTROL=true\n' > "$HOME/.config/claude-panel/options"
  printf 'keybind = ctrl+shift+h=resize_split:left,40\n' > "$HOME/.config/ghostty/config"
  printf '{}\n' > "$HOME/.cache/claude-hourly-buckets.json"

  local snap
  snap() { (cd "$HOME" && find . -type f -o -type d | sort | while read -r p; do
            [ -f "$p" ] && printf '%s %s\n' "$p" "$(cksum < "$p")" || printf '%s\n' "$p"; done); }
  local before; before=$(snap)
  local out rc
  out=$(bash "$u" --dry-run 2>&1); rc=$?
  assert_eq "dry run exits 0" "0" "$rc"
  assert_eq "dry run changes nothing" "$before" "$(snap)"
  assert_contains "dry run lists the launcher" "would: revert the panel's patch" "$out"

  out=$(bash "$u" 2>&1); rc=$?
  assert_eq "uninstall exits 0" "0" "$rc"
  for f in ccusage-panel.sh claude-panel-launch.sh claude-panel-keyblock claude-panel-overlay claude-panel-keysend \
           claude-panel-session-hook.sh claude-cost-alert-check.sh claude-day-projection.sh; do
    assert_eq "$f removed" "gone" "$([ -e "$bin/$f" ] && echo present || echo gone)"
  done
  assert_eq "~/.zshrc is back to the user's own lines" "$(cat "$SBX/zshrc.orig")" "$(cat "$HOME/.zshrc")"
  assert_eq "settings.json keeps only the user's hook" "$(printf '%s' "$mine" | jq -S .)" "$(jq -S . "$HOME/.claude/settings.json")"
  assert_eq "launcher reverted to its unpatched form" "$(cat "$SBX/gcl.orig")" "$(cat "$bin/ghostty-claude-launcher")"
  assert_eq "launcher still executable-free of panel args" "0" "$(grep -c 'PIN_SID\|PANEL_RC_ARGS' "$bin/ghostty-claude-launcher")"
  assert_contains "it warns that Remote Control goes with the launcher patch" "--remote-control" "$out"
  assert_eq "options and caches removed" "gone" \
    "$([ -e "$HOME/.config/claude-panel" ] || [ -e "$HOME/.cache/ccusage-panel-cache" ] || [ -e "$HOME/.cache/claude-hourly-buckets.json" ] && echo present || echo gone)"
  assert_contains "Ghostty keybinds are kept" "resize_split" "$(cat "$HOME/.config/ghostty/config")"
  assert_eq "three backups written" "3" "$(ls "$HOME"/.zshrc.bak-ccusage-uninstall-* "$HOME"/.claude/settings.json.bak-ccusage-uninstall-* "$bin"/ghostty-claude-launcher.bak-ccusage-uninstall-* 2>/dev/null | wc -l | tr -d ' ')"

  local after; after=$(snap)
  out=$(bash "$u" 2>&1); rc=$?
  assert_eq "second run exits 0" "0" "$rc"
  assert_eq "second run changes nothing" "$after" "$(snap)"
  assert_contains "second run says so" "nothing to remove" "$out"

  # A hand-edited block (start marker, no end) is left alone, not truncated.
  printf '%s\n' "# --- ccusage split-panel autolaunch (installed by claude-panel-setup.sh) ---" "mine" > "$HOME/.zshrc"
  out=$(bash "$u" 2>&1)
  assert_eq "a block with no end marker is left as-is" "2" "$(wc -l < "$HOME/.zshrc" | tr -d ' ')"
  assert_contains "and it warns" "no end marker" "$out"
}
