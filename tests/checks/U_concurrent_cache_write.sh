# Check U -- two panels on the same session do not fight over a temp file.
#
# Every cache write here is `> "$f.tmp" && mv "$f.tmp" "$f"`, which is
# atomic for the READER. It was not safe for the second WRITER: the temp
# name was shared, so two panels open on the same session both wrote
# `<file>.tmp`, whichever renamed first won, and the loser's `mv` failed on
# a path that no longer existed. Three of these caches are keyed by session
# and have no lock around them, so nothing prevented it.
#
# The failure was visible, not silent -- the builders' stderr goes into
# PANEL_ERR_FILE, so it rendered on the panel as `! mv: ...tmp: No such
# file or directory`. It took two panels to see it, which is why it survived
# a suite that had always run one.
#
# Asserting on the absence of an error message would be asserting on the
# absence of matched output, which this suite's first rule forbids. So the
# assertions are: the temp name contains the pid (structural, cannot pass by
# accident), both writers report success, and the cache ends up with valid
# content rather than a half-written or missing file.
check_U_concurrent_cache_write() {
  sandbox_new U
  cat > "$CCUSAGE_FIXTURE_DIR/session.json" <<'JSON'
{"sessions":[{"sessionId":"s1","totalCost":1.00,"totalTokens":100,"lastActivity":"2026-09-01T10:00:00.000Z","entries":[]}]}
JSON
  load_panel 10 12 ""
  local CD="$CCUSAGE_CACHE_DIR_REAL"

  # Structural: the writer's temp path must be process-unique. Read it out
  # of the function's own source, so a future edit that reinstates a shared
  # name fails here rather than in production with two panes open.
  local body; body=$(declare -f session_identity_cached)
  assert_contains "the identity cache writes a per-process temp" \
    '$cache_file.$$.tmp' "$body"
  body=$(declare -f session_today_tokens_cached)
  assert_contains "so does the today-tokens cache" \
    '$cache_file.$$.tmp' "$body"

  # Behavioural: two writers, concurrently, on one session's entry. Each is
  # a separate PROCESS -- a subshell shares $$ with its parent, so `( ... )`
  # would reuse one temp name and prove nothing.
  local tp="$HOME/.claude/projects/test-project"
  printf '{}\n' > "$tp/s1.jsonl"
  local i out1 out2
  for i in 1 2; do
    ( PANEL_LIB_ONLY=1; source "$PANEL_SH" 10 12 "" </dev/null
      session_identity_cached "$tp/s1.jsonl" >/dev/null 2>"$SBX/err.$i"
      printf '%s' "$?" > "$SBX/rc.$i" ) &
  done
  wait

  assert_eq "first writer succeeded" "0" "$(cat "$SBX/rc.1")"
  assert_eq "second writer succeeded" "0" "$(cat "$SBX/rc.2")"

  # The surviving entry must be a real one. A lost race previously left the
  # loser having written nothing, so a check that only counted exit codes
  # could still be looking at an empty cache.
  local cached; cached=$(cat "$CD"/sessid-*.tsv 2>/dev/null)
  assert_ne "the cache holds an entry, not an empty file" "" "$cached"
  assert_eq "and it is a stamped tsv row, not a fragment" "1" \
    "$(printf '%s' "$cached" | grep -cE '^[0-9]+:[0-9]+' || true)"

  # No temp file may outlive the writers.
  assert_eq "no temp files left behind" "0" \
    "$(find "$CD" -maxdepth 1 -name '*.tmp' | wc -l | tr -d ' ')"
}
