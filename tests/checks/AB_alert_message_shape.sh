# Check AB -- the cost alert's message keeps the shape its renderer imposes.
#
# `systemMessage` is not free-form. Measured against Claude Code 2.1.266 with
# a stub hook and `--output-format stream-json`, it arrives as a
# `{"type":"system","subtype":"informational"}` event in which EVERY line is
# rendered with a literal "UserPromptSubmit says: " prefix, and markdown is
# not interpreted. Two consequences, and this check is here because both are
# invisible in the source:
#
#   - one line per DISTINCT alert. An alert wrapped over three lines repeats
#     that prefix three times and pushes the figures off the right of a phone
#     screen -- which is the exact failure this message was reformatted to
#     fix, so a regression to multi-line would undo it silently.
#   - no markdown. `**RED**` arrives as four literal asterisks, so emphasis
#     has to come from emoji and caps.
#
# The whole point of the alert is to be read on a phone, where nobody is
# looking at the terminal to notice it has gone wrong.
check_AB_alert_message_shape() {
  sandbox_new AB
  local hook="$HOME_REAL_BIN/claude-cost-alert-check.sh"
  if [ ! -f "$hook" ]; then
    assert_eq "cost-alert hook is present to be checked" "1" "0"
    return
  fi

  # $20.00 against three sessions averaging $8.20 -> 2.4x, which is RED
  # (>2x, <3x) and well above MIN_SESSION_ALERT.
  #
  # These figures also pin the baseline fix, which is why they are not round:
  # the current session is excluded from the average it is judged against, so
  # the divisor is $8.20. Included, it would be $11.15 and this session would
  # come out at 1.8x -- yellow, and the hook is deliberately silent on yellow.
  # Getting that wrong does not misreport the alert, it deletes it.
  printf '%s\n' '{"sessions":[{"period":"S1","totalCost":8.0},{"period":"S2","totalCost":8.0},{"period":"S3","totalCost":8.6},{"period":"SID-AB","totalCost":20.00}]}' \
    > "$CCUSAGE_FIXTURE_DIR/session.json"

  # The phone push is check AC's subject. Opted out here (silently, by
  # design) so this check reads the alert lines and not the operator notice
  # an unconfigured push would legitimately add.
  local out
  out=$(TERM_PROGRAM=ghostty CLAUDE_COST_ALERT_TELEGRAM=0 bash "$hook" <<< '{"session_id":"SID-AB"}')
  assert_ne "the hook fires on a red session" "" "$out"

  local msg
  msg=$(jq -r '.systemMessage' <<<"$out")

  assert_eq "one line per alert, and only one alert is active" "1" \
    "$(printf '%s\n' "$msg" | wc -l | tr -d ' ')"
  assert_contains "the severity word survives" "COST ALERT" "$msg"
  assert_contains "the session's own figure is in it" '$20.00' "$msg"
  assert_contains "so is the multiple, which is the actionable number" "2.4x" "$msg"
  assert_contains "the baseline excludes this session" '$8.20 average' "$msg"

  # Markdown is inert in this renderer, so any of it in the message is a
  # literal artefact rather than emphasis.
  assert_not_contains "no markdown bold" '**' "$msg"
  assert_not_contains "no markdown code spans" '`' "$msg"

  # The prefix eats ~23 columns before the message even starts, so the
  # figures have to be near the front to survive a phone's truncation.
  assert_eq "the money appears in the first 40 characters" "1" \
    "$(awk -v s="$msg" 'BEGIN{print (index(substr(s,1,40), "$") > 0) ? 1 : 0}')"

  # Desktop notification is additive; it must never be the only channel, and
  # OSC 777 must not leak into terminals that would print it as text.
  local seq
  seq=$(jq -r '.hookSpecificOutput.terminalSequence' <<<"$out")
  assert_contains "ghostty gets an OSC 777 desktop notification" "]777;notify;" "$seq"
  # OSC 777 is ';'-delimited -- `]777;notify;<title>;<body>`, so exactly four
  # fields. A semicolon in the body adds a fifth and truncates the popup.
  assert_eq "no semicolon inside the notification body" "4" \
    "$(awk -v s="$seq" 'BEGIN{n=split(s,a,";"); print n}')"

  local seq_other
  seq_other=$(TERM_PROGRAM=Apple_Terminal CLAUDE_COST_ALERT_TELEGRAM=0 bash "$hook" <<< '{"session_id":"SID-AB2"}' \
    | jq -r '.hookSpecificOutput.terminalSequence')
  assert_not_contains "other terminals get no OSC 777 to print as text" "777" "$seq_other"

  # additionalContext goes to the model, which correctly refuses instructions
  # arriving from tool/hook output -- verified: a context asking for a
  # PushNotification was declined as untrusted. So it must stay descriptive;
  # an imperative there is a channel that reports success and does nothing.
  local ctx
  ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out")
  assert_contains "the model is told the figures" '$20.00' "$ctx"
  assert_not_contains "but is not instructed to notify" "PushNotification" "$ctx"
}
