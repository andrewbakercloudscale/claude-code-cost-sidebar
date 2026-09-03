#!/usr/bin/env bash
# Undoes everything claude-panel-setup.sh wires up. Mirrors the pattern in
# the claude-burst repo's rollback.sh/ROLLBACK.md: back up first, remove each
# piece independently, safe to run repeatedly or when nothing was installed.
#
# What this undoes:
#   - the preexec autolaunch hook in ~/.zshrc
#   - the UserPromptSubmit cost-alert hook in ~/.claude/settings.json
#   - the two resize_split keybinds in ~/.config/ghostty/config
#   - any running panel/launcher/keyblock process
#
# What this deliberately leaves alone:
#   - the generated scripts in ~/.local/bin (ccusage-panel.sh,
#     claude-panel-launch.sh, claude-panel-keyblock,
#     claude-cost-alert-check.sh) -- inert on disk with nothing left to
#     invoke them, and install-cost-panel.sh overwrites them again on the
#     next install anyway
#   - a patched ~/.local/bin/ghostty-claude-launcher (Finder Service path) --
#     rewriting that needs the installer's own template, not a targeted
#     removal; rerun install-cost-panel.sh afterward to refresh it
#
# Usage: bash rollback-cost-panel.sh
set -uo pipefail

ZSHRC="$HOME/.zshrc"
GHOSTTY_CONF="$HOME/.config/ghostty/config"
SETTINGS="$HOME/.claude/settings.json"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$HOME/.config/claude-panel-setup/backups"
ZSHRC_BEGIN="# --- ccusage split-panel autolaunch (installed by claude-panel-setup.sh) ---"
ZSHRC_END="# --- end ccusage split-panel autolaunch ---"
ALERT_CMD="~/.local/bin/claude-cost-alert-check.sh"

main() {
  mkdir -p "$BACKUP_DIR"

  echo "== 1. stopping any running panel/launcher processes =="
  stop_process '/ccusage-panel\.sh' "ccusage-panel.sh"
  stop_process '/claude-panel-launch\.sh' "claude-panel-launch.sh"
  stop_process '/claude-panel-keyblock' "claude-panel-keyblock"

  echo
  echo "== 2. removing the ~/.zshrc autolaunch hook =="
  remove_zshrc_block

  echo
  echo "== 3. removing the resize_split keybinds from ghostty config =="
  remove_ghostty_keybinds

  echo
  echo "== 4. removing the cost-alert hook from settings.json =="
  remove_settings_hook

  echo
  echo "rollback complete. Panel scripts remain in ~/.local/bin (inert, nothing left to invoke them)."
  echo "Re-install any time with: bash install-cost-panel.sh"
}

stop_process() {
  local pattern="$1" label="$2"
  if pkill -f "$pattern" 2>/dev/null; then
    echo "stopped $label"
  else
    echo "$label not running"
  fi
}

remove_zshrc_block() {
  if [[ -f "$ZSHRC" ]] && grep -qF "$ZSHRC_BEGIN" "$ZSHRC"; then
    cp "$ZSHRC" "$BACKUP_DIR/zshrc.$TS.bak"
    awk -v b="$ZSHRC_BEGIN" -v e="$ZSHRC_END" '
      $0==b {skip=1}
      skip!=1 {print}
      $0==e {skip=0}
    ' "$ZSHRC" > "$ZSHRC.tmp.$$" && mv "$ZSHRC.tmp.$$" "$ZSHRC"
    echo "removed autolaunch block from $ZSHRC (backup: $BACKUP_DIR/zshrc.$TS.bak)"
  else
    echo "no autolaunch block present in $ZSHRC"
  fi
}

remove_ghostty_keybinds() {
  if [[ -f "$GHOSTTY_CONF" ]] && grep -qF "keybind = ctrl+shift+h=resize_split:left,40" "$GHOSTTY_CONF"; then
    cp "$GHOSTTY_CONF" "$BACKUP_DIR/ghostty-config.$TS.bak"
    grep -vF \
      -e "keybind = ctrl+shift+h=resize_split:left,40" \
      -e "keybind = ctrl+shift+l=resize_split:right,40" \
      "$GHOSTTY_CONF" > "$GHOSTTY_CONF.tmp.$$" && mv "$GHOSTTY_CONF.tmp.$$" "$GHOSTTY_CONF"
    echo "removed resize_split keybinds from $GHOSTTY_CONF (backup: $BACKUP_DIR/ghostty-config.$TS.bak)"
  else
    echo "no resize_split keybinds present in $GHOSTTY_CONF"
  fi
}

remove_settings_hook() {
  if [[ ! -f "$SETTINGS" ]]; then
    echo "no $SETTINGS -- nothing to do"
    return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq not found -- cannot safely edit $SETTINGS, skipping" >&2
    return
  fi
  if ! grep -qF "$ALERT_CMD" "$SETTINGS"; then
    echo "no cost-alert hook present in $SETTINGS"
    return
  fi
  cp "$SETTINGS" "$BACKUP_DIR/settings.json.$TS.bak"
  jq --arg cmd "$ALERT_CMD" '
    .hooks //= {} |
    .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) | map(select((.hooks // []) | any(.command == $cmd) | not))) |
    if (.hooks.UserPromptSubmit | length) == 0 then del(.hooks.UserPromptSubmit) else . end
  ' "$SETTINGS" > "$SETTINGS.tmp.$$" && mv "$SETTINGS.tmp.$$" "$SETTINGS"
  echo "removed the cost-alert hook from $SETTINGS (backup: $BACKUP_DIR/settings.json.$TS.bak)"
}

main "$@"
