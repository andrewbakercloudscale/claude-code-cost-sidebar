# Check BI -- a session's tokens today are read from its own transcript.
#
# Top Sessions used to ask `ccusage session -i <sid>` for each busy session,
# a scan of the whole corpus every time, and six panels on 16 Oct 2026 kept
# about a core busy with it. The count now reads the one transcript and its
# subagents'. It must still count what ccusage counts, and two of its rules
# are easy to lose: a message logged several times counts once at its
# largest usage (streamed copies grow, copies of a rewound session carry
# zeros), and the day is the timestamp's UTC prefix.
check_BI_today_tokens_direct() {
  sandbox_new BI
  load_panel 10 12 ""
  local tp="$HOME/.claude/projects/test-project"
  mkdir -p "$tp/s9/subagents"
  local u='"usage":{"input_tokens":%d,"output_tokens":%d,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}'
  {
    # m1 streamed twice (10+5, then 10+40), then copied with zeros by a rewind.
    printf '{"type":"assistant","timestamp":"2026-10-16T08:00:00.000Z","requestId":"r1","message":{"id":"m1",'"$u"'}}\n' 10 5
    printf '{"type":"assistant","timestamp":"2026-10-16T08:00:01.000Z","requestId":"r1","message":{"id":"m1",'"$u"'}}\n' 10 40
    printf '{"type":"assistant","timestamp":"2026-10-16T08:00:01.000Z","requestId":"r1","message":{"id":"m1",'"$u"'}}\n' 0 0
    # Yesterday by its UTC prefix: not counted.
    printf '{"type":"assistant","timestamp":"2026-10-15T23:59:00.000Z","requestId":"r2","message":{"id":"m2",'"$u"'}}\n' 1000 0
    # A user line carrying usage is not an assistant message.
    printf '{"type":"user","timestamp":"2026-10-16T09:00:00.000Z","message":{"id":"m3",'"$u"'}}\n' 500 0
    printf 'not json "usage"\n'
  } > "$tp/s9.jsonl"
  printf '{"type":"assistant","timestamp":"2026-10-16T10:00:00.000Z","requestId":"r4","message":{"id":"m4",'"$u"'}}\n' 7 3 \
    > "$tp/s9/subagents/agent-a.jsonl"

  assert_eq "largest copy of a message, plus its subagent, today only" "60" \
    "$(session_today_tokens_cached s9 2026-10-16)"

  local body; body=$(declare -f session_today_tokens_cached)
  assert_not_contains "no corpus-wide ccusage scan per session" "ccusage session" "$body"

  # Cached on the transcript's stamp: a second call answers from the cache.
  assert_eq "a second call returns the same count" "60" \
    "$(session_today_tokens_cached s9 2026-10-16)"
  assert_eq "and it was written to the shared cache" "1" \
    "$(ls "$CCUSAGE_CACHE_DIR_REAL"/todaytok-*.tsv 2>/dev/null | wc -l | tr -d ' ')"
}
