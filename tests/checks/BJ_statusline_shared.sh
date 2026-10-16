# Check BJ -- the status line reads the panel's shared cache, never scans.
#
# Claude Code's status line was `ccusage statusline`, a scan of the whole
# corpus whenever its per-session cache lapsed: five sessions ran it 17 times
# in two minutes on 16 Oct 2026, peaking at 477% CPU. Today's spend and the
# block are the same for every session, so claude-statusline.sh reads them
# from the files ccusage_cached writes, and fetches only when they are stale
# AND a transcript has changed, in the background, one caller at a time.
check_BJ_statusline_shared() {
  sandbox_new BJ
  local sl="$HOME_REAL_BIN/claude-statusline.sh"
  local dir="$HOME/.cache/ccusage-panel-cache"; mkdir -p "$dir"
  key() { printf '%s' "$*" | shasum -a 256 | cut -c1-16; }
  local today end
  today=$(date +%Y-%m-%d)
  end=$(date -u -v+2H -v+30M +%Y-%m-%dT%H:%M:00.000Z)
  printf '{"daily":[{"date":"%s","totalCost":1234.5}]}' "$today" > "$dir/$(key claude daily --json --offline).json"
  printf '{"blocks":[{"isActive":true,"costUSD":5.25,"endTime":"%s","burnRate":{"costPerHour":12.3,"tokensPerMinuteForIndicator":2500}}]}' \
    "$end" > "$dir/$(key claude blocks --active --json --offline).json"
  local tp="$HOME/.claude/projects/test-project/s1.jsonl"
  printf '{"type":"assistant","message":{"usage":{"input_tokens":4,"cache_creation_input_tokens":1000,"cache_read_input_tokens":150000,"output_tokens":9}}}\n' > "$tp"
  age_corpus 3600
  local in out
  in=$(jq -nc --arg t "$tp" '{model:{id:"claude-opus-5-5[1m]",display_name:"Opus 5.5 (1M context)"},cost:{total_cost_usd:22.5},transcript_path:$t}')

  out=$(printf '%s' "$in" | "$sl")
  assert_contains "session cost from Claude Code" '$22.50 session' "$out"
  assert_contains "today from the shared daily cache" '$1234.50 today' "$out"
  assert_contains "block cost and time left" '$5.25 block (2h ' "$out"
  assert_contains "burn rate and its label" '$12.30/hr (Moderate)' "$out"
  assert_contains "context from the transcript tail" '151,004 (15%)' "$out"
  sleep 0.5
  assert_eq "fresh cache: no ccusage run at all" "0" "$(grep -c . "$CCUSAGE_CALL_LOG")"

  # Stale but nothing written since: still no scan.
  age_file "$dir/$(key claude daily --json --offline).json" 600
  printf '%s' "$in" | "$sl" >/dev/null; sleep 0.5
  assert_eq "stale cache, unchanged corpus: no ccusage run" "0" "$(grep -c . "$CCUSAGE_CALL_LOG")"

  # Stale and a transcript moved: one background fetch, by one caller.
  printf '{}\n' >> "$tp"
  printf '{"daily":[{"date":"%s","totalCost":2000}]}' "$today" > "$CCUSAGE_FIXTURE_DIR/daily.json"
  printf '%s' "$in" | "$sl" >/dev/null & printf '%s' "$in" | "$sl" >/dev/null; wait
  sleep 1
  assert_eq "stale and changed: exactly one daily fetch" "1" "$(grep -c 'daily' "$CCUSAGE_CALL_LOG")"
  assert_contains "the fetch lands in the shared cache" '$2000.00 today' "$(printf '%s' "$in" | "$sl")"
}
