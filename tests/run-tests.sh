#!/usr/bin/env bash
# Test runner for ccusage-panel.sh.
#
#   bash tests/run-tests.sh                 # test the installed panel
#   PANEL_SH=/path/to/panel.sh bash tests/run-tests.sh
#
# Exits non-zero if any check fails OR if any check ran zero assertions. The
# second condition matters as much as the first: a check that has quietly
# stopped covering anything reports "ok" forever and stops you looking.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
export PANEL_SH="${PANEL_SH:-$HOME/.local/bin/ccusage-panel.sh}"

if [ ! -f "$PANEL_SH" ]; then
  printf 'no panel to test at %s\n' "$PANEL_SH" >&2
  exit 2
fi
for dep in jq shasum python3; do
  command -v "$dep" >/dev/null 2>&1 || { printf 'missing dependency: %s\n' "$dep" >&2; exit 2; }
done

# The stub goes first on PATH so no check can accidentally scan the real
# 653MB corpus -- which would be slow, non-deterministic, and would make the
# invocation counts meaningless.
export PATH="$HERE/stub:$PATH"
export TEST_TMP="${TMPDIR:-/tmp}/ccusage-panel-tests.$$"
mkdir -p "$TEST_TMP"
REAL_HOME="$HOME"
trap 'HOME="$REAL_HOME"; rm -rf "$TEST_TMP"' EXIT

source "$HERE/lib/harness.sh"
for f in "$HERE"/checks/*.sh; do source "$f"; done

printf 'panel:  %s\n' "$PANEL_SH"
printf 'checks: %s\n\n' "$(ls "$HERE"/checks/*.sh | wc -l | tr -d ' ')"

TOTAL_ASSERTIONS=0
FAILED_CHECKS=0
RUN_CHECKS=0

for fn in $(declare -F | awk '{print $3}' | grep '^check_' | sort); do
  ASSERTIONS=0
  FAILED=0
  ( exit 0 )
  "$fn"
  status=$?
  RUN_CHECKS=$(( RUN_CHECKS + 1 ))
  TOTAL_ASSERTIONS=$(( TOTAL_ASSERTIONS + ASSERTIONS ))

  if [ "$ASSERTIONS" -eq 0 ]; then
    printf '  %-28s NO ASSERTIONS RAN -- this check is covering nothing\n' "$fn"
    FAILED_CHECKS=$(( FAILED_CHECKS + 1 ))
  elif [ "$FAILED" -ne 0 ] || [ "$status" -ne 0 ]; then
    printf '  %-28s FAIL (%d assertions)\n' "$fn" "$ASSERTIONS"
    FAILED_CHECKS=$(( FAILED_CHECKS + 1 ))
  else
    printf '  %-28s ok   (%d assertions)\n' "$fn" "$ASSERTIONS"
  fi
  HOME="$REAL_HOME"
done

printf '\n%d checks, %d assertions, %d failed\n' \
  "$RUN_CHECKS" "$TOTAL_ASSERTIONS" "$FAILED_CHECKS"
[ "$FAILED_CHECKS" -eq 0 ]
