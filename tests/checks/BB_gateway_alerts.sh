# Check BB -- Claude Burst's gateway alerts, floated over Ghostty.
#
# New events in notices.json are shown once each, one at a time, coloured by
# severity; events from before the panel started are not replayed; an error
# is sticky until an ok that resolves its kind; the panel says so itself
# when the gateway's dashboard stops answering; and nothing shows with the
# option off.
check_BB_gateway_alerts() {
  sandbox_new BB
  load_panel 10 12 ""
  local f="$HOME/.config/claude-burst/notices.json" log="$SBX/overlay.log" now
  mkdir -p "$(dirname "$f")" "$HOME/.local/bin"
  # A stub notice: records its arguments, stays up for a moment, then goes.
  cat > "$HOME/.local/bin/claude-panel-overlay" <<STUB
#!/bin/bash
echo "show \$2|\$3|\$5|\$6" >> "$log"
trap 'echo killed >> "$log"; exit 0' TERM
sleep 0.2
STUB
  chmod +x "$HOME/.local/bin/claude-panel-overlay"
  PANEL_GHOSTTY_PID=0
  # No dashboard to check here: the health check is driven by hand below.
  panel_gateway_url() { :; }
  : > "$log"
  now=$(panel_now)

  write_notices() { # $@ = JSON events; each write moves the mtime on
    local IFS=,
    printf '{"events":[%s]}\n' "$*" > "$f"
    BB_BUMP=$((BB_BUMP + 1))
    touch -t "$(date -v+${BB_BUMP}S +%Y%m%d%H%M.%S)" "$f"
  }
  BB_BUMP=0
  # Waits for the notice on screen to go (sleep is slow here: 0.1 takes
  # nearer 0.3, so fixed sleeps race).
  bb_settle() { local i; for i in $(seq 1 40); do alert_alive || return 0; sleep 0.1; done; }
  write_notices \
    "{\"id\":\"1\",\"kind\":\"gateway\",\"severity\":\"info\",\"title\":\"Old news\",\"ts\":$((now - 300))}" \
    "{\"id\":\"2\",\"kind\":\"failover\",\"severity\":\"warn\",\"title\":\"Failed over to together\",\"detail\":\"until 10:00\",\"ts\":$now}" \
    "{\"id\":\"3\",\"kind\":\"gateway\",\"severity\":\"info\",\"title\":\"Gateway ready\",\"detail\":\"\",\"ts\":$now}"
  gateway_alerts_tick
  gateway_alerts_tick
  bb_settle
  assert_eq "the old event is not replayed; the first new one shows alone" \
    "show 15|Failed over to together|warn|until 10:00" "$(cat "$log")"
  gateway_alerts_tick
  bb_settle
  assert_eq "then the next, with an empty detail kept empty" \
    "show 10|Gateway ready|info|" "$(sed -n 2p "$log")"
  gateway_alerts_tick
  bb_settle
  assert_eq "each shown once" 2 "$(wc -l < "$log" | tr -d ' ')"

  # An error stays, steps aside for news, and comes back until resolved.
  : > "$log"
  write_notices \
    "{\"id\":\"3\",\"kind\":\"gateway\",\"severity\":\"info\",\"title\":\"Gateway ready\",\"ts\":$now}" \
    "{\"id\":\"4\",\"kind\":\"network\",\"severity\":\"error\",\"title\":\"Network offline\",\"ts\":$now}"
  gateway_alerts_tick
  bb_settle
  assert_contains "the error shows" "|Network offline|error|" "$(cat "$log")"
  local secs
  secs=$(head -1 "$log" | sed 's/^show \([0-9]*\)|.*/\1/')
  assert_eq "for up to 10 minutes" yes "$( (( secs >= 590 && secs <= 600 )) && echo yes || echo "no ($secs)")"
  gateway_alerts_tick
  bb_settle
  assert_contains "and comes back after it closes" "show" "$(sed -n 2p "$log")"
  write_notices \
    "{\"id\":\"4\",\"kind\":\"network\",\"severity\":\"error\",\"title\":\"Network offline\",\"ts\":$now}" \
    "{\"id\":\"5\",\"kind\":\"network\",\"severity\":\"ok\",\"title\":\"Network back\",\"resolves\":\"network\",\"ts\":$now}"
  gateway_alerts_tick
  bb_settle
  assert_eq "the ok that resolves it ends it" "" "$ALERT_STICKY"
  assert_contains "and shows in green" "show 10|Network back|ok|" "$(cat "$log")"
  : > "$log"
  gateway_alerts_tick
  bb_settle
  assert_eq "the error does not come back" "" "$(cat "$log")"

  # The gateway cannot report its own death: the panel does, after 3 misses.
  : > "$log"
  panel_gateway_url() { printf 'http://127.0.0.1:1/'; }
  curl() { return 7; }
  local i
  for i in 1 2; do ALERT_HEALTH_AT=0; gateway_alerts_tick; done
  bb_settle
  assert_eq "two misses are not an outage" "" "$(cat "$log")"
  ALERT_HEALTH_AT=0; gateway_alerts_tick
  bb_settle
  assert_contains "three are" "|Burst gateway not responding|error|" "$(cat "$log")"
  curl() { return 0; }
  ALERT_HEALTH_AT=0; gateway_alerts_tick
  bb_settle
  assert_contains "and it says when it is back" "|Burst gateway back|ok|" "$(cat "$log")"
  unset -f curl

  # An event about a session goes to its own panel, a handover to the
  # others, and an event another panel claimed is left to it.
  : > "$log"
  mkdir -p "$HOME/.config/claude-panel/alerts-claimed/11"
  write_notices \
    "{\"id\":\"7\",\"kind\":\"context\",\"severity\":\"info\",\"title\":\"Context other\",\"session\":\"other\",\"ts\":$now}" \
    "{\"id\":\"8\",\"kind\":\"context\",\"severity\":\"info\",\"title\":\"Context mine\",\"session\":\"me\",\"ts\":$now}" \
    "{\"id\":\"9\",\"kind\":\"handover\",\"severity\":\"info\",\"title\":\"Handover mine\",\"session\":\"me\",\"ts\":$now}" \
    "{\"id\":\"10\",\"kind\":\"handover\",\"severity\":\"info\",\"title\":\"Handover other\",\"session\":\"other\",\"ts\":$now}" \
    "{\"id\":\"11\",\"kind\":\"test\",\"severity\":\"info\",\"title\":\"Claimed elsewhere\",\"ts\":$now}"
  local n
  for n in 1 2 3; do gateway_alerts_tick me; bb_settle; done
  assert_eq "own context, others' handover, nothing claimed elsewhere" \
    "Context mine|Handover other" "$(cut -d'|' -f2 "$log" | paste -sd'|' -)"
  assert_eq "and this panel claimed what it showed" yes \
    "$([ -d "$HOME/.config/claude-panel/alerts-claimed/8" ] && echo yes || echo no)"

  : > "$log"
  write_notices \
    "{\"id\":\"6\",\"kind\":\"test\",\"severity\":\"info\",\"title\":\"Test alert\",\"ts\":$now}"
  CLAUDE_PANEL_ALERTS=false gateway_alerts_tick
  bb_settle
  assert_eq "option off, nothing shown" "" "$(cat "$log")"
  pkill -f "$HOME/.local/bin/claude-panel-overlay" 2>/dev/null
  return 0
}
