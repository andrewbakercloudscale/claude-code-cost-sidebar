# Check A -- which path the launcher takes is decided by whether an
# interpreter can actually post key events, and PANEL_KEYSEND_PYTHON can turn
# the targeted path off.
#
# That last part is what makes the AppleScript fallback reachable at all on a
# machine that HAS pyobjc, which is every machine this was developed on. If
# the override were merely first in the search order, the search would find
# Homebrew's python anyway, the fallback would never run again here, and it
# would rot silently -- exactly the failure this repo keeps paying for.
check_A_path_selection() {
  import_fn find_quartz_python || return 1

  # No override: pick whatever on this machine can post events. Either answer
  # is legitimate -- the point is that the probe RUNS the import rather than
  # assuming a path exists.
  local picked; picked=$(PANEL_KEYSEND_PYTHON="" find_quartz_python) || picked=""
  if [ -n "$picked" ]; then
    assert_eq "an interpreter it picked can really import Quartz" "0" \
      "$("$picked" -c 'import Quartz' 2>/dev/null; echo $?)"
  else
    # A machine with no pyobjc anywhere. Then the fallback is the only path,
    # which is correct and is itself the assertion.
    assert_eq "with no pyobjc anywhere, no interpreter is claimed" "" "$picked"
  fi

  # Override that cannot post events: the search must STOP, not shop around.
  local out rc
  out=$(PANEL_KEYSEND_PYTHON=/usr/bin/python3 find_quartz_python); rc=$?
  if /usr/bin/python3 -c 'import Quartz' 2>/dev/null; then
    assert_eq "stock python3 has Quartz here, so it is accepted" "0" "$rc"
  else
    assert_eq "an override without Quartz is refused, not worked around" "1" "$rc"
    assert_eq "and names no interpreter" "" "$out"
  fi

  # Override that does not exist at all: same answer, no fallthrough.
  out=$(PANEL_KEYSEND_PYTHON=/nonexistent/python3 find_quartz_python); rc=$?
  assert_eq "a missing override is refused rather than ignored" "1" "$rc"
  assert_eq "and names no interpreter either" "" "$out"

  # The launcher must actually consult it, not just define it.
  assert_contains "the launcher calls the probe" "find_quartz_python" \
    "$(cat "$LAUNCH_SH")"
  assert_contains "and logs which path it took, so a bare log explains itself" \
    "focus-dependent AppleScript path" "$(cat "$LAUNCH_SH")"
}
