# Check AD -- the two daily control limits, and the ways each can be wrong.
#
# The session rule cannot see a day made of many ordinary sessions, which is
# what these exist for. But a control limit has a failure mode the session
# rule does not: it can become unreachable without anything announcing it.
# sd on this data is about the size of the mean, so the limit is set largely
# by the window's composition -- 30 days to 2026-09-09 gave $787 with one
# day above it, while the same rule on a rolling 14 days sits near $370. An
# alert that has drifted out of reach looks exactly like a quiet month, so
# the firing, the NOT-firing, and the report that distinguishes them are all
# asserted here.
#
# The projected ("bad day") rule has a second failure mode of its own: it
# depends on hourly buckets that only the PANEL writes. With no panel ever
# run there are no buckets, and the rule is not merely quiet -- it is off.
# That case is asserted too, because nothing else would ever surface it.
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
  assert_contains "a day over the runaway limit alerts" "DAILY SPEND" "$msg"
  assert_contains "and names today's figure" '$900.00' "$msg"
  assert_contains "and the limit it passed" "limit" "$msg"
  # The session in this fixture costs nothing, so the daily line is the only
  # one -- which is the point: the session rule could not have caught this.
  assert_not_contains "the session rule did not fire here" "COST ALERT" "$msg"
  # No plan reading anywhere: no bars, rather than empty ones.
  assert_not_contains "no plan reading draws no bars" "5h window" "$msg"

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
  assert_contains "the report states the bad-day limit" "bad day:" "$rep"
  assert_contains "and the runaway limit" "runaway:" "$rep"
  assert_contains "and the sample behind them" "day(s) worked" "$rep"
  assert_contains "and today, so they can be compared" "115.00" "$rep"
  assert_contains "and says where that leaves you" "under both limits" "$rep"
  # No panel has run in this sandbox, so there are no hourly buckets and the
  # bad-day rule is OFF. The report must say so outright rather than reading
  # like a quiet day.
  assert_contains "an unavailable projection is stated, not implied" \
    "UNAVAILABLE" "$rep"
  assert_contains "and says the bad-day alert cannot fire" \
    "cannot fire" "$rep"
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

  # ---- the bad-day rule, which needs the panel's hourly buckets ----------
  sandbox_new AD4
  mkdir -p "$bin"
  cat > "$bin/ccusage" <<'STUB4'
#!/usr/bin/env bash
sub="$1"; [ "$sub" = claude ] && sub="$2"
case "$sub" in
  session) printf '%s\n' '{"sessions":[]}' ;;
  daily)   python3 -c '
import json, datetime, os
today = datetime.date.today()
rows = [{"date": (today - datetime.timedelta(days=i)).isoformat(),
         "totalCost": 100.0 + (i % 3) * 10} for i in range(1, 15)]
rows.append({"date": today.isoformat(), "totalCost": float(os.environ["AD_TODAY"])})
print(json.dumps({"daily": rows}))' ;;
esac
STUB4
  chmod +x "$bin/ccusage"

  # Buckets shaped so that the CURRENT hour is always half way through a
  # typical day's spend, whenever this suite happens to run. Generated, not
  # fixed: a hardcoded hour makes the check pass in the morning and fail
  # after lunch.
  python3 - "$HOME/.cache/claude-hourly-buckets.json" <<'BUCKETS'
import datetime, json, sys
hour = datetime.datetime.now().hour
# 120 spread over the hours up to and including now, and 120 over the
# hours after, so the elapsed fraction is one half at any hour (all of it
# at 23:00) and comfortably above MIN_PROJECTION_ELAPSED. Uniform buckets
# put it at (hour+1)/24, under that floor before 06:00, and the check
# failed whenever the suite ran after midnight.
def bucket(h, avg):
    return {"hour": h, "avgCost": avg, "days": 14, "totalCost": avg * 14}
buckets = [bucket(h, 120.0 / (hour + 1)) for h in range(hour + 1)]
if hour < 23:
    buckets += [bucket(h, 120.0 / (23 - hour)) for h in range(hour + 1, 24)]
json.dump({"generatedAt": 0, "windowDays": 14, "buckets": buckets}, open(sys.argv[1], "w"))
BUCKETS

  # The spend to use is derived from the limits the hook itself reports,
  # not hardcoded. Two reasons, both learned the hard way: the exact sd
  # depends on the fixture, and the projection divides by the elapsed
  # fraction, which the buckets set and which is all of the day at 23:00 --
  # so a fixed figure would sit between the two limits at one hour and above
  # both at another. The fraction is read back from the buckets written above.
  local lim_bad lim_run target elapsed_frac spend_needed
  lim_bad=$(PATH="$bin:$PATH" AD_TODAY=0 bash "$hook" --report \
    | awk '/^bad day:/ {gsub(/\$/,"",$3); print $3}')
  lim_run=$(PATH="$bin:$PATH" AD_TODAY=0 bash "$hook" --report \
    | awk '/^runaway:/ {gsub(/\$/,"",$2); print $2}')
  assert_ne "the report yields a bad-day limit to aim at" "" "$lim_bad"
  assert_ne "and a runaway limit to stay under" "" "$lim_run"

  # Aim the PROJECTION between the two lines: over the bad-day one, under
  # the runaway one. That gap is precisely the case the bad-day rule exists
  # for and the runaway rule cannot catch in time.
  target=$(LC_ALL=C awk -v a="$lim_bad" -v b="$lim_run" 'BEGIN{printf "%.2f", (a+b)/2}')
  elapsed_frac=$(jq -r --argjson ch "$(( 10#$(date +%H) ))" '
    ([.buckets[] | select(.hour <= $ch) | .avgCost] | add) / ([.buckets[].avgCost] | add)
  ' "$HOME/.cache/claude-hourly-buckets.json")
  spend_needed=$(python3 -c "print(round($target*$elapsed_frac,2))")

  # The two --report calls above populated the hook's daily cache with
  # today=0, and that cache is good for HOOK_CACHE_TTL (120s) -- so without
  # this the firing run below reads a payload predating the spend it is
  # meant to react to and stays silent. Worth knowing outside the tests too:
  # today's figure the hook acts on can be up to two minutes old.
  rm -rf "$HOME/.cache/ccusage-panel-cache"

  # On a plan the alert carries the panel's three plan bars, each on a line
  # of its own. The reading is the one the usage-panel mod saved; this
  # sandbox has no Burst config, so the gateway is not asked.
  mkdir -p "$HOME/.claude/plugins/store"
  python3 - "$HOME/.claude/plugins/store/usage-panel_test.json" <<'LIMITS'
import json, sys, time
now = int(time.time())
json.dump({"limits": [{"key": "5h", "util": 0.42, "reset": now + 7200},
                      {"key": "7d", "util": 0.83, "reset": now + 3 * 86400}]}, open(sys.argv[1], "w"))
LIMITS

  local out5
  out5=$(PATH="$bin:$PATH" AD_TODAY="$spend_needed" TERM_PROGRAM=ghostty \
         CLAUDE_COST_ALERT_TELEGRAM=0 bash "$hook" <<<"$payload")
  local msg5; msg5=$(jq -r '.systemMessage' <<<"$out5")
  assert_contains "a day heading over the 2-sigma line alerts early" \
    "BAD DAY AHEAD" "$msg5"
  # Phrased as a forecast. It fires while the day can still be changed, and
  # a projection stated as fact is an alert people stop believing.
  assert_contains "and says so as a forecast" "heading for" "$msg5"
  assert_contains "and shows what is actually spent so far" "spent so far" "$msg5"
  assert_not_contains "without claiming the day is already over budget" \
    "DAILY SPEND" "$msg5"
  assert_contains "the 5h bar has its own line, green" $'\n🟢 5h ▰▰▰▰▱▱▱▱▱▱ 42% ' "$msg5"
  assert_contains "the weekly bar has its own line, yellow past 80%" $'\n🟡 week ▰▰▰▰▰▰▰▰▱▱ 83% ' "$msg5"
  # 4 of 7 days gone is 57%, so 83% used is 26 points ahead: red.
  assert_contains "the week's time against it, on its own line" $'\n🔴 time ▰▰▰▰▰▰▱▱▱▱ 57% +26' "$msg5"
  # One line of a phone each, about 27 characters: the emoji squares the
  # bars were first drawn with wrapped every row onto two or three lines.
  local longest
  longest=$(printf '%s\n' "$msg5" | tail -n 3 | python3 -c 'import sys; print(max(len(l.rstrip("\n")) for l in sys.stdin))')
  assert_eq "every bar row fits a phone's line" "1" "$([ "$longest" -le 27 ] && echo 1 || echo 0)"
  assert_contains "the model gets the figures in words" "Plan utilisation: 5h window 42% used, resets" \
    "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out5")"
  assert_contains "and the pace" "week gone 57% of the week, 26 over pace" \
    "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out5")"

  # Separate claims: the early warning must not consume the later one.
  assert_eq "the bad-day claim is taken" "1" \
    "$([ -d "$HOME/.cache/claude-cost-alert-state/daily-$(date +%Y-%m-%d)-projected" ] && echo 1 || echo 0)"
  assert_eq "the runaway claim is still available" "0" \
    "$([ -d "$HOME/.cache/claude-cost-alert-state/daily-$(date +%Y-%m-%d)-actual" ] && echo 1 || echo 0)"

  # Same day, now genuinely over the runaway line: the second, louder alert
  # must still be able to fire even though the early one already did.
  local out6
  rm -rf "$HOME/.cache/ccusage-panel-cache"
  out6=$(PATH="$bin:$PATH" AD_TODAY=900 TERM_PROGRAM=ghostty \
         CLAUDE_COST_ALERT_TELEGRAM=0 bash "$hook" <<<"$payload")
  assert_contains "the runaway alert still fires after the early one" \
    "DAILY SPEND" "$(jq -r '.systemMessage' <<<"$out6")"

  # A quiet day must not be talked into an alert by the projection.
  sandbox_new AD5
  mkdir -p "$bin"
  python3 - "$HOME/.cache/claude-hourly-buckets.json" <<'BUCKETS2'
import json, sys
buckets = [{"hour": h, "avgCost": 10.0, "days": 14, "totalCost": 140.0} for h in range(24)]
json.dump({"generatedAt": 0, "windowDays": 14, "buckets": buckets}, open(sys.argv[1], "w"))
BUCKETS2
  local out7
  rm -rf "$HOME/.cache/ccusage-panel-cache"
  out7=$(PATH="$bin:$PATH" AD_TODAY=30 TERM_PROGRAM=ghostty \
         CLAUDE_COST_ALERT_TELEGRAM=0 bash "$hook" <<<"$payload")
  assert_eq "a quiet day stays quiet with a projection available" "" "$out7"
}
