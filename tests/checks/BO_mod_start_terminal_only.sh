# Check BO -- ccusage-panel-mod-start starts panels for terminal sessions only.
#
# The usage-panel mod runs in Claude Desktop sessions too (entrypoint
# "claude-desktop"), and in SDK and local-agent ones. None has a terminal, and
# each kept a headless panel (and so the shared collector) running for
# nothing. The starter now says why it skips them and touches nothing, so a
# panel already running for one stops by itself. A terminal session ("cli"),
# or one it cannot tell yet, goes on as before; and that usual answer, a
# panel already running, costs no process start beyond the script itself.
check_BO_mod_start_terminal_only() {
  sandbox_new BO
  load_panel 10 12 ""
  local ms="${PANEL_SH%/*}/ccusage-panel-mod-start" out sid proj="$HOME/.claude/projects/-bo"
  [ -x "$ms" ] && _pass || _fail "ccusage-panel-mod-start beside the panel" "$ms" "missing"
  mkdir -p "$proj" "$MOD_DIR"

  # The environment says so.
  sid="0bd0bd00-0000-4000-8000-000000000001"
  out=$(CLAUDE_CODE_ENTRYPOINT=claude-desktop bash "$ms" "$sid" "$HOME" 2>&1)
  assert_eq "a Desktop session is skipped, and says why" "skipped: Claude Desktop session, no terminal" "$out"
  [ -e "$MOD_DIR/$sid.alive" ] && _fail "and its .alive is not touched" "absent" "written" || _pass
  [ -e "$MOD_DIR/$sid.pid" ] && _fail "and no panel is started" "no pid" "pid" || _pass
  out=$(CLAUDE_CODE_ENTRYPOINT=sdk-cli bash "$ms" "$sid" "$HOME" 2>&1)
  assert_eq "an SDK session too" "skipped: sdk-cli session, no terminal" "$out"
  out=$(CLAUDE_CODE_ENTRYPOINT=local-agent bash "$ms" "$sid" "$HOME" 2>&1)
  assert_eq "and a local agent" "skipped: local-agent session, no terminal" "$out"

  # Or the transcript does, when the environment does not: remembered.
  sid="0bd0bd00-0000-4000-8000-000000000002"
  { printf '{"type":"custom-title","customTitle":"x","sessionId":"%s"}\n' "$sid"
    printf '{"parentUuid":null,"type":"user","entrypoint":"claude-desktop","sessionId":"%s"}\n' "$sid"; } > "$proj/$sid.jsonl"
  out=$(env -u CLAUDE_CODE_ENTRYPOINT bash "$ms" "$sid" "$HOME" 2>&1)
  assert_eq "a Desktop transcript is skipped" "skipped: Claude Desktop session, no terminal" "$out"
  assert_eq "and what it found is remembered" "claude-desktop" "$(cat "$MOD_DIR/$sid.entry" 2>/dev/null)"
  [ -e "$MOD_DIR/$sid.alive" ] && _fail "nothing touched for it either" "absent" "written" || _pass

  # A terminal session with its panel running: "running", .alive moved on.
  sid="0bd0bd00-0000-4000-8000-000000000003"
  printf '{"type":"user","entrypoint":"cli","sessionId":"%s"}\n' "$sid" > "$proj/$sid.jsonl"
  sleep 300 & local holder=$!
  printf '%s\n' "$holder" > "$MOD_DIR/$sid.pid"
  : > "$MOD_DIR/$sid.alive"
  age_file "$MOD_DIR/$sid.alive" 600
  out=$(env -u CLAUDE_CODE_ENTRYPOINT bash "$ms" "$sid" "$HOME" 2>&1)
  assert_eq "a terminal session's running panel is left running" "running" "$out"
  mod_alive "$sid" && _pass || _fail "and .alive says it is still wanted" "fresh" "stale"
  out=$(CLAUDE_CODE_ENTRYPOINT=cli bash "$ms" "$sid" "$HOME" 2>&1)
  assert_eq "cli in the environment is a terminal session" "running" "$out"

  # That answer starts no process: counted with bash's own xtrace, every
  # line a child shell would print carries a pid other than the script's.
  local trace="$SBX/ms.trace" pids
  CLAUDE_CODE_ENTRYPOINT=cli PS4='+${BASHPID} ' bash -x "$ms" "$sid" "$HOME" >/dev/null 2>"$trace"
  pids=$(sed -n 's/^+*\([0-9][0-9]*\) .*/\1/p' "$trace" | sort -u | wc -l | tr -d ' ')
  assert_eq "one shell, no child: no fork in the running path" 1 "$pids"
  local cmd ext=""
  for cmd in cat touch mkdir ps sed tr date stat; do
    grep -qE "^\+[0-9]+ $cmd( |$)" "$trace" && ext+="$cmd "
  done
  assert_eq "and no external command" "" "$ext"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  return 0
}
