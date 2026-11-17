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

  # The forms the Session line uses, with no $(...), agree with these.
  local t fl
  panel_option_usd_v fl CLAUDE_PANEL_ALERT_MIN_USD "$MIN_SESSION_ALERT"
  assert_eq "panel_option_usd_v reads what panel_option_usd reads" "$(floor)" "$fl"
  tier_color_v t 20 8.2 1.5 2.0 "$fl"
  assert_eq "tier_color_v colours as tier_color does" "$(tier_color 20 8.2 1.5 2.0 "$fl")" "$t"
  printf 'CLAUDE_PANEL_ALERT_MIN_USD=25\n' > "$f"
  panel_option_usd_v fl CLAUDE_PANEL_ALERT_MIN_USD "$MIN_SESSION_ALERT"
  tier_color_v t 20 8.2 1.5 2.0 "$fl"
  assert_eq "and under the floor, green too" "$C_GREEN" "$t"
  : > "$f"

  # The panel uses the setting at the call site, not the hardcoded value.
  assert_contains "the Session line reads the setting" \
    'panel_option_usd_v min_usd CLAUDE_PANEL_ALERT_MIN_USD' "$(grep -n 'panel_option_usd_v min_usd' "$PANEL_SH")"
  assert_contains "and colours by it" \
    '"$min_usd"' "$(grep -n 'tier_color_v sc "$sess_amt"' "$PANEL_SH")"
}
