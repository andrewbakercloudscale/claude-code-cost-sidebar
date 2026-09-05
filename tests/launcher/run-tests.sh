#!/usr/bin/env bash
# Test runner for the launcher's path selection.
#
#   bash tests/launcher/run-tests.sh
#   LAUNCH_SH=/path/to/claude-panel-launch.sh bash tests/launcher/run-tests.sh
#
# Scope is deliberately narrow. Driving Ghostty through the Accessibility API
# is not something a hermetic check can do, so what is covered is the part
# that DECIDES which of the two paths runs, plus the helper's contract with
# the launcher. That decision is the whole reason the fallback exists, and an
# untested fallback is one that has stopped working without anyone noticing.
#
# Same two rules as the other suites: gate on exit codes, and fail a check
# that ran zero assertions.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
export LAUNCH_SH="${LAUNCH_SH:-$HOME/.local/bin/claude-panel-launch.sh}"
export KEYSEND="${KEYSEND:-$HOME/.local/bin/claude-panel-keysend}"
for f in "$LAUNCH_SH" "$KEYSEND"; do
  [ -f "$f" ] || { printf 'missing: %s\n' "$f" >&2; exit 2; }
done

ASSERTIONS=0
_pass() { ASSERTIONS=$(( ASSERTIONS + 1 )); }
_fail() {
  ASSERTIONS=$(( ASSERTIONS + 1 )); FAILED=1
  printf '    FAIL: %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3" >&2
}
assert_eq() { [ "$2" = "$3" ] && _pass || _fail "$1" "$2" "$3"; }
assert_contains() { case "$3" in *"$2"*) _pass ;; *) _fail "$1" "contains '$2'" "$3" ;; esac; }

# Pull one function out of the launcher and define it here. The launcher is a
# script that runs on source, not a library, so there is no seam to import --
# and adding one purely for tests would change the thing under test.
import_fn() { # $1 = function name
  local body
  body=$(awk -v f="$1" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^\}$/ {exit}' "$LAUNCH_SH")
  [ -n "$body" ] || { printf 'could not extract %s from %s\n' "$1" "$LAUNCH_SH" >&2; return 1; }
  eval "$body"
}

# One `source` per file. `source "$HERE"/checks/*.sh` sources only the FIRST
# match and passes the rest as positional arguments -- which silently ran one
# of two checks here while the header still announced two.
for f in "$HERE"/checks/*.sh; do source "$f"; done

CHECK_FILES=$(ls "$HERE"/checks/*.sh | wc -l | tr -d ' ')
CHECK_FNS=$(declare -F | awk '{print $3}' | grep -c '^check_')
printf 'launcher: %s\n' "$LAUNCH_SH"
printf 'checks:   %s\n\n' "$CHECK_FNS"
# A file that defines no check, or a check that failed to load, is invisible
# unless the two numbers are compared. They were not, and one of two checks
# silently did not run.
if [ "$CHECK_FILES" -ne "$CHECK_FNS" ]; then
  printf '%s check FILES but %s check FUNCTIONS loaded -- a check is not running\n' \
    "$CHECK_FILES" "$CHECK_FNS" >&2
  exit 2
fi

TOTAL=0; FAILED_CHECKS=0; RUN=0
for fn in $(declare -F | awk '{print $3}' | grep '^check_' | sort); do
  ASSERTIONS=0; FAILED=0
  "$fn"; status=$?
  RUN=$(( RUN + 1 )); TOTAL=$(( TOTAL + ASSERTIONS ))
  if [ "$ASSERTIONS" -eq 0 ]; then
    printf '  %-30s NO ASSERTIONS RAN -- this check is covering nothing\n' "$fn"
    FAILED_CHECKS=$(( FAILED_CHECKS + 1 ))
  elif [ "$FAILED" -ne 0 ] || [ "$status" -ne 0 ]; then
    printf '  %-30s FAIL (%d assertions)\n' "$fn" "$ASSERTIONS"
    FAILED_CHECKS=$(( FAILED_CHECKS + 1 ))
  else
    printf '  %-30s ok   (%d assertions)\n' "$fn" "$ASSERTIONS"
  fi
done

printf '\n%d checks, %d assertions, %d failed\n' "$RUN" "$TOTAL" "$FAILED_CHECKS"
[ "$FAILED_CHECKS" -eq 0 ]
