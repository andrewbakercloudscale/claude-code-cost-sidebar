# Check B -- the helper's contract with the launcher.
#
# The launcher branches on this program's exit code, so the codes are the
# interface, not an implementation detail. Exit 2 in particular is what makes
# the launcher fall through to the AppleScript path instead of leaving the
# window with no panel.
#
# What is NOT asserted: that keystrokes arrive. That needs a real window, a
# real Accessibility grant and a real Ghostty, and faking any of them would
# assert the fake. It was verified by hand instead -- panel launched into a
# deliberately UNFOCUSED window, confirmed by the resulting panel process's
# own ancestry, with focus checked before and after.
check_B_keysend_contract() {
  local py rc out
  # Wrong arity is a programming error in the launcher, and must not read as
  # "pyobjc missing" -- those get different treatment.
  py=$(PANEL_KEYSEND_PYTHON="" import_fn find_quartz_python >/dev/null 2>&1; find_quartz_python 2>/dev/null) || py=""
  if [ -z "$py" ]; then
    py=$(command -v python3 2>/dev/null)
  fi
  [ -n "$py" ] || { assert_eq "no python3 at all on this machine" "skip" "skip"; return 0; }

  "$py" "$KEYSEND" >/dev/null 2>&1; rc=$?
  assert_eq "no arguments is a usage error (64), not a missing-pyobjc signal" "64" "$rc"

  "$py" "$KEYSEND" 1 2 3 4 >/dev/null 2>&1; rc=$?
  assert_eq "too many arguments is the same usage error" "64" "$rc"

  # An interpreter without the bindings must exit 2 and say why on stderr.
  if ! /usr/bin/python3 -c 'import Quartz' 2>/dev/null; then
    out=$(/usr/bin/python3 "$KEYSEND" 1 x 1 2>&1); rc=$?
    assert_eq "an interpreter without pyobjc exits 2" "2" "$rc"
    assert_contains "and says which import failed" "Quartz" "$out"
  fi

  # The sequence itself is fixed, and the launcher depends on its shape: a
  # split, the command, Return, then the resize presses.
  local src; src=$(cat "$KEYSEND")
  assert_contains "it opens a split" '"d", ("cmd",)' "$src"
  assert_contains "it presses Return"  '"return"' "$src"
  assert_contains "it focuses the left pane" '"h", ("ctrl",)' "$src"
  assert_contains "it shrinks the right one" '"l", ("ctrl", "shift")' "$src"
  assert_contains "and it targets a pid, not the focus" "CGEventPostToPid" "$src"
}
