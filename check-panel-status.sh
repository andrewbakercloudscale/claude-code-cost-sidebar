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
CREDS_FILE="$HOME/Desktop/github/.creds"
TG_LOG="$HOME/.cache/claude-cost-alert-telegram.log"

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
  echo "== cost-alert phone push (Telegram) =="
  # The one channel whose breakage is silent: a missing token means no push,
  # and no push is indistinguishable from no overspend. Report it here so it
  # is visible without waiting for an alert that never comes.
  if [[ "${CLAUDE_COST_ALERT_TELEGRAM:-1}" == "0" ]]; then
    echo "disabled (CLAUDE_COST_ALERT_TELEGRAM=0)"
  elif [[ -f "$CREDS_FILE" ]] && grep -q "TELEGRAM_BOT_TOKEN" "$CREDS_FILE" \
       && grep -q "TELEGRAM_CHAT_ID" "$CREDS_FILE"; then
    echo "configured (credentials in ~/Desktop/github/.creds)"
    if [[ -s "$TG_LOG" ]]; then
      echo "  WARNING: $(wc -l < "$TG_LOG" | tr -d ' ') failed send(s) logged:"
      tail -3 "$TG_LOG" | sed 's/^/    /'
    else
      echo "  no send failures logged"
    fi
  else
    echo "NOT configured -- overspend will not reach your phone"
    echo "  (needs TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in ~/Desktop/github/.creds)"
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
