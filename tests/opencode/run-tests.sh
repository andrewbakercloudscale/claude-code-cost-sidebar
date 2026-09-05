#!/usr/bin/env bash
# Test runner for opencode-panel.sh. Same two rules as ccusage-panel's suite:
# gate on exit codes never on absent output, and fail any check that ran zero
# assertions -- a gate covering nothing must be visible, not reassuring.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export PANEL_SH="${PANEL_SH:-$HOME/.local/bin/opencode-panel.sh}"
[ -f "$PANEL_SH" ] || { printf 'no panel to test at %s\n' "$PANEL_SH" >&2; exit 2; }
for dep in jq shasum; do command -v "$dep" >/dev/null || { echo "missing $dep" >&2; exit 2; }; done

export PATH="$HERE/stub:$PATH"
export TEST_TMP="${TMPDIR:-/tmp}/opencode-panel-tests.$$"
mkdir -p "$TEST_TMP"
REAL_HOME="$HOME"
trap 'HOME="$REAL_HOME"; rm -rf "$TEST_TMP"' EXIT

ASSERTIONS=0; FAILED=0
_pass() { ASSERTIONS=$(( ASSERTIONS + 1 )); }
_fail() { ASSERTIONS=$(( ASSERTIONS + 1 )); printf '    FAIL: %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3" >&2; FAILED=1; }
assert_eq() { [ "$2" = "$3" ] && _pass || _fail "$1" "$2" "$3"; }
assert_ne() { [ "$2" != "$3" ] && _pass || _fail "$1" "not $2" "$3"; }

sandbox_new() { # $1 name
  SBX="$TEST_TMP/$1"; rm -rf "$SBX"
  mkdir -p "$SBX/home/.local/share/opencode" "$SBX/fixtures"
  export HOME="$SBX/home"
  export OC_FIXTURE_DIR="$SBX/fixtures"
  export OC_CALL_LOG="$SBX/calls.log"; : > "$OC_CALL_LOG"
  # A "database" old enough that the gate has something to compare against.
  : > "$HOME/.local/share/opencode/opencode.db"
  touch -t "$(date -v-1H +%Y%m%d%H%M.%S)" "$HOME/.local/share/opencode/opencode.db"
  printf '{"sessions":[]}\n' > "$OC_FIXTURE_DIR/session-list.json"
  printf '{}\n' > "$OC_FIXTURE_DIR/stats-1.json"
  printf '{}\n' > "$OC_FIXTURE_DIR/stats-7.json"
  printf '{}\n' > "$OC_FIXTURE_DIR/stats-30.json"
  printf '{"info":{},"messages":[]}\n' > "$OC_FIXTURE_DIR/export.json"
}
calls_for() { grep -c "^$1" "$OC_CALL_LOG" 2>/dev/null || true; }
load_panel() { PANEL_LIB_ONLY=1 source "$PANEL_SH" "$@" </dev/null; }
# Same-second races are real: a cache file written and the db "touched" in
# the same wall-clock second tie under -newer, which only checks for
# strictly-greater mtime. Nudge the db a few seconds into the future rather
# than to "now" so this is never a coin flip.
touch_db() { touch -t "$(date -v+5S +%Y%m%d%H%M.%S)" "$HOME/.local/share/opencode/opencode.db"; }

for f in "$HERE"/checks/*.sh; do source "$f"; done

printf 'panel:  %s\n' "$PANEL_SH"
printf 'checks: %s\n\n' "$(ls "$HERE"/checks/*.sh | wc -l | tr -d ' ')"
TOTAL=0; FAILED_CHECKS=0; RUN=0
for fn in $(declare -F | awk '{print $3}' | grep '^check_' | sort); do
  ASSERTIONS=0; FAILED=0
  "$fn"
  RUN=$(( RUN + 1 )); TOTAL=$(( TOTAL + ASSERTIONS ))
  if [ "$ASSERTIONS" -eq 0 ]; then
    printf '  %-28s NO ASSERTIONS RAN\n' "$fn"; FAILED_CHECKS=$(( FAILED_CHECKS + 1 ))
  elif [ "$FAILED" -ne 0 ]; then
    printf '  %-28s FAIL (%d assertions)\n' "$fn" "$ASSERTIONS"; FAILED_CHECKS=$(( FAILED_CHECKS + 1 ))
  else
    printf '  %-28s ok   (%d assertions)\n' "$fn" "$ASSERTIONS"
  fi
  HOME="$REAL_HOME"
done
printf '\n%d checks, %d assertions, %d failed\n' "$RUN" "$TOTAL" "$FAILED_CHECKS"
[ "$FAILED_CHECKS" -eq 0 ]
