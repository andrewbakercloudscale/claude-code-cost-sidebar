# Check AD -- the daily 3-sigma alert, and the two ways it can be wrong.
#
# The session rule cannot see a day made of many ordinary sessions, which is
# what this exists for. But a control limit has a failure mode the session
# rule does not: it can become unreachable without anything announcing it.
# sd on this data is about the size of the mean, so the limit is set mostly
# by the window's composition -- 30 days to 2026-09-09 give a limit of $787
# and contain one day above it; the same window minus its first fortnight
# gives $364. An alert that has silently drifted out of reach looks exactly
# like a quiet month, so both the firing and the not-firing are asserted
# here, and so is the report the operator reads to tell them apart.
check_AD_daily_control_limit() {
  sandbox_new AD
  local hook="$HOME_REAL_BIN/claude-cost-alert-check.sh"
  if [ ! -f "$hook" ]; then
    assert_eq "cost-alert hook is present to be checked" "1" "0"
    return
  fi

  # A stub answering both queries the hook now makes. `daily` is generated so
  # the dates are always relative to today -- a fixed fixture would age out
  # of the 30-day window and start reporting an empty sample.
  local bin="$SBX/bin"
  mkdir -p "$bin"
  cat > "$bin/ccusage" <<'STUB'
#!/usr/bin/env bash
sub="$1"; [ "$sub" = claude ] && sub="$2"
case "$sub" in
  session) printf '%s\n' '{"sessions":[{"period":"S1","totalCost":8.0},{"period":"S2","totalCost":8.0},{"period":"S3","totalCost":8.6}]}' ;;
  daily)   python3 -c '
import json, datetime, os
today = datetime.date.today()
rows = [{"date": (today - datetime.timedelta(days=i)).isoformat(),
         "totalCost": 100.0 + (i % 3) * 10} for i in range(1, 15)]
rows.append({"date": today.isoformat(), "totalCost": float(os.environ["AD_TODAY"])})
print(json.dumps({"daily": rows}))' ;;
esac
STUB
  chmod +x "$bin/ccusage"

  local payload='{"session_id":"SID-AD","cwd":"/tmp/proj"}'
  local run="PATH=$bin:$PATH"

  # 14 prior days at 100/110/120 -> mean ~110, sd ~8, so the limit sits near
  # $135. $900 is unambiguously over it.
  local out
  out=$(PATH="$bin:$PATH" AD_TODAY=900 TERM_PROGRAM=ghostty \
        CLAUDE_COST_ALERT_TELEGRAM=0 bash "$hook" <<<"$payload")
  local msg; msg=$(jq -r '.systemMessage' <<<"$out")
  assert_contains "a day over the limit alerts" "DAILY SPEND" "$msg"
  assert_contains "and names today's figure" '$900.00' "$msg"
  assert_contains "and the limit it passed" "limit" "$msg"
  # The session in this fixture costs nothing, so the daily line is the only
  # one -- which is the point: the session rule could not have caught this.
  assert_not_contains "the session rule did not fire here" "COST ALERT" "$msg"

  # Throttled per DAY and across sessions, not per session: N open windows
  # each run this hook on every prompt, and N pushes of one day's alert is
  # how a useful alert becomes a muted one.
  local out2
  out2=$(PATH="$bin:$PATH" AD_TODAY=900 TERM_PROGRAM=ghostty \
         CLAUDE_COST_ALERT_TELEGRAM=0 bash "$hook" <<<'{"session_id":"SID-AD-OTHER","cwd":"/tmp/proj"}')
  assert_eq "a second window the same day says nothing" "" "$out2"

  # An ordinary day must stay silent. Asserted explicitly because a rule that
  # fires on everything is discovered immediately, and one that fires on
  # nothing is not discovered at all.
  sandbox_new AD2
  mkdir -p "$bin"
  local out3
  out3=$(PATH="$bin:$PATH" AD_TODAY=115 TERM_PROGRAM=ghostty \
         CLAUDE_COST_ALERT_TELEGRAM=0 bash "$hook" <<<"$payload")
  assert_eq "an ordinary day is silent" "" "$out3"

  # --report is what makes an unreachable limit visible, and it must run the
  # same computation the alert is gated on rather than a second copy of it.
  local rep
  rep=$(PATH="$bin:$PATH" AD_TODAY=115 bash "$hook" --report)
  assert_contains "the report states the limit" "limit:" "$rep"
  assert_contains "and the sample behind it" "prior day(s)" "$rep"
  assert_contains "and today, so the two can be compared" "115.00" "$rep"
  assert_contains "and says where that leaves you" "under limit" "$rep"
  # Money is dot-decimal regardless of locale: bash printf would reject these
  # values outright under en_ZA, and bare awk would print them with a comma
  # while the alert lines use a dot.
  assert_not_contains "no comma decimals from the locale" "115,00" "$rep"

  # Too small a sample must disable the alert rather than act on a sd
  # computed from three days.
  sandbox_new AD3
  mkdir -p "$bin"
  cat > "$bin/ccusage" <<'STUB2'
#!/usr/bin/env bash
sub="$1"; [ "$sub" = claude ] && sub="$2"
case "$sub" in
  session) printf '%s\n' '{"sessions":[]}' ;;
  daily)   python3 -c '
import json, datetime
today = datetime.date.today()
rows = [{"date": (today - datetime.timedelta(days=i)).isoformat(), "totalCost": 10.0}
        for i in range(1, 4)]
rows.append({"date": today.isoformat(), "totalCost": 5000.0})
print(json.dumps({"daily": rows}))' ;;
esac
STUB2
  chmod +x "$bin/ccusage"
  local out4 rep4
  out4=$(PATH="$bin:$PATH" TERM_PROGRAM=ghostty CLAUDE_COST_ALERT_TELEGRAM=0 \
         bash "$hook" <<<"$payload")
  assert_eq "three prior days raise no alert, however large today is" "" "$out4"
  # And says so, rather than reporting a limit nobody is enforcing.
  rep4=$(PATH="$bin:$PATH" bash "$hook" --report)
  assert_contains "the report admits the alert cannot fire" "NO DAILY ALERT POSSIBLE" "$rep4"
}
