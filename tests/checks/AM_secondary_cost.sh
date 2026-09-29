# Check AM -- a turn claude-burst sent to its secondary shows the gateway's
# own price for it, and that price stays out of the Anthropic session total.
#
# Secondary rows used to render "?" in Cost even though the gateway logs
# api_equivalent_usd for every hop, priced from its own config. The figure
# is the secondary vendor's bill, so it belongs on the row and not in
# SESS_COST, which is Anthropic spend.
check_AM_secondary_cost() {
  sandbox_new AM
  local tp="$HOME/.claude/projects/test-project/sess.jsonl"
  mkdir -p "$HOME/.config/claude-burst"
  printf '%s\n%s\n' \
    '{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
    '{"type":"assistant","timestamp":"2026-09-01T10:05:00.000Z","message":{"id":"m2","model":"claude-opus-5","usage":{"input_tokens":139383,"output_tokens":111,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' > "$tp"
  printf '%s\n' '{"time":"2026-09-01T10:05:00.100Z","slot":"secondary","route":"together","model":"zai-org/GLM-5.3","input_tokens":139383,"output_tokens":111,"api_equivalent_usd":0.1956246}' \
    > "$HOME/.config/claude-burst/metrics.jsonl"
  load_panel 10 12 ""
  latest="$tp"
  session_stats_refresh
  assert_contains "the secondary turn is labelled with the model that served it" "GLM-5.3*" "$SESS_TABLE"
  assert_contains "and priced at the gateway's figure" '$0.20' "$SESS_TABLE"
  assert_contains "with the vendor named as the biller" "billed by together" "$SESS_TABLE"
  assert_eq "the session total is Anthropic spend only" "5.000000" "$SESS_COST"

  # An event from before the gateway logged a price still renders "?".
  printf '%s\n' '{"time":"2026-09-01T10:05:00.100Z","slot":"secondary","route":"together","model":"zai-org/GLM-5.3","input_tokens":139383,"output_tokens":111}' \
    > "$HOME/.config/claude-burst/metrics.jsonl"
  touch "$tp"; printf '\n' >> "$tp"
  session_stats_refresh
  assert_not_contains "a hop with no logged price invents none" '$0.20' "$SESS_TABLE"
  assert_eq "and still leaves the session total alone" "5.000000" "$SESS_COST"
}
