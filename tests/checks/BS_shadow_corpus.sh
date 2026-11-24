# Check BS -- the collector's live reports come from a shadow corpus.
#
# Every ccusage run reads every transcript (3.7GB, 2.4 CPU-s on 2026-11-20),
# and daily and blocks --active ran every two minutes. The collector now
# keeps a copy holding only the lines from local midnight yesterday on
# (shadow_py), runs those two on it, takes older days from one full daily
# run a day and sums weekly and monthly from the merged rows. That is only
# right if the shadow holds exactly what it should, so every shadow file
# here is compared with the source's lines filtered by hand.
#
# Covered here: a first build, appends, a line still being written, the
# resume (an early byte changed in place must NOT be seen), subagents, a
# file that shrank, another inode, a rewrite under the offset, a deleted
# file, a state left "building" or corrupt, and the daily roll. Check BT
# covers the block proof, the reports and the fallbacks, with the helpers
# defined here.
bs_iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z; }
bs_line() { # $1 = id, $2 = epoch, $3 = input tokens
  printf '{"type":"assistant","timestamp":"%s","requestId":"r-%s","message":{"id":"%s","model":"claude-opus-5-5","usage":{"input_tokens":%d,"output_tokens":7}}}\n' \
    "$(bs_iso "$2")" "$1" "$1" "$3"
}
# Appends a line to a transcript, and to its expected shadow when the line's
# time is at or after S.
bs_add() { # $1 = transcript, $2 = id, $3 = epoch, $4 = tokens
  local l
  l=$(bs_line "$2" "$3" "$4")
  printf '%s\n' "$l" >> "$1"
  (( $3 >= BS_S )) && printf '%s\n' "$l" >> "$1.want"
  return 0
}
bs_sync() {
  SHADOW_NOW="$BS_NOW" shadow_py "$HOME/.claude/projects" "$SHADOW_DIR" "" "" "" "" 2>&1
}
bs_shadow_of() { # $1 = transcript: its shadow file's text, or ABSENT
  local p="$SHADOW_DIR/root/projects/${1#"$HOME/.claude/projects/"}"
  if [ -f "$p" ]; then cat "$p"; else printf 'ABSENT'; fi
}
bs_same() { # $1 = label, $2 = transcript: its shadow is its .want
  local want=""
  [ -f "$2.want" ] && want=$(cat "$2.want")
  [ -n "$want" ] || want=ABSENT
  assert_eq "$1" "$want" "$(bs_shadow_of "$2")"
}
bs_row() { # $1 = date, $2 = cost, $3 = model: one daily row as ccusage gives it
  jq -cn --arg d "$1" --argjson c "$2" --arg m "$3" '{date: $d, inputTokens: ($c * 2), outputTokens: $c,
    cacheCreationTokens: 0, cacheReadTokens: ($c * 7), totalTokens: ($c * 10), totalCost: $c,
    modelsUsed: [$m], modelBreakdowns: [{modelName: $m, inputTokens: ($c * 2), outputTokens: $c,
    cacheCreationTokens: 0, cacheReadTokens: ($c * 7), cost: $c}]}'
}

check_BS_shadow_corpus() {
  sandbox_new BS
  load_panel 10 12 ""
  local d18 d19 out p t sub old early
  d18=$(local_midnight 2026-11-18)
  d19=$(local_midnight 2026-11-19)
  BS_S=$d18
  BS_NOW=$(( d19 + 15 * 3600 ))
  p="$HOME/.claude/projects/-bs"
  t="$p/s1.jsonl"
  sub="$p/s1/subagents/agent-a.jsonl"
  old="$p/old.jsonl"
  mkdir -p "$p/s1/subagents"

  # ---- a first build ----
  bs_add "$t" a1 $(( BS_S - 3600 )) 100
  bs_add "$t" a2 $(( BS_S + 600 )) 200
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"hi"}}\n' "$(bs_iso $(( BS_S + 700 )))" | tee -a "$t" >> "$t.want"
  printf '{"type":"summary","summary":"no timestamp here"}\n' >> "$t"
  # An old top-level time with a new one inside it: kept (a superset is
  # harmless, a missing entry is not).
  printf '{"type":"user","timestamp":"%s","toolUseResult":{"timestamp":"%s"}}\n' \
    "$(bs_iso $(( BS_S - 60 )))" "$(bs_iso $(( BS_S + 60 )))" | tee -a "$t" >> "$t.want"
  bs_add "$t" a3 $(( BS_S + 7200 )) 300
  bs_add "$sub" s1 $(( BS_S + 800 )) 50
  bs_add "$old" o1 $(( BS_S - 86400 )) 10
  age_file "$old" $(( BS_NOW - BS_S + 7200 ))
  out=$(bs_sync)
  assert_contains "a first build" "ok " "$out"
  assert_contains "it says it built" "rebuild" "$out"
  assert_contains "the first exact day is the day of S" " 2026-11-18 " "$out"
  bs_same "first build: the lines from S on" "$t"
  bs_same "first build: a subagent's lines, at its own path" "$sub"
  bs_same "first build: a file last written before S is not copied" "$old"

  # ---- appends, and a line still being written ----
  bs_add "$t" a4 $(( BS_NOW - 600 )) 400
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"a5"' "$(bs_iso $(( BS_NOW - 300 )))" >> "$t"
  out=$(bs_sync)
  assert_contains "an append" "append" "$out"
  bs_same "the appended line, not the partial one" "$t"
  printf ',"model":"claude-opus-5-5","usage":{"input_tokens":5,"output_tokens":7}}}\n' >> "$t"
  tail -n 1 "$t" >> "$t.want"
  bs_sync >/dev/null
  bs_same "the partial line once it is finished" "$t"
  bs_add "$sub" s2 $(( BS_NOW - 200 )) 60
  bs_add "$p/s1/subagents/agent-b.jsonl" s3 $(( BS_NOW - 100 )) 70
  bs_sync >/dev/null
  bs_same "a subagent appended to" "$sub"
  bs_same "a new subagent" "$p/s1/subagents/agent-b.jsonl"

  # Proof it resumed rather than re-read: a2's tokens changed in place, same
  # length, far before the saved offset. The shadow keeps what it read.
  early=$(LC_ALL=C sed 's/"input_tokens":200/"input_tokens":999/' "$t")
  printf '%s\n' "$early" > "$t"
  bs_add "$t" a6 $(( BS_NOW - 60 )) 600
  bs_sync >/dev/null
  assert_contains "the resumed sync did not re-read the start" '"input_tokens":200' "$(bs_shadow_of "$t")"
  assert_contains "and it read what was appended" '"id":"a6"' "$(bs_shadow_of "$t")"
  # From here the file's own text is what is expected.
  printf '%s\n' "$early" > "$t.src"
  bs_line a6 $(( BS_NOW - 60 )) 600 >> "$t.src"
  LC_ALL=C sed 's/"input_tokens":200/"input_tokens":999/' "$t.want" > "$t.want2"

  # ---- smaller, another inode, rewritten under the offset, deleted ----
  head -n 3 "$t.src" > "$t"
  head -n 3 "$t.src" | while IFS= read -r line; do
    case "$line" in *'"id":"a1"'*|*'no timestamp'*) ;; *) printf '%s\n' "$line" ;; esac
  done > "$t.want"
  bs_sync >/dev/null
  bs_same "a file that got smaller is read again" "$t"
  rm -f "$t"
  cp "$t.src" "$t"
  cp "$t.want2" "$t.want"
  bs_sync >/dev/null
  bs_same "another file in its place is read again" "$t"
  LC_ALL=C sed '$ s/"input_tokens":600/"input_tokens":601/' "$t.src" > "$t.tmp"
  cat "$t.tmp" > "$t"
  LC_ALL=C sed '$ s/"input_tokens":600/"input_tokens":601/' "$t.want2" > "$t.want"
  bs_sync >/dev/null
  bs_same "rewritten just under the offset: read again" "$t"
  rm -f "$p/s1/subagents/agent-b.jsonl"
  bs_sync >/dev/null
  assert_eq "a deleted transcript's shadow goes" "ABSENT" "$(bs_shadow_of "$p/s1/subagents/agent-b.jsonl")"

  # ---- a state left building, or corrupt, is built again ----
  python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); s["status"]="building"; json.dump(s, open(sys.argv[1],"w"))' "$SHADOW_DIR/state.json"
  out=$(bs_sync)
  assert_contains "a state left building: rebuilt" "rebuild" "$out"
  bs_same "and the rebuild is the same shadow" "$t"
  bs_same "subagent too" "$sub"
  printf '{"v":' > "$SHADOW_DIR/state.json"
  out=$(bs_sync)
  assert_contains "a corrupt state: rebuilt" "rebuild" "$out"
  bs_same "the same shadow again" "$t"

  # ---- the roll: a day later, the lines before the new S go ----
  BS_NOW=$(( BS_NOW + 86400 ))
  out=$(bs_sync)
  assert_contains "the next day rolls" "roll" "$out"
  assert_contains "and the first exact day moves" " 2026-11-19 " "$out"
  local want_roll
  want_roll=$(while IFS= read -r line; do
    case "$line" in *'"id":"a4"'*|*'"id":"a5"'*|*'"id":"a6"'*) printf '%s\n' "$line" ;; esac
  done < "$t.want")
  assert_eq "only the lines from the new S stay" "$want_roll" "$(bs_shadow_of "$t")"
  out=$(bs_sync)
  assert_contains "a second run the same day does not roll" "append" "$out"
}
