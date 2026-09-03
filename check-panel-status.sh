#!/usr/bin/env bash
# Read-only diagnostic: reports what claude-panel-setup.sh has installed on
# this machine and whether it's currently running, without changing
# anything. Mirrors the claude-burst repo's `transparent-root.sh status` --
# same reasoning: a checked-in diagnostic script beats re-typing the same
# greps/ps checks ad hoc every time something needs troubleshooting.
#
# Usage: bash check-panel-status.sh
set -uo pipefail

ZSHRC="$HOME/.zshrc"
GHOSTTY_CONF="$HOME/.config/ghostty/config"
SETTINGS="$HOME/.claude/settings.json"
ZSHRC_MARKER="# --- ccusage split-panel autolaunch"
ALERT_CMD="~/.local/bin/claude-cost-alert-check.sh"

main() {
  echo "== generated files (~/.local/bin) =="
  check_file "ccusage-panel.sh"
  check_file "claude-panel-launch.sh"
  check_file "claude-panel-keyblock"
  check_file "claude-cost-alert-check.sh"

  echo
  echo "== ~/.zshrc autolaunch hook =="
  if [[ -f "$ZSHRC" ]] && grep -qF "$ZSHRC_MARKER" "$ZSHRC"; then
    echo "present"
  else
    echo "absent"
  fi

  echo
  echo "== ~/.config/ghostty/config resize_split keybinds =="
  if [[ -f "$GHOSTTY_CONF" ]] && grep -qF "keybind = ctrl+shift+h=resize_split:left,40" "$GHOSTTY_CONF"; then
    echo "present"
  else
    echo "absent (or no ghostty config file)"
  fi

  echo
  echo "== ~/.claude/settings.json cost-alert hook (UserPromptSubmit) =="
  if [[ -f "$SETTINGS" ]] && grep -qF "$ALERT_CMD" "$SETTINGS"; then
    echo "present"
  else
    echo "absent"
  fi

  echo
  echo "== running processes =="
  check_process "ccusage-panel.sh"
  check_process "claude-panel-launch.sh"
  check_process "claude-panel-keyblock"

  echo
  echo "== recent launch log (last 5 lines, if any) =="
  if [[ -f "$HOME/.cache/claude-panel-launch.log" ]]; then
    tail -5 "$HOME/.cache/claude-panel-launch.log"
  else
    echo "no log at ~/.cache/claude-panel-launch.log"
  fi
}

check_file() {
  local name="$1" path="$HOME/.local/bin/$1"
  if [[ -e "$path" ]]; then
    echo "$name: present ($(date -r "$path" '+%Y-%m-%d %H:%M:%S'))"
  else
    echo "$name: absent"
  fi
}

check_process() {
  local name="$1"
  local pids
  pids="$(pgrep -f "/$name" 2>/dev/null | tr '\n' ' ')"
  if [[ -n "$pids" ]]; then
    echo "$name: running (pid $pids)"
  else
    echo "$name: not running"
  fi
}

main "$@"
