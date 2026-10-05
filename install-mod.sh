#!/bin/zsh
# Installs, updates or removes the usage-panel Claude Code mod (mods/usage-panel):
# this panel in a sidebar inside each Claude Code session, in place of the
# Ghostty split. Called by claude-panel-setup.sh, so every deploy updates it.
#
# While it is installed, ~/.config/claude-panel/mod-installed exists and the
# split launcher stands aside (CLAUDE_PANEL_SPLIT=true brings the split back).
#
# Claude Code keeps an installed plugin as a copy, cached by version, so an
# edit to the mod never reaches a session by itself. This compares the copy
# with the source and reinstalls when they differ, whatever the version says.
# New sessions pick it up; running ones keep the copy they loaded.
#
# CLAUDE_PANEL_MOD=no skips it. Never fails its caller: the mod is optional,
# so any problem is a warning and exit 0.
#
# Usage: update-mod.sh [install|uninstall]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/mods/usage-panel"
PLUGIN="usage-panel@ccusage-panel"
MIN_VERSION="2.1.287" # the first Claude Code that loads mods
MARKER="$HOME/.config/claude-panel/mod-installed"
installed() { mkdir -p "$(dirname "$MARKER")" && date '+%Y-%m-%d %H:%M:%S' > "$MARKER"; }
CLAUDE="${CLAUDE_BIN:-$(command -v claude 2>/dev/null)}"

say() { echo "usage-panel mod: $*"; }
warn() { echo "WARNING: usage-panel mod: $*" >&2; }

if [[ -z "$CLAUDE" || ! -x "$CLAUDE" ]]; then
  say "Claude Code not found, skipped"
  exit 0
fi

# What Claude Code loads: the manifest and the hooks module. Tests and local
# state (.omc) are not part of it.
mod_hash() { # $1 = plugin dir
  [[ -d "$1/hooks" ]] || { echo none; return; }
  (cd "$1" && cat .claude-plugin/plugin.json hooks/*(.N) 2>/dev/null) | shasum -a 256 | cut -c1-16
}

installed_path() {
  "$CLAUDE" plugin list --json 2>/dev/null | python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in rows if isinstance(rows, list) else []:
    if r.get("id") == "'"$PLUGIN"'":
        print(r.get("installPath", ""))
'
}

case "${1:-install}" in
  uninstall)
    if [[ -n "$(installed_path)" ]]; then
      "$CLAUDE" plugin uninstall "$PLUGIN" >/dev/null 2>&1 || warn "could not uninstall; run: claude plugin uninstall $PLUGIN"
      say "removed"
    fi
    rm -f "$MARKER"
    "$CLAUDE" plugin marketplace remove ccusage-panel >/dev/null 2>&1
    exit 0
    ;;
  install) ;;
  *) echo "Usage: $0 [install|uninstall]" >&2; exit 2 ;;
esac

if [[ "${CLAUDE_PANEL_MOD:-yes}" == "no" ]]; then
  say "CLAUDE_PANEL_MOD=no, skipped"
  rm -f "$MARKER"
  exit 0
fi
version="$("$CLAUDE" --version 2>/dev/null | awk '{print $1}')"
if [[ "$(printf '%s\n%s\n' "$MIN_VERSION" "$version" | sort -V | head -1)" != "$MIN_VERSION" ]]; then
  say "Claude Code $version is older than $MIN_VERSION, which mods need; skipped"
  rm -f "$MARKER"
  exit 0
fi

current="$(installed_path)"
if [[ -n "$current" && "$(mod_hash "$current")" == "$(mod_hash "$SRC")" ]]; then
  say "up to date"
  installed
  exit 0
fi

# The marketplace is this checkout; adding it again is a no-op.
if ! "$CLAUDE" plugin marketplace list 2>/dev/null | grep -qE '❯ ccusage-panel$'; then
  "$CLAUDE" plugin marketplace add "$ROOT" >/dev/null 2>&1 || { warn "could not add the marketplace in $ROOT"; exit 0; }
else
  "$CLAUDE" plugin marketplace update ccusage-panel >/dev/null 2>&1
fi
if [[ -n "$current" ]]; then
  "$CLAUDE" plugin uninstall "$PLUGIN" >/dev/null 2>&1
fi
if ! "$CLAUDE" plugin install "$PLUGIN" >/dev/null 2>&1; then
  warn "install failed; run: claude plugin install $PLUGIN"
  exit 0
fi
now="$(installed_path)"
if [[ -z "$now" || "$(mod_hash "$now")" != "$(mod_hash "$SRC")" ]]; then
  warn "installed, but the installed copy does not match $SRC"
  exit 0
fi
installed
msg=installed
[[ -n "$current" ]] && msg=updated
say "$msg; new Claude Code sessions load it"
exit 0
