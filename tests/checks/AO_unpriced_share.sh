# Check AO -- an unpriced sliver of the day does not blank Today.
#
# Today is withheld (`?`) when a model ccusage cannot price ran today,
# because the missing part can be most of the day. On 2026-09-29 a one-line
# `claude -p --model sonnet` test (the alias had moved to claude-sonnet-5-5)
# blanked a whole day's total over a few cents. unpriced_share_pct weighs the unpriced
# models' tokens against the day's; under 1% the priced figure is shown with
# the gap named.
check_AO_unpriced_share() {
  sandbox_new AO
  load_panel 10 12 ""
  local day='{"daily":[{"modelBreakdowns":[
    {"modelName":"claude-opus-5-5","cost":400,"inputTokens":1000000,"outputTokens":200000,"cacheCreationTokens":2000000,"cacheReadTokens":90000000},
    {"modelName":"claude-sonnet-5-5","cost":0,"inputTokens":10,"outputTokens":5,"cacheCreationTokens":20000,"cacheReadTokens":0}]}]}'
  local pct
  pct=$(unpriced_share_pct "$day")
  assert_eq "a sliver is under 1%" "1" "$(awk -v p="$pct" 'BEGIN{print (p < 1)}')"
  assert_eq "and is still flagged unpriced" "claude-sonnet-5-5" "$(unpriced_models "$day")"

  local big='{"daily":[{"modelBreakdowns":[
    {"modelName":"claude-opus-5-5","cost":4,"inputTokens":1000,"outputTokens":200,"cacheCreationTokens":2000,"cacheReadTokens":9000},
    {"modelName":"claude-sonnet-5-5","cost":0,"inputTokens":1000000,"outputTokens":50000,"cacheCreationTokens":0,"cacheReadTokens":0}]}]}'
  pct=$(unpriced_share_pct "$big")
  assert_eq "most of the day is not a sliver" "0" "$(awk -v p="$pct" 'BEGIN{print (p < 1)}')"

  assert_eq "an unreadable report counts as all unpriced" "100" "$(unpriced_share_pct 'not json')"
}
