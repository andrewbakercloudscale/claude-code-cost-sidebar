# Check AS -- the cost alert obeys the two options the dashboard switches.
#
# CLAUDE_PANEL_COST_ALERTS=false silences the spend alerts but not the
# panel-launch failure, which reports a broken install rather than spend.
# CLAUDE_PANEL_ALERT_MIN_USD replaces the hardcoded $5 floor, and a value
# that is not a number falls back to it rather than silencing every alert.
check_AS_alert_options() {
  sandbox_new AS
  case "$HOME" in "$SBX"/*) ;; *) _fail "HOME is the sandbox" "$SBX/..." "$HOME"; return ;; esac
  local hook="$HOME_REAL_BIN/claude-cost-alert-check.sh"
  if [ ! -f "$hook" ]; then
    assert_eq "cost-alert hook is present to be checked" "1" "0"
    return
  fi
  local opts="$HOME/.config/claude-panel/options"
  mkdir -p "$(dirname "$opts")"

  # $20.00 against sessions averaging $8.20: 2.4x, RED (see check AB).
  printf '%s\n' '{"sessions":[{"period":"S1","totalCost":8.0},{"period":"S2","totalCost":8.0},{"period":"S3","totalCost":8.6},{"period":"SID-AS","totalCost":20.00}]}' \
    > "$CCUSAGE_FIXTURE_DIR/session.json"
  run() { # $1 = session id suffix; a fresh id so throttling never answers
    rm -rf "$HOME/.cache/claude-cost-alert-state"
    TERM_PROGRAM=Apple_Terminal CLAUDE_COST_ALERT_TELEGRAM=0 bash "$hook" <<< '{"session_id":"SID-AS"}' 2>/dev/null
  }

  : > "$opts"
  assert_contains "no options file entries: alerts on by default" "COST ALERT" "$(run)"

  printf '# c\nCLAUDE_PANEL_COST_ALERTS="False"\n' > "$opts"
  assert_eq "COST_ALERTS=False (quoted, capitalised): silent" "" "$(run)"

  printf 'CLAUDE_PANEL_COST_ALERTS=true\nCLAUDE_PANEL_ALERT_MIN_USD=25\n' > "$opts"
  assert_eq "ALERT_MIN_USD=25 above the \$20 session: silent" "" "$(run)"

  printf 'CLAUDE_PANEL_ALERT_MIN_USD=19.50\n' > "$opts"
  assert_contains "ALERT_MIN_USD=19.50 below it: fires" "COST ALERT" "$(run)"

  printf 'CLAUDE_PANEL_ALERT_MIN_USD=lots\n' > "$opts"
  assert_contains "ALERT_MIN_USD not a number: falls back to \$5 and fires" "COST ALERT" "$(run)"

  # Alerts off, launcher failed: the launch alert still arrives, alone.
  printf 'CLAUDE_PANEL_COST_ALERTS=off\n' > "$opts"
  printf '2026-01-01 00:00:00 done: GAVE UP after 3 attempts\n' > "$HOME/.cache/claude-panel-launch.log"
  local out msg
  out=$(run)
  msg=$(jq -r '.systemMessage // empty' <<<"$out" 2>/dev/null)
  assert_contains "alerts off: the launch failure still fires" "DIDN'T LAUNCH" "$msg"
  assert_not_contains "alerts off: no cost alert beside it" "COST ALERT" "$msg"
  rm -f "$HOME/.cache/claude-panel-launch.log"

  # Setup's options block writes each key and each comment exactly once:
  # in a fresh file, and when topping up a file an older setup wrote. Run
  # alone, extracted from the repo's setup script, with HOME in the sandbox
  # (checked above), so nothing outside it is touched.
  local setup="$HERE/../claude-panel-setup.sh" block
  block=$(awk '/^PANEL_OPTIONS="\$HOME\/.config\/claude-panel\/options"$/{on=1} /^echo "Options: /{on=0} on' "$setup")
  assert_contains "options block found in setup" "OPTIONS_EOF" "$block"
  local keys="REMOTE_CONTROL CAFFEINATE SESSION_TITLE RESTART_TOKENS COST_ALERTS ALERT_MIN_USD" k
  once() { # $1 label, $2 file
    for k in $keys; do
      assert_eq "$1: CLAUDE_PANEL_$k= once" "1" "$(grep -c "^CLAUDE_PANEL_$k=" "$2")"
      assert_eq "$1: its comment once" "1" "$(grep -c "^# CLAUDE_PANEL_$k: " "$2")"
    done
  }
  rm -f "$opts"
  bash -c "$block"
  once "fresh file" "$opts"
  assert_eq "fresh file: defaults" "CLAUDE_PANEL_SESSION_TITLE=true CLAUDE_PANEL_ALERT_MIN_USD=5.00" \
    "$(grep -E '^CLAUDE_PANEL_(SESSION_TITLE|ALERT_MIN_USD)=' "$opts" | tr '\n' ' ' | sed 's/ $//')"
  bash -c "$block"
  once "second run" "$opts"

  # An older file: two keys set by the user, the header listing comments
  # for keys it never wrote. Kept values survive, missing keys arrive once.
  printf '%s\n' "# claude-panel options -- true/false. Written by claude-panel-setup.sh." \
    "# CLAUDE_PANEL_REMOTE_CONTROL: start interactive claude sessions with --remote-control" \
    "# CLAUDE_PANEL_CAFFEINATE: keep the Mac awake (caffeinate -i) while a panel runs" \
    "# CLAUDE_PANEL_SESSION_TITLE: name new sessions after their folder" \
    "CLAUDE_PANEL_REMOTE_CONTROL=true" "CLAUDE_PANEL_CAFFEINATE=true" > "$opts"
  bash -c "$block"
  once "old file topped up" "$opts"
  assert_eq "old file: user's value kept" "1" "$(grep -c '^CLAUDE_PANEL_REMOTE_CONTROL=true$' "$opts")"
}
