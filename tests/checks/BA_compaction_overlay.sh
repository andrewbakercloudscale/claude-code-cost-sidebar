# Check BA -- the floating "Async Compaction In Progress" notice.
#
# Shown once when Claude Burst's compaction-state.json says this session's
# summary is in flight (pending), told to show "Finished" when it no longer
# is, never for another session, never from a state file 15 minutes stale,
# and not at all when the option is off.
check_BA_compaction_overlay() {
  sandbox_new BA
  load_panel 10 12 ""
  local f="$HOME/.config/claude-burst/compaction-state.json" log="$SBX/overlay.log"
  mkdir -p "$(dirname "$f")" "$HOME/.local/bin"
  # A stub notice: records its arguments, then waits to be signalled.
  cat > "$HOME/.local/bin/claude-panel-overlay" <<STUB
#!/bin/bash
echo "start \$2 \$3|\$4" >> "$log"
trap 'echo ready >> "$log"; exit 0' USR1
for _ in \$(seq 1 50); do sleep 0.1; done
STUB
  chmod +x "$HOME/.local/bin/claude-panel-overlay"
  PANEL_GHOSTTY_PID=0
  : > "$log"

  printf '{"aaa|claude-opus-5-5|x":{"pending":true},"bbb|claude-opus-5-5|y":{}}\n' > "$f"
  compaction_pending aaa && r=yes || r=no
  assert_eq "pending for this session" yes "$r"
  compaction_pending bbb && r=yes || r=no
  assert_eq "not pending for another session" no "$r"
  compaction_pending aa && r=yes || r=no
  assert_eq "a session id prefix is not a match" no "$r"
  compaction_pending "" && r=yes || r=no
  assert_eq "no session, nothing pending" no "$r"

  compaction_overlay_tick aaa
  compaction_overlay_tick aaa
  # Waits for the stub to have started, not a fixed time: under load bash
  # took over half a second to start it, and the signal below then killed it
  # before its trap was set.
  ba_wait() { local i; for i in $(seq 1 50); do grep -q "$1" "$log" 2>/dev/null && return 0; sleep 0.1; done; }
  ba_wait start
  sleep 0.2
  assert_eq "shown once, with both messages" "start 600 Async Compaction In Progress|Async Compaction Finished" "$(cat "$log")"

  printf '{"aaa|claude-opus-5-5|x":{"pending":false}}\n' > "$f"
  touch -t "$(date -v+1M +%Y%m%d%H%M.%S)" "$f"
  compaction_overlay_tick aaa
  ba_wait ready
  assert_contains "told it finished" "ready" "$(cat "$log")"
  assert_eq "ready for the next one" 0 "$COMPACT_SHOWN"

  printf '{"aaa|m|x":{"pending":true}}\n' > "$f"
  touch -t "$(date -v-20M +%Y%m%d%H%M.%S)" "$f"
  compaction_pending aaa && r=yes || r=no
  assert_eq "a state file 20 minutes old is ignored" no "$r"

  touch "$f"; : > "$log"
  CLAUDE_PANEL_COMPACTION_OVERLAY=false compaction_overlay_tick aaa
  sleep 0.3
  assert_eq "option off, no notice" "" "$(cat "$log")"

  # Claude Burst's mod toasting this session: the toast is the notice.
  mkdir -p "$HOME/.config/claude-panel/mod-toasts"
  touch "$HOME/.config/claude-panel/mod-toasts/aaa"
  compaction_overlay_tick aaa
  sleep 0.3
  assert_eq "toasted in the session, no notice" "" "$(cat "$log")"
  assert_eq "and nothing counted as shown" 0 "$COMPACT_SHOWN"
  # Another session's mark, or one a gone mod left, changes nothing.
  compaction_toasted bbb && r=yes || r=no
  assert_eq "another session's mark is not this one's" no "$r"
  touch -t "$(date -v-5M +%Y%m%d%H%M.%S)" "$HOME/.config/claude-panel/mod-toasts/aaa"
  compaction_toasted aaa && r=yes || r=no
  assert_eq "a mark 5 minutes old is ignored" no "$r"
  compaction_overlay_tick aaa
  ba_wait start
  assert_contains "so the notice is shown" "start 600 Async Compaction In Progress" "$(cat "$log")"
  pkill -f "$HOME/.local/bin/claude-panel-overlay" 2>/dev/null
  return 0
}
