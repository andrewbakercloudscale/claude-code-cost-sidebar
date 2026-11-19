# Check BR -- a transcript is read from where the last read stopped.
#
# Identity, today's tokens and the turn table each re-read the WHOLE
# transcript whenever it changed, which is every tick while a session works:
# 1.6 CPU-s a tick on a 102MB transcript on 2026-11-19, in every panel
# showing a busy session. panel_parse_py keeps each one's state and the byte
# offset it reached, and reads only what was appended. That is only right if
# it gives what a full read gives, so every answer here is compared with a
# cold read (an empty state directory) of the same bytes, and the resume is
# proved by changing an early byte the resumed read must NOT see.
#
# Covered: resume after an append, a cut in the middle of a line, a file
# that got smaller, a rewrite under the saved offset, another inode, a panel
# script change, today's tokens across a day change, the turn table writing
# the identity entry, and the empty error log left behind by a panel.
br_line() { # $1 = message id, $2 = timestamp, $3 = input tokens, $4 = cwd
  printf '{"type":"assistant","timestamp":"%s","requestId":"r-%s","cwd":"%s","message":{"id":"%s","model":"claude-opus-5-5","usage":{"input_tokens":%d,"output_tokens":7,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}}}\n' \
    "$2" "$1" "$4" "$1" "$3"
}
br_cold() { # $1 = mode, $2... = its arguments: the answer of a full read
  local d="$SBX/cold.$RANDOM"
  mkdir -p "$d"
  CCUSAGE_CACHE_DIR="$d" panel_parse_py "$@" 2>&1
  rm -rf "$d"
}
br_warm() { # the answer of a read resumed from the sandbox's own state
  CCUSAGE_CACHE_DIR="$BR_STATE" panel_parse_py "$@" 2>&1
}
br_all_same() { # $1 = label, $2 = transcript, $3 = today: all three modes, warm vs cold
  local m warm cold
  for m in identity todaytok turns; do
    case "$m" in
      identity) warm=$(br_warm identity "$2"); cold=$(br_cold identity "$2") ;;
      todaytok) warm=$(br_warm todaytok "$2" "$3"); cold=$(br_cold todaytok "$2" "$3") ;;
      turns) warm=$(br_warm turns "$2" "${BR_TARGS[@]}"); cold=$(br_cold turns "$2" "${BR_TARGS[@]}") ;;
    esac
    assert_eq "$1: $m resumed is $m read whole" "$cold" "$warm"
  done
}
check_BR_incremental_parse() {
  sandbox_new BR
  load_panel 10 12 ""
  BR_STATE="$SBX/state"
  mkdir -p "$BR_STATE"
  BR_TARGS=(12 "" "" "" "" "" "" "" "" "" 30 50 70 1.5 2.0 1000 "" series)
  local tp="$HOME/.claude/projects/-br" t full i cut out
  mkdir -p "$tp/b1/subagents"
  t="$tp/b1.jsonl"
  full="$SBX/full.jsonl"
  {
    br_line m1 2026-11-18T23:00:00.000Z 100 /x/alpha
    br_line m2 2026-11-19T08:00:00.000Z 200 /x/alpha
    printf '{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-19T08:30:00Z"}\n'
    printf '{"type":"user","message":{"role":"user","content":"The earlier part of this conversation was compacted by claude-burst to save context."}}\n'
    br_line m3 2026-11-19T09:00:00.000Z 300 /x/alpha
    printf 'not json at all "usage" "assistant"\n'
    # m3 again, larger: today's tokens keep the larger copy.
    br_line m3 2026-11-19T09:00:01.000Z 900 /x/alpha
    printf '{"type":"assistant","timestamp":"2026-11-19T09:30:00.000Z","message":{"id":"m4","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}\n'
    br_line m5 2026-11-19T10:00:00.000Z 500 /x/alpha
  } > "$full"
  br_line s1 2026-11-19T09:10:00.000Z 50 /x/alpha > "$tp/b1/subagents/agent-a.jsonl"

  # The cold answers are the ones a full read gives, and say what is in it.
  cp "$full" "$t"
  assert_contains "a full read: identity" $'b1\tclaude-opus-5-5\tOpus 5.5\talpha\t' "$(br_cold identity "$t")"
  # m2 200+1207, m3 900+1207 (largest copy), m5 500+1207, subagent 50+1207.
  assert_eq "a full read: today's tokens" "6478" "$(br_cold todaytok "$t" 2026-11-19)"
  assert_contains "a full read: the Burst compaction row" "Async Full Compaction" "$(br_cold turns "$t" "${BR_TARGS[@]}")"

  # Resume: the first lines, then the rest appended.
  head -n 3 "$full" > "$t"
  br_all_same "first three lines" "$t" 2026-11-19
  cat "$full" > "$t"
  br_all_same "the rest appended" "$t" 2026-11-19
  assert_eq "state kept for the session and its tokens" "2" \
    "$(ls "$BR_STATE"/inc-*.json 2>/dev/null | wc -l | tr -d ' ')"

  # Proof it resumed rather than re-read: the first line's folder changed in
  # place, same length, far before the saved offset. A full read sees it,
  # the resumed one must not; then one appended line reaches it as usual.
  LC_ALL=C sed 's|/x/alpha|/x/omega|' "$full" > "$SBX/omega.jsonl"
  cat "$SBX/omega.jsonl" > "$t"
  assert_contains "a full read sees the rewritten first line" $'\tomega\t' "$(br_cold identity "$t")"
  assert_contains "the resumed read did not re-read it" $'\talpha\t' "$(br_warm identity "$t")"
  br_line m6 2026-11-19T11:00:00.000Z 600 /x/omega >> "$t"
  assert_contains "and it reads what was appended" "Turn" "$(br_warm turns "$t" "${BR_TARGS[@]}")"
  assert_eq "the appended turn is in the table" "5" \
    "$(br_warm turns "$t" "${BR_TARGS[@]}" | grep -c '^  [0-9]')"

  # A script change (the panel's mtime is in the state) starts again.
  out=$(PANEL_SELF_MTIME=1 br_warm identity "$t")
  assert_contains "another panel script reads from the top" $'\tomega\t' "$out"

  # A cut in the middle of a line, at every byte of one line: the partial
  # line counts as a full read of those bytes counts it, and is read whole
  # once it is finished.
  rm -f "$BR_STATE"/inc-*.json
  cat "$full" > "$t"
  local len3 len5 bad=0 n=0 m warm cold
  len3=$(head -n 4 "$full" | wc -c | tr -d ' ')
  len5=$(head -n 5 "$full" | wc -c | tr -d ' ')
  for (( cut = len3 - 1; cut <= len5 + 1; cut += 7 )); do
    head -c "$cut" "$full" > "$t"
    for m in identity todaytok turns; do
      case "$m" in
        identity) warm=$(br_warm identity "$t"); cold=$(br_cold identity "$t") ;;
        todaytok) warm=$(br_warm todaytok "$t" 2026-11-19); cold=$(br_cold todaytok "$t" 2026-11-19) ;;
        turns) warm=$(br_warm turns "$t" "${BR_TARGS[@]}"); cold=$(br_cold turns "$t" "${BR_TARGS[@]}") ;;
      esac
      n=$(( n + 1 ))
      [ "$warm" = "$cold" ] || { bad=$(( bad + 1 )); printf '    cut at %s: %s differs\n' "$cut" "$m" >&2; }
    done
  done
  assert_eq "cut mid-line at $n points, resumed is whole" 0 "$bad"
  assert_ne "the cuts covered something" 0 "$n"
  cat "$full" > "$t"
  br_all_same "finished after the cuts" "$t" 2026-11-19

  # Smaller: a rewind or a rewrite left fewer bytes.
  head -n 2 "$full" > "$t"
  br_all_same "the file got smaller" "$t" 2026-11-19
  cat "$full" > "$t"
  br_all_same "and grew again" "$t" 2026-11-19

  # Rewritten under the saved offset, same length: the fingerprint of the
  # bytes before it (the last 64) no longer matches, so it reads from the
  # top. The change is in the last line's final 64 bytes.
  LC_ALL=C sed '$ s|"cache_creation_input_tokens":200|"cache_creation_input_tokens":300|' "$full" > "$SBX/rw.jsonl"
  cat "$SBX/rw.jsonl" > "$t"
  br_all_same "rewritten just under the offset" "$t" 2026-11-19
  assert_eq "the rewritten count is the one read" "6578" "$(br_warm todaytok "$t" 2026-11-19)"

  # Another file in its place (a new inode), same bytes.
  rm -f "$t"; cp "$full" "$t"
  br_all_same "replaced by another file" "$t" 2026-11-19

  # A corrupt state is ignored.
  for i in "$BR_STATE"/inc-*.json; do printf '{"tag":' > "$i"; done
  br_all_same "corrupt state" "$t" 2026-11-19

  # Today's tokens: a new day starts again, and so does going back.
  assert_eq "the 18th from the state of the 19th" "$(br_cold todaytok "$t" 2026-11-18)" "$(br_warm todaytok "$t" 2026-11-18)"
  assert_eq "the 18th has only m1" "1307" "$(br_warm todaytok "$t" 2026-11-18)"
  assert_eq "back to the 19th" "6478" "$(br_warm todaytok "$t" 2026-11-19)"
  # A subagent's own offset: one appended to, one new.
  br_line s2 2026-11-19T09:20:00.000Z 10 /x/alpha >> "$tp/b1/subagents/agent-a.jsonl"
  br_line s3 2026-11-19T09:30:00.000Z 20 /x/alpha > "$tp/b1/subagents/agent-b.jsonl"
  assert_eq "subagents appended and added" "$(br_cold todaytok "$t" 2026-11-19)" "$(br_warm todaytok "$t" 2026-11-19)"
  assert_eq "and the count is theirs" "8922" "$(br_warm todaytok "$t" 2026-11-19)"
  rm -f "$tp/b1/subagents/agent-b.jsonl"
  assert_eq "a subagent gone: read again" "7695" "$(br_warm todaytok "$t" 2026-11-19)"

  # One python for identity and the table: the table's run writes the
  # identity entry, and it is the line the identity scan gives.
  rm -f "$CCUSAGE_CACHE_DIR"/sessid-*.tsv "$CCUSAGE_CACHE_DIR"/turns-*.out
  local idl=""
  turn_table_series_v _ "$t"
  session_identity_hit_v idl "$t" && _pass || _fail "the table's run wrote the identity entry" "a hit" "a miss"
  assert_eq "and it is identity's own line" "$(br_cold identity "$t")" "$idl"

  # An empty error log from a panel with no terminal is removed when it
  # exits; the prune takes an empty one after a day, a full one after a week.
  local pid ef
  ( cd /tmp && CLAUDE_PANEL_GHOSTTY_PID=0 SLOW_REFRESH=600 exec bash "$PANEL_SH" 10 12 "" \
      </dev/null >/dev/null 2>&1 ) &
  pid=$!
  ef="$CCUSAGE_CACHE_DIR/errors-$pid.log"
  for (( i = 0; i < 100; i++ )); do [ -e "$ef" ] && break; sleep 0.1; done
  [ -e "$ef" ] && _pass || _fail "the panel made its error log" "$ef" "absent"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  local cpid=""
  { IFS= read -r cpid < "$CCUSAGE_CACHE_DIR/collector/lock/pid"; } 2>/dev/null
  [ -n "$cpid" ] && kill "$cpid" 2>/dev/null
  [ ! -e "$ef" ] && _pass || _fail "an empty error log goes when its panel exits" "removed" "$(ls -l "$ef" 2>&1)"
  : > "$CCUSAGE_CACHE_DIR/errors-1.log"; age_file "$CCUSAGE_CACHE_DIR/errors-1.log" 90000
  printf 'x\n' > "$CCUSAGE_CACHE_DIR/errors-2.log"; age_file "$CCUSAGE_CACHE_DIR/errors-2.log" 90000
  : > "$CCUSAGE_CACHE_DIR/errors-3.log"
  load_panel 10 12 ""
  [ ! -e "$CCUSAGE_CACHE_DIR/errors-1.log" ] && _pass || _fail "an empty error log a day old is pruned" "gone" "kept"
  [ -e "$CCUSAGE_CACHE_DIR/errors-2.log" ] && _pass || _fail "one with errors in it is kept for the week" "kept" "gone"
  [ -e "$CCUSAGE_CACHE_DIR/errors-3.log" ] && _pass || _fail "an empty one from today is kept" "kept" "gone"
}
