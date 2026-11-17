# Check BM -- a pane nobody is looking at ticks at a walk, and the tick
# itself starts as few processes as it can.
#
# A dozen panes ran the full tick every 10 seconds, about 60 process starts
# each (date, jq, tr, grep, stat, awk, basename, shasum ...), and forked five
# times a second while waiting, for the one or two sessions on screen. The
# tick now reads its files with one stat (tick_stat_batch), Burst's config
# with one jq (burst_cfg_load), and the rest in the shell; a pane without
# focus for a while, whose session the Dock does not show, draws every
# PANEL_IDLE_REFRESH and checks every REFRESH, with one stat, whether a turn
# has landed. Each piece is pinned here, because a pane that quietly stopped
# redrawing on a new turn would look exactly like a quiet session.
check_BM_idle_panel() {
  sandbox_new BM
  load_panel 10 12 ""
  local now t st st2 f

  # ---- labels: the idle rate is derived, like every other -----------------
  assert_eq "idle label derives from PANEL_IDLE_REFRESH" \
    "$(fmt_interval "$PANEL_IDLE_REFRESH")" "$RATE_IDLE"
  assert_eq "the active label is the tick's" "$RATE_FAST" "$RATE_FAST_ACTIVE"
  assert_eq "idle is slower than the tick" yes \
    "$( (( PANEL_IDLE_REFRESH > REFRESH )) && echo yes || echo no)"

  # ---- the idle decision ------------------------------------------------------
  panel_now_v now
  PANEL_CLOSE=1 PANEL_FOCUSED=0 PANEL_FOCUS_LOST_AT=$(( now - 3600 )) panel_dock_rc=1
  panel_idle "$now" && _pass || _fail "no focus for an hour, not on screen: idle" "idle" "active"
  panel_dock_rc=2
  panel_idle "$now" && _pass || _fail "no Dock: focus alone decides" "idle" "active"
  panel_dock_rc=0
  panel_idle "$now" && _fail "on screen per the Dock: never idle" "active" "idle" || _pass
  panel_dock_rc=1 PANEL_FOCUSED=1
  panel_idle "$now" && _fail "focused: never idle" "active" "idle" || _pass
  PANEL_FOCUSED=0 PANEL_FOCUS_LOST_AT=$(( now - PANEL_IDLE_AFTER + 1 ))
  panel_idle "$now" && _fail "focus lost moments ago: not idle yet" "active" "idle" || _pass
  PANEL_FOCUS_LOST_AT=$(( now - 3600 )) PANEL_CLOSE=0
  panel_idle "$now" && _fail "no focus reporting: never idle" "active" "idle" || _pass
  PANEL_CLOSE=1

  # ---- focus, from what the terminal sends --------------------------------
  PANEL_FOCUSED=1 PANEL_FOCUS_LOST_AT=0 PANEL_INBUF=$'\e[O'
  panel_read_clicks 40
  assert_eq "focus out clears focus" 0 "$PANEL_FOCUSED"
  assert_ne "and stamps when" 0 "$PANEL_FOCUS_LOST_AT"
  PANEL_INBUF=$'\e[O\e[<0;3;3M\e[I'
  panel_read_clicks 40
  assert_eq "the later of the two in one read wins" 1 "$PANEL_FOCUSED"

  # ---- the wait between idle draws ------------------------------------------
  f="$HOME/.claude/projects/test-project/idle.jsonl"
  printf '{}\n' > "$f"
  # PANEL_CLOSE off: the wait's own input poll must not read the runner's tty.
  latest=$f cur_sid=idle PANEL_REDRAW=0 PANEL_FOCUSED=0 panel_dock_rc=2 PANEL_CLOSE=0
  transcript_stamp_v idle_stamp "$f"
  BM_WAITS=0 BM_ALERTS=0
  restart_if_changed() { :; }
  compaction_overlay_tick() { :; }
  gateway_alerts_tick() { BM_ALERTS=$(( BM_ALERTS + 1 )); }
  # Each wait: the first one, a turn lands (the file grows).
  flash_restart_banner() {
    BM_WAITS=$(( BM_WAITS + 1 ))
    (( BM_WAITS == 1 )) && printf '{"x":1}\n' >> "$f"
    (( BM_WAITS > 5 )) && PANEL_REDRAW=1
  }
  panel_now_v now
  last_full=$now last_slow=$now
  panel_idle_wait ""
  assert_eq "a turn landing ends the wait at the next check" 1 "$BM_WAITS"
  assert_eq "the alerts kept their cadence meanwhile" 1 "$BM_ALERTS"

  transcript_stamp_v idle_stamp "$f"
  BM_WAITS=0 BM_ALERTS=0
  last_full=$(( now - PANEL_IDLE_REFRESH ))
  panel_idle_wait ""
  assert_eq "a full draw due: no wait at all" 0 "$BM_WAITS"
  last_full=$now last_slow=$(( now - SLOW_REFRESH ))
  panel_idle_wait ""
  assert_eq "the slow tier due: no wait either (its label stays true)" 0 "$BM_WAITS"
  last_slow=$now
  PANEL_REDRAW=0
  flash_restart_banner() { BM_WAITS=$(( BM_WAITS + 1 )); (( BM_WAITS == 2 )) && PANEL_INBUF=$'\e[I' && panel_read_clicks 40; }
  panel_idle_wait ""
  assert_eq "focus in ends the wait" 2 "$BM_WAITS"
  assert_eq "and asks for a redraw" 1 "$PANEL_REDRAW"
  unset -f restart_if_changed compaction_overlay_tick gateway_alerts_tick flash_restart_banner
  load_panel 10 12 ""

  # ---- one stat a tick --------------------------------------------------------
  printf 'abc' > "$SBX/a"
  tick_stat "$SBX/a" st && _pass || _fail "a file outside a batch is statted" "found" "missing"
  tick_stat "$SBX/nope" st && _fail "a missing file is missing" "missing" "found" || _pass
  tick_stat_batch "$SBX/a" "$SBX/nope" ""
  tick_stat "$SBX/a" st2
  assert_eq "the batch answers as the stat did" "$st" "$st2"
  tick_stat "$SBX/nope" st2 && _fail "and records a missing file as missing" "missing" "found" || _pass
  rm -f "$SBX/a"
  tick_stat "$SBX/a" st2 && _pass || _fail "within the tick the batch is the answer" "found" "missing"
  tick_stat_end
  tick_stat "$SBX/a" st2 && _fail "after it, the file as it is" "missing" "found" || _pass
  printf 'abcde' > "$SBX/b"
  transcript_stamp_v st "$SBX/b"
  assert_eq "the transcript stamp is mtime:size" "$(stat -f %m "$SBX/b"):5" "$st"
  transcript_stamp_v st "$SBX/none"
  assert_eq "and 0:0 for no file" "0:0" "$st"

  # ---- the options file, read in the shell -------------------------------
  mkdir -p "$HOME/.config/claude-panel"
  printf 'BM_OPT=one\nBM_OPT_X=no\nBM_OPT="Two Words"' > "$HOME/.config/claude-panel/options"
  panel_option_raw BM_OPT t
  assert_eq "the last line wins, with no newline after it" '"Two Words"' "$t"
  BM_OPT=env panel_option_raw BM_OPT t
  assert_eq "the environment wins" env "$t"
  printf 'BM_FLAG= "OFF"\n' > "$HOME/.config/claude-panel/options"
  panel_option_off BM_FLAG && _pass || _fail "quotes, spaces and case are dropped" "off" "on"

  # ---- notices.json is read when it changes, not every tick ------------------
  ALERT_FILE="$SBX/notices.json"
  printf '{"events":[]}\n' > "$ALERT_FILE"
  ALERT_MTIME=""
  alert_file_changed && _pass || _fail "a new file is a change" "changed" "same"
  alert_file_changed && _fail "the same file is not" "same" "changed" || _pass
  printf '{"events":[] }\n' > "$ALERT_FILE"
  alert_file_changed && _pass || _fail "a rewrite in the same second is" "changed" "same"

  # ---- the turn table is reused while the transcript holds still ----------
  # Counted in a file: session_stats_refresh asks inside $(...).
  : > "$SBX/tables"
  turn_table_series() { echo x >> "$SBX/tables"; printf '#META\t1\t2\t3\t0\nrow'; }
  bm_tables() { wc -l < "$SBX/tables" | tr -d ' '; }
  latest="$SBX/b" PANEL_MEMO=1
  session_stats_refresh; session_stats_refresh
  assert_eq "an unchanged transcript is not asked twice" 1 "$(bm_tables)"
  assert_eq "and the second answer is the first" "row" "$SESS_TABLE"
  printf 'more' >> "$SBX/b"
  session_stats_refresh
  assert_eq "a changed one is" 2 "$(bm_tables)"
  PANEL_MEMO=0
  session_stats_refresh
  assert_eq "outside the loop every call asks" 3 "$(bm_tables)"
  unset -f turn_table_series bm_tables
  return 0
}
