# Check BN -- one collector for every panel.
#
# A dozen panels each worked out the same gateway check, Burst config, Proxy
# State line, block clock, notices and slow-tier reports every tick. One
# collector does it now and writes collector/state.sh, and the panels read
# that. Pinned here: there is only ever one (the lock), panels take what it
# wrote, a half-written, stale or orphaned state.sh is not believed (the panel
# works the figure out itself, as before the collector), a dead collector is
# started again by a panel, and the panels' own filter of the collector's
# notices picks exactly the events the jq it replaced picked.
bn_wait() { # $1 = condition, as a command; up to 15s
  local i
  for (( i = 0; i < 75; i++ )); do
    eval "$1" && return 0
    sleep 0.2
  done
  return 1
}
bn_lock_pid() { local p=""; { IFS= read -r p < "$COLLECTOR_LOCK/pid"; } 2>/dev/null; printf '%s' "$p"; }
check_BN_collector() {
  sandbox_new BN
  load_panel 10 12 ""
  local coll="${PANEL_SH%/*}/ccusage-panel-collector" a b p t out jq_out mine

  # ---- the collector script is installed beside the panel -----------------
  [ -x "$coll" ] && _pass || _fail "ccusage-panel-collector beside the panel" "$coll" "missing"

  # ---- one at a time ---------------------------------------------------------
  # A panel is listed (this shell), so the first stays.
  mkdir -p "$COLLECTOR_PANELS"
  printf 'x\n' > "$COLLECTOR_PANELS/$$"
  ( exec bash "$coll" 10 12 </dev/null >/dev/null 2>"$SBX/coll-a.err" ) &
  a=$!
  bn_wait '[ -s "$COLLECTOR_STATE" ]' && _pass || _fail "the first collector writes state.sh" "written" "nothing in 15s"
  assert_eq "and holds the lock" "$a" "$(bn_lock_pid)"
  ( exec bash "$coll" 10 12 </dev/null >/dev/null 2>"$SBX/coll-b.err" ) &
  b=$!
  bn_wait '! kill -0 '"$b"' 2>/dev/null' && _pass || _fail "a second collector leaves at once" "exited" "running"
  assert_eq "the lock is still the first's" "$a" "$(bn_lock_pid)"
  kill -0 "$a" 2>/dev/null && _pass || _fail "and the first runs on" "running" "gone"

  # ---- a panel reads it -------------------------------------------------------
  collector_read
  assert_eq "a fresh state.sh from a live collector is live" 1 "$COLLECTOR_LIVE"
  assert_eq "its pid is the collector's" "$a" "$CS_PID"

  # ---- the collector goes; a panel starts another ------------------------
  kill "$a" 2>/dev/null; wait "$a" 2>/dev/null
  collector_read
  assert_eq "a collector that has gone is not live" 0 "$COLLECTOR_LIVE"
  COLLECTOR_SELF=$coll COLLECTOR_SPAWN_OK=1 COLLECTOR_SPAWNED_AT=0
  collector_ensure
  bn_wait 'p=$(bn_lock_pid); [ -n "$p" ] && [ "$p" != "'"$a"'" ] && kill -0 "$p" 2>/dev/null' \
    && _pass || _fail "a panel that finds none starts one" "a new pid in the lock" "$(bn_lock_pid)"
  p=$(bn_lock_pid)
  bn_wait 'collector_read; (( COLLECTOR_LIVE )) && [ "$CS_PID" = "'"$p"'" ]' \
    && _pass || _fail "and reads the new one's state" "live, pid $p" "live=$COLLECTOR_LIVE pid=$CS_PID"
  COLLECTOR_SPAWN_OK=0
  # No panel left: it goes by itself once COLLECTOR_LINGER has passed. The
  # restarted one has the default linger, so this one is stopped by hand and
  # a short-lived one is asked for.
  kill "$p" 2>/dev/null
  bn_wait '! kill -0 '"$p"' 2>/dev/null' || _fail "the collector stops on TERM" "gone" "running"
  rm -f "$COLLECTOR_PANELS/$$"
  ( COLLECTOR_LINGER=1 exec bash "$coll" 1 12 </dev/null >/dev/null 2>"$SBX/coll-c.err" ) &
  p=$!
  bn_wait '! kill -0 '"$p"' 2>/dev/null' && _pass || _fail "with no panel left it leaves" "exited" "running"
  [ -d "$COLLECTOR_LOCK" ] && _fail "and gives the lock up" "no lock" "lock left" || _pass
  local e
  for e in "$SBX"/coll-*.err; do
    assert_eq "no collector wrote to stderr ($(basename "$e"))" "" "$(cat "$e")"
  done

  # ---- what a panel believes ------------------------------------------------
  # A state.sh written by hand, so each field is known.
  bn_state() { # $1 = seq, $2 = at, $3 = pid, $4 = trailer seq
    {
      printf '# collector %s\n' "$1"
      printf 'CS_AT=%q\nCS_PID=%q\n' "$2" "$3"
      printf 'CS_PROXY_LINE=%q\nCS_PROXY_LINE_VIEW=%q\n' "proxy line $1" "proxy view $1"
      printf 'CS_GW_URL=%q\nCS_GW_SEQ=%q\nCS_GW_OK=%q\n' "http://127.0.0.1:1/" "$1" 1
      printf 'CS_BLOCK=%q\n' "$(printf 'has_block=1\nblk_cph=%q\nburn_label=High\n' "4$1.00")"
      printf '# end %s\n' "$4"
    } > "$COLLECTOR_STATE"
  }
  t=$(panel_now)
  sleep 300 & local holder=$!
  COLLECTOR_SEQ_SEEN=""
  bn_state 11 "$t" "$holder" 11
  collector_read
  assert_eq "whole and fresh: live" 1 "$COLLECTOR_LIVE"
  proxy_state_line_v out
  assert_eq "the Proxy State line is the collector's" "proxy line 11" "$out"
  PANEL_CLOSE=1 proxy_state_line_v out
  assert_eq "with the [View] button, its other line" "proxy view 11" "$out"
  has_block=0 blk_cph=""
  block_clock_tick
  assert_eq "the block's clock is the collector's" "411.00" "$blk_cph"
  # The gateway: the collector's result, and no curl of this panel's own.
  : > "$SBX/curl.log"
  curl() { echo x >> "$SBX/curl.log"; return 7; }
  ALERT_HEALTH_SEQ=0 ALERT_HEALTH_MISSES=2
  alert_health_tick
  assert_eq "a check from the collector that answered clears the misses" 0 "$ALERT_HEALTH_MISSES"
  ALERT_HEALTH_MISSES=2
  alert_health_tick
  assert_eq "the same result is not counted twice" 2 "$ALERT_HEALTH_MISSES"
  assert_eq "and the panel ran no curl" 0 "$(wc -l < "$SBX/curl.log" | tr -d ' ')"

  bn_state 12 "$t" "$holder" 11
  collector_read
  assert_eq "a half-written file (seq lines differ) is not read" 0 "$COLLECTOR_LIVE"
  proxy_state_line_v out
  assert_eq "and the panel works the line out itself (no Burst here: none)" "" "$out"
  printf '# collector 13\nCS_AT=%s\n' "$t" > "$COLLECTOR_STATE"
  collector_read
  assert_eq "nor one cut short" 0 "$COLLECTOR_LIVE"
  bn_state 14 "$(( t - COLLECTOR_STALE_SECS - 5 ))" "$holder" 14
  collector_read
  assert_eq "nor a stale one" 0 "$COLLECTOR_LIVE"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  bn_state 15 "$t" "$holder" 15
  collector_read
  assert_eq "nor one whose collector has gone" 0 "$COLLECTOR_LIVE"
  : > "$SBX/curl.log"
  ALERT_HEALTH_AT=0
  panel_gateway_url_v() { printf -v "$1" '%s' 'http://127.0.0.1:1/'; }
  alert_health_tick
  assert_eq "with none live, the panel checks the gateway itself" 1 "$(wc -l < "$SBX/curl.log" | tr -d ' ')"
  unset -f curl panel_gateway_url_v
  load_panel 10 12 ""
  PANEL_COLLECTOR=0
  bn_state 16 "$t" "$$" 16
  collector_read
  assert_eq "PANEL_COLLECTOR=0 ignores it" 0 "$COLLECTOR_LIVE"
  PANEL_COLLECTOR=1

  # ---- the notices filter, against the jq it stands in for ----------------
  ALERT_FILE="$SBX/notices.json"
  local now; now=$(panel_now)
  printf '{"events":[%s]}\n' "$(printf '%s,' \
    "{\"id\":\"e1\",\"ts\":$(( now - 500 )),\"severity\":\"info\",\"kind\":\"a\",\"title\":\"one\"}" \
    "{\"id\":\"e2\",\"ts\":$(( now - 100 )).5,\"severity\":\"warn\",\"kind\":\"b\",\"title\":\"two\",\"detail\":\"d\\u001fx\\nl\"}" \
    "{\"id\":\"e3\",\"ts\":$(( now - 100 )),\"severity\":\"ok\",\"kind\":\"c\",\"title\":\"three\",\"resolves\":\"b\",\"session\":\"s1\"}" \
    "{\"id\":\"e4\",\"ts\":\"later\",\"severity\":\"error\",\"kind\":\"d\",\"title\":\"four\"}" \
    "{\"id\":\"e5\",\"ts\":null,\"severity\":\"info\",\"kind\":\"e\",\"title\":\"five\"}" \
    "{\"id\":\"e6\",\"ts\":$(( now - 10 )),\"severity\":\"info\",\"kind\":\"f\",\"title\":\"six\"}" | sed 's/,$//')" \
    > "$ALERT_FILE"
  CS_ALERT_EVENTS=$(collector_alert_events)
  tick_stat "$ALERT_FILE" CS_ALERT_STAMP
  ALERT_MTIME=$CS_ALERT_STAMP
  sleep 300 & holder=$!
  CS_PID=$holder CS_AT=$now COLLECTOR_LIVE=1
  local case_
  for case_ in ":0" ":$(( now - 100 ))" ":$(( now - 101 ))" ":$(( now - 600 ))" "e2:0" "e6:0" "zz:$(( now - 50 ))" "e1:0"; do
    ALERT_LAST_ID=${case_%%:*} ALERT_SINCE=${case_#*:}
    jq_out=$(alert_new_events)
    mine=""
    collector_alert_events_v mine && _pass || _fail "the collector's copy answers ($case_)" "answered" "fell back"
    assert_eq "picks what jq picked (last=${case_%%:*})" "$jq_out" "$mine"
  done
  ALERT_MTIME="something else"
  collector_alert_events_v mine && _fail "a copy of another version of the file is not used" "fell back" "answered" || _pass
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  COLLECTOR_LIVE=0
  return 0
}
