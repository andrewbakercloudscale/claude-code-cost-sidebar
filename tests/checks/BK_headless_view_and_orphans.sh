# Check BK -- one headless panel per session, and the ones nobody can see
# kept up to date at a walk.
#
# mod_prune deleted any file over two days old, a running panel's .pid among
# them, and the next ccusage-panel-mod-start started a second panel for the
# same session: six such pairs, up to four days old, on 26 Oct 2026. With a
# dozen sessions open every panel also ran at full rate, about 6% of a core
# each, for the one sidebar on screen. Ghostty Dock now names the sessions on
# screen in a file; a panel not named there runs at a walk.
check_BK_headless_view_and_orphans() {
  sandbox_new BK
  load_panel 10 12 ""
  local sid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" now
  mkdir -p "$MOD_DIR"

  # The prune keeps a .pid however old, and still clears the rest.
  printf '%s\n' "$$" > "$MOD_DIR/$sid.pid"
  : > "$MOD_DIR/gone.json"
  age_file "$MOD_DIR/$sid.pid" $(( 3 * 86400 ))
  age_file "$MOD_DIR/gone.json" $(( 3 * 86400 ))
  mod_prune
  [ -f "$MOD_DIR/$sid.pid" ] && _pass || _fail "a running panel's .pid survives the prune" "kept" "deleted"
  [ -f "$MOD_DIR/gone.json" ] && _fail "an old feed file is pruned" "deleted" "kept" || _pass

  # A panel goes once another live one holds the session.
  mod_still_ours "$sid" && _pass || _fail "its own .pid is its own" "ours" "not ours"
  sleep 30 &
  local other=$!
  printf '%s\n' "$other" > "$MOD_DIR/$sid.pid"
  mod_still_ours "$sid" && _fail "another live holder takes the session" "not ours" "ours" || _pass
  kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
  mod_still_ours "$sid" && _pass || _fail "a dead holder does not" "ours" "not ours"
  rm -f "$MOD_DIR/$sid.pid"
  mod_still_ours "$sid" && _pass || _fail "nor does no file" "ours" "not ours"

  # In view: no Dock file, a stale one, or one naming it. Out: a fresh file
  # without it.
  now=$(date +%s)
  DOCK_VISIBLE_FILE="$SBX/visible"
  panel_in_view "$sid" "$now" && _pass || _fail "no Dock: every panel is in view" "in view" "out"
  printf '%s\n' "other-session" > "$DOCK_VISIBLE_FILE"
  panel_in_view "$sid" "$now" && _fail "a fresh file without it is out of view" "out" "in view" || _pass
  printf '%s\n%s\n' "other-session" "$sid" > "$DOCK_VISIBLE_FILE"
  panel_in_view "$sid" "$now" && _pass || _fail "named among others, it is in view" "in view" "out"
  printf '%s\n' "other-session" > "$DOCK_VISIBLE_FILE"
  age_file "$DOCK_VISIBLE_FILE" $(( PANEL_VIEW_STALE_SECS + 30 ))
  panel_in_view "$sid" "$now" && _pass || _fail "a file the Dock stopped rewriting counts for nothing" "in view" "out"
}
