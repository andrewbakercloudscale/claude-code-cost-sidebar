
# Check BE -- the day's costliest turns, across sessions, for the mod.
#
# ccusage has no per-turn figure, so the headless panel reads the turns of
# every transcript written to today and keeps the dearest that began since
# midnight. Its failure modes are quiet ones: yesterday's turns in a file
# touched today counted as today's, or a session other than this one left
# out, would both draw a plausible list.
check_BE_top_turns() {
  sandbox_new BE
  load_panel 10 12 ""
  local a="aaaaaaaa-bbbb-cccc-dddd-00000000000a" b="aaaaaaaa-bbbb-cccc-dddd-00000000000b"
  local pa="$HOME/.claude/projects/-work-alpha" pb="$HOME/.claude/projects/-work-beta"
  mkdir -p "$pa" "$pb"
  local now old
  now=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
  old=$(date -u -v-3d '+%Y-%m-%dT%H:%M:%S.000Z')
  turn() { # id, timestamp, cwd, cache write tokens
    printf '{"type":"assistant","timestamp":"%s","cwd":"%s","message":{"id":"%s","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":%s}}}\n' "$2" "$3" "$1" "$4"
  }
  { turn m1 "$now" /work/alpha 200; turn m2 "$now" /work/alpha 90000; } > "$pa/$a.jsonl"
  # Written to today, but its dear turn is three days old.
  { turn n1 "$old" /work/beta 500000; turn n2 "$now" /work/beta 30000; } > "$pb/$b.jsonl"

  top_turns_refresh
  assert_eq "today's turns only" "3" "$(jq 'length' <<<"$TOP_TURNS_JSON")"
  assert_eq "and how many there were today, for the day's average" "3" "$TODAY_TURNS"
  awk -v u="$TODAY_TURNS_USD" 'BEGIN{exit !(u > 0)}' && _pass || _fail "with what they cost together" "> 0" "$TODAY_TURNS_USD"
  assert_eq "dearest first, from whichever session" "$a" "$(jq -r '.[0].sid' <<<"$TOP_TURNS_JSON")"
  assert_eq "its turn number" "2" "$(jq -r '.[0].turn' <<<"$TOP_TURNS_JSON")"
  assert_eq "its folder" "alpha" "$(jq -r '.[0].folder' <<<"$TOP_TURNS_JSON")"
  assert_eq "then the other session's" "$b" "$(jq -r '.[1].sid' <<<"$TOP_TURNS_JSON")"
  assert_eq "a turn from before midnight is not today's" "0" "$(jq '[.[] | select(.sid == "'"$b"'" and .turn == 1)] | length' <<<"$TOP_TURNS_JSON")"
  local dear cheap
  dear=$(jq '.[0].cost' <<<"$TOP_TURNS_JSON"); cheap=$(jq '.[2].cost' <<<"$TOP_TURNS_JSON")
  awk -v d="$dear" -v c="$cheap" 'BEGIN{exit !(d > c && c > 0)}' && _pass || _fail "costs are priced and ordered" "dear > cheap > 0" "$dear, $cheap"

  # A resumed session's transcript repeats the turns it came from: the same
  # turn is listed once, under the transcript written to last.
  local c="aaaaaaaa-bbbb-cccc-dddd-00000000000c"
  sleep 1
  cp "$pa/$a.jsonl" "$pa/$c.jsonl"
  top_turns_refresh
  assert_eq "a turn copied into a resumed session is listed once" "3" "$(jq 'length' <<<"$TOP_TURNS_JSON")"
  assert_eq "under the session still being written" "$c" "$(jq -r '.[0].sid' <<<"$TOP_TURNS_JSON")"
  rm -f "$pa/$c.jsonl"
  top_turns_refresh

  # And it reaches the mod's file.
  local sid="$a"
  mkdir -p "$MOD_DIR"
  PANEL_HEADLESS=1 PIN_SESSION_ID="$sid" resolve_session
  session_stats_refresh
  printf '%s' '{"daily":[]}' > "$SBX/recent.json"
  printf '%s' '{"session":[]}' > "$SBX/all.json"
  MJ_RECENT_FILE="$SBX/recent.json" MJ_ALL_SESS_FILE="$SBX/all.json" mod_json_write "$sid"
  assert_eq "the mod's file carries them" "3" "$(jq '.top_turns | length' "$MOD_DIR/$sid.json")"
  assert_eq "and the day's turn count" "3" "$(jq '.today.turns' "$MOD_DIR/$sid.json")"

  # Why a turn was dear: each row carries its cache hit, what it wrote, its
  # reply's size and the turn before it in the same session.
  assert_eq "a row carries what it wrote" "90000" "$(jq '.[0].delta' <<<"$TOP_TURNS_JSON")"
  assert_eq "its reply's size" "50" "$(jq '.[0].out' <<<"$TOP_TURNS_JSON")"
  assert_eq "the context of the turn before it" "1300" "$(jq '.[0].prev' <<<"$TOP_TURNS_JSON")"
  assert_eq "and how long after it" "0" "$(jq '.[0].gap' <<<"$TOP_TURNS_JSON")"
  assert_eq "a session's first turn has none before it" "null" "$(jq -c '[.[] | select(.sid == "'"$a"'" and .turn == 1)][0].gap' <<<"$TOP_TURNS_JSON")"
  assert_eq "no pause today, nothing lost" "0" "$CACHE_LOSS_TURNS"

  # A pause: a turn 20 minutes after the one before it, the context still
  # there and written again. 50k tokens at Opus 5.5's $5 to write against
  # $0.20 to read is $0.24 lost. The day goes on file.
  local p="aaaaaaaa-bbbb-cccc-dddd-00000000000d" pp="$HOME/.claude/projects/-work-gamma" at before after
  mkdir -p "$pp"
  at=$(date '+%s')
  before=$(date -u -r $((at - 1200)) '+%Y-%m-%dT%H:%M:%S.000Z')
  after=$(date -u -r "$at" '+%Y-%m-%dT%H:%M:%S.000Z')
  { turn p1 "$before" /work/gamma 50000; turn p2 "$after" /work/gamma 50000; } > "$pp/$p.jsonl"
  top_turns_refresh
  assert_eq "the turn after a pause is counted" "1" "$CACHE_LOSS_TURNS"
  assert_eq "at what writing the cache again cost over reading it" "0.240000" "$CACHE_LOSS_USD"
  assert_eq "its row says how long the pause was" "1200" "$(jq '[.[] | select(.sid == "'"$p"'" and .turn == 2)][0].gap' <<<"$TOP_TURNS_JSON")"
  assert_eq "the day is kept on file" "$(date '+%Y-%m-%d')	1	0.240000" "$(cat "$CACHE_LOSS_FILE")"
  # An earlier day on file is added to the total, and a day's figure does
  # not shrink when its session's early turns leave the series.
  printf '2020-01-01\t2\t1.000000\n%s\t3\t0.500000\n' "$(date '+%Y-%m-%d')" > "$CACHE_LOSS_FILE"
  top_turns_refresh
  assert_eq "today keeps the larger figure" "0.500000" "$CACHE_LOSS_USD"
  assert_eq "the total is every day on file" "1.500000" "$CACHE_LOSS_30"
  assert_eq "and says how many days that is" "2" "$CACHE_LOSS_DAYS"
  MJ_RECENT_FILE="$SBX/recent.json" MJ_ALL_SESS_FILE="$SBX/all.json" mod_json_write "$sid"
  assert_eq "the mod's file carries the day's loss" "0.5" "$(jq '.today.cache_loss' "$MOD_DIR/$sid.json")"
  assert_eq "and the total" "1.5" "$(jq '.today.cache_loss_30' "$MOD_DIR/$sid.json")"
  rm -f "$pp/$p.jsonl" "$CACHE_LOSS_FILE"

  # No transcript today: an empty list, not an error.
  rm -f "$pa/$a.jsonl" "$pb/$b.jsonl"
  top_turns_refresh
  assert_eq "nothing today is an empty list" "[]" "$TOP_TURNS_JSON"
}
