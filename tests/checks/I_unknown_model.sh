# Check I -- a model the panel cannot price or size is never answered silently.
#
# Two separate silent-wrong-number risks, one per column:
#
#   Cost.    An id absent from PRICES was priced at DEFAULT_PRICE ($3/$15)
#            with no indication. A Claude Fable 5.1 turn at its real $10/$50
#            was therefore under-reported 3.3x, and looked like every other
#            row. It is still priced at the default -- excluding it would
#            silently understate the session total, which is worse -- but the
#            table now names the id underneath.
#   Context. The window used to default to 1M for anything unrecognised. Every
#            model in PRICES is 1M except Haiku 4.5 (verified against the
#            claude-api model table, cached 2026-06-24), so an unknown id is
#            by definition a model released after that table, whose window is
#            not guessable. It now returns 0 and the panel renders N/A.
check_I_unknown_model() {
  sandbox_new I
  local tp="$HOME/.claude/projects/test-project/sess.jsonl"

  # Known model first, as the control: without it, every assertion below
  # would also pass on a panel that simply rendered nothing.
  printf '%s\n' '{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}}}' > "$tp"
  load_panel 10 12 ""
  latest="$tp"
  session_stats_refresh
  assert_eq "a known model has a window" "1000000" "$SESS_WIN"
  assert_not_contains "and no estimate footnote" "estimated at default rates" "$SESS_TABLE"

  # Claude Fable 5.1 -- present in the price table, so it must behave like
  # any other known model rather than like the unknown case below.
  printf '%s\n' '{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"id":"m2","model":"claude-fable-5-1","usage":{"input_tokens":1000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' > "$tp"
  session_stats_refresh
  assert_eq "Fable 5.1 is priced at its own rate, not the default" "10.000000" "$SESS_COST"
  assert_eq "and has a window" "1000000" "$SESS_WIN"

  # An id from after the table was written.
  printf '%s\n' '{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"id":"m3","model":"claude-nonesuch-9","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' > "$tp"
  session_stats_refresh
  assert_eq "an unknown model reports no window" "0" "$SESS_WIN"
  assert_contains "and names itself as estimated" "claude-nonesuch-9" "$SESS_TABLE"
  assert_contains "under an explicit caveat" "estimated at default rates" "$SESS_TABLE"

  # The rendered line must say N/A, not 0%.
  local summary; summary=$(build_summary 2>/dev/null)
  assert_contains "the summary shows N/A for context" "Context Usage: N/A" "$summary"
  assert_not_contains "and never a percentage against an unknown window" "(0%)" "$summary"
}
