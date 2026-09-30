# Check AT -- the panel's Session colour obeys the same floor as the chat alert.
#
# CLAUDE_PANEL_ALERT_MIN_USD (the dashboard's "Session alert only above")
# was read by the alert hook only; the panel hardcoded $5, so raising the
# setting quietened the alert while the Session line still turned red.
check_AT_panel_alert_floor() {
  sandbox_new AT
  load_panel 10 12 ""
  local f="$HOME/.config/claude-panel/options"
  mkdir -p "$(dirname "$f")"
  floor() { panel_option_usd CLAUDE_PANEL_ALERT_MIN_USD "$MIN_SESSION_ALERT"; }

  : > "$f"
  assert_eq "no setting: the \$5 default" "5.00" "$(floor)"
  printf 'CLAUDE_PANEL_ALERT_MIN_USD=25\n' > "$f"
  assert_eq "a set floor is read" "25" "$(floor)"
  printf 'CLAUDE_PANEL_ALERT_MIN_USD="19.50"\n' > "$f"
  assert_eq "quoted with cents" "19.50" "$(floor)"
  printf 'CLAUDE_PANEL_ALERT_MIN_USD=lots\n' > "$f"
  assert_eq "garbage falls back to the default" "5.00" "$(floor)"
  printf 'CLAUDE_PANEL_ALERT_MIN_USD=1.2.3\n' > "$f"
  assert_eq "two points falls back too" "5.00" "$(floor)"

  # \$20 against an \$8.20 average is 2.4x: red above a \$5 floor, green
  # (uncoloured) below a \$25 one, exactly as the alert hook decides.
  printf 'CLAUDE_PANEL_ALERT_MIN_USD=25\n' > "$f"
  assert_eq "under the floor: green" "$C_GREEN" "$(tier_color 20 8.2 1.5 2.0 "$(floor)")"
  : > "$f"
  assert_not_contains "over the default floor: not green" "$C_GREEN" "$(tier_color 20 8.2 1.5 2.0 "$(floor)")"

  # The panel uses the setting at the call site, not the hardcoded value.
  assert_contains "the Session line reads the setting" \
    'panel_option_usd CLAUDE_PANEL_ALERT_MIN_USD' "$(grep -n 'sc=$(tier_color "$sess_amt"' "$PANEL_SH")"
}
