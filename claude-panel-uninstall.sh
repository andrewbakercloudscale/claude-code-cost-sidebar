#!/usr/bin/env bash
# Removes what claude-panel-setup.sh installed, and nothing else.
#
#   bash claude-panel-uninstall.sh            # remove
#   bash claude-panel-uninstall.sh --dry-run  # list what would change
#
# Standalone: it needs no checkout of this repo, only bash, awk and jq (jq
# only when ~/.claude/settings.json exists). Idempotent: a second run finds
# nothing to do and says so. Every file it edits rather than deletes
# (~/.zshrc, ~/.claude/settings.json, ~/.local/bin/ghostty-claude-launcher)
# is backed up beside itself first, and an edit it cannot make safely (a
# hand-edited block, an unfamiliar launcher) is left alone with a warning.
#
# Left in place on purpose: the Ghostty resize_split keybinds (harmless, and
# they may predate the panel).
set -u

DRY=0
case "${1:-}" in
  --dry-run|-n) DRY=1 ;;
  "") ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

TS="$(date +%Y%m%d-%H%M%S)"
BIN="$HOME/.local/bin"
FAILED=0
CHANGED=0

say()  { if [ "$DRY" = 1 ]; then echo "would: $*"; else echo "$*"; fi; }
warn() { echo "WARNING: $*" >&2; }
fail() { echo "ERROR: $*" >&2; FAILED=1; }

remove_path() { # path, label
  [ -e "$1" ] || [ -L "$1" ] || return 0
  CHANGED=1
  say "remove $2"
  [ "$DRY" = 1 ] && return 0
  rm -rf "$1" || fail "could not remove $1"
}

# --- scripts and helpers in ~/.local/bin ---------------------------------
for f in ccusage-panel.sh .ccusage-panel.sh.new claude-panel-launch.sh claude-panel-keyblock claude-panel-overlay \
         claude-panel-keysend claude-panel-session-hook.sh claude-cost-alert-check.sh \
         claude-day-projection.sh; do
  remove_path "$BIN/$f" "~/.local/bin/$f"
done

# --- ~/.zshrc autolaunch block -------------------------------------------
ZSHRC="$HOME/.zshrc"
START="# --- ccusage split-panel autolaunch"
END="# --- end ccusage split-panel autolaunch ---"
if [ -f "$ZSHRC" ] && grep -qF "$START" "$ZSHRC"; then
  if ! grep -qxF "$END" "$ZSHRC"; then
    warn "~/.zshrc has the panel's autolaunch block but no end marker (hand-edited?); left as-is, remove it yourself"
  else
    CHANGED=1
    say "remove the autolaunch block from ~/.zshrc (backup ~/.zshrc.bak-ccusage-uninstall-$TS)"
    if [ "$DRY" = 0 ]; then
      new="$(mktemp)"
      # The block starts at a line BEGINNING with the start marker (a comment
      # elsewhere may mention it mid-line), and setup put one blank line
      # before it, which goes too.
      awk -v start="$START" -v end="$END" '
        index($0, start) == 1 { skip = 1; if (held) held = 0; next }
        skip { if ($0 == end) skip = 0; next }
        { if (held) print ""; held = 0 }
        $0 == "" { held = 1; next }
        { print }
        END { if (held) print "" }
      ' "$ZSHRC" > "$new" \
        && cp "$ZSHRC" "$ZSHRC.bak-ccusage-uninstall-$TS" \
        && cat "$new" > "$ZSHRC" \
        || fail "could not edit ~/.zshrc"
      rm -f "$new"
    fi
  fi
fi

# --- ~/.claude/settings.json hooks ---------------------------------------
SETTINGS="$HOME/.claude/settings.json"
HOOKS_FILTER='
  def strip:
    map(.hooks = [(.hooks // [])[] | select(.command != $a and .command != $s)])
    | map(select((.hooks | length) > 0));
  if (.hooks | type) == "object" then
    .hooks |= (with_entries(.value |= strip) | with_entries(select((.value | length) > 0)))
    | if (.hooks | length) == 0 then del(.hooks) else . end
  else . end'
if [ -f "$SETTINGS" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    fail "jq is needed to remove the panel's hooks from ~/.claude/settings.json"
  else
    new="$(mktemp)"
    if jq --arg a "~/.local/bin/claude-cost-alert-check.sh" --arg s "~/.local/bin/claude-panel-session-hook.sh" \
         "$HOOKS_FILTER" "$SETTINGS" > "$new" 2>/dev/null; then
      if ! jq -e --slurpfile b "$new" '. == $b[0]' "$SETTINGS" >/dev/null 2>&1; then
        CHANGED=1
        say "remove the panel's SessionStart and UserPromptSubmit hooks from ~/.claude/settings.json (backup ~/.claude/settings.json.bak-ccusage-uninstall-$TS)"
        if [ "$DRY" = 0 ]; then
          cp "$SETTINGS" "$SETTINGS.bak-ccusage-uninstall-$TS" && cat "$new" > "$SETTINGS" \
            || fail "could not edit ~/.claude/settings.json"
        fi
      fi
    else
      warn "~/.claude/settings.json is not valid JSON; left as-is"
    fi
    rm -f "$new"
  fi
fi

# --- ~/.local/bin/ghostty-claude-launcher patch --------------------------
GCL="$BIN/ghostty-claude-launcher"
if [ -f "$GCL" ] && grep -qE 'claude-panel-launch\.sh|PANEL_RC_ARGS|PANEL_BYPASS_ARGS|--session-id "\$PIN_SID"' "$GCL"; then
  new="$(mktemp)"
  # 1. setup's comment block, from its marker through the launch line, and
  #    the blank line setup put before it; 2. the Remote Control snippet;
  #    3. the bypass snippet, from its marker through its esac, remembering
  #    whether the launcher had --dangerously-skip-permissions before setup
  #    made it an option; 4. the arguments setup added to the "$CLAUDE" line,
  #    putting that flag back where it was.
  awk '
    index($0, "# Auto-open the live ccusage stats panel") == 1 { skip = 1; held = 0; next }
    skip { if (index($0, "claude-panel-launch.sh\" \"$PIN_SID\" &") > 0) skip = 0; next }
    $0 == "# CLAUDE_PANEL_BYPASS_PERMISSIONS (claude-panel options)" { inbp = 1; next }
    inbp {
      if ($0 == "PANEL_BYPASS_ARGS=(--dangerously-skip-permissions)") bpflag = 1
      if ($0 == "esac") inbp = 0
      next
    }
    $0 == "# CLAUDE_PANEL_REMOTE_CONTROL (claude-panel options)" { next }
    $0 == "PANEL_RC_ARGS=()" { next }
    index($0, "rc_opt=\"$(grep -E '"'"'^CLAUDE_PANEL_REMOTE_CONTROL='"'"'") == 1 { next }
    index($0, "rc_opt=\"$(printf '"'"'%s'"'"' \"${rc_opt#*=}\"") == 1 { next }
    index($0, "case \"$rc_opt\" in true|1|yes|on) PANEL_RC_ARGS=(--remote-control) ;; esac") == 1 { next }
    {
      gsub(/ "\$\{PANEL_RC_ARGS\[@\]\}"/, "")
      gsub(/ "\$\{PANEL_BYPASS_ARGS\[@\]\}"/, bpflag ? " --dangerously-skip-permissions" : "")
      gsub(/ --session-id "\$PIN_SID"/, "")
      if (held) print ""
      held = 0
    }
    $0 == "" { held = 1; next }
    { print }
    END { if (held) print "" }
  ' "$GCL" > "$new"
  if grep -qE 'PIN_SID|PANEL_RC_ARGS|PANEL_BYPASS_ARGS|claude-panel|rc_opt|bp_opt' "$new"; then
    warn "~/.local/bin/ghostty-claude-launcher does not match the shape setup patched (hand-edited?); left as-is"
  else
    CHANGED=1
    say "revert the panel's patch to ~/.local/bin/ghostty-claude-launcher (backup ~/.local/bin/ghostty-claude-launcher.bak-ccusage-uninstall-$TS)"
    echo "NOTE: this also removes the launcher's --remote-control option (CLAUDE_PANEL_REMOTE_CONTROL). Sessions it starts will no longer have Remote Control unless you add --remote-control to it yourself."
    if [ "$DRY" = 0 ]; then
      cp -p "$GCL" "$GCL.bak-ccusage-uninstall-$TS" && cat "$new" > "$GCL" \
        || fail "could not edit ~/.local/bin/ghostty-claude-launcher"
    fi
  fi
  rm -f "$new"
fi

# --- options, caches and logs --------------------------------------------
remove_path "$HOME/.config/claude-panel" "~/.config/claude-panel (options, including CLAUDE_PANEL_REMOTE_CONTROL)"
for p in ccusage-panel-cache claude-panel-pin claude-panel-pin.log claude-panel-launch.log \
         claude-hourly-buckets.json claude-cost-alert-state claude-cost-alert-telegram.log; do
  remove_path "$HOME/.cache/$p" "~/.cache/$p"
done

if grep -qs "resize_split" "$HOME/.config/ghostty/config"; then
  echo "kept: the resize_split keybinds in ~/.config/ghostty/config (harmless; remove them yourself if you like)"
fi

if [ "$FAILED" = 1 ]; then
  echo "uninstall incomplete: see the errors above" >&2
  exit 1
fi
if [ "$CHANGED" = 0 ]; then
  echo "nothing to remove: the usage panel is not installed"
elif [ "$DRY" = 1 ]; then
  echo "dry run: nothing changed"
else
  echo "usage panel removed. Panels already open keep running until their split is closed."
fi
