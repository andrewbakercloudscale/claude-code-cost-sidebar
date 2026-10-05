# Check BD -- the headless panel that feeds the usage-panel mod.
#
# The mod draws nothing it did not read from mod/<session id>.json, so what
# this file holds is the mod's whole truth: the figures, their traffic-light
# tiers (as words, not escape codes) and the series behind the graphs. It is
# written only while the mod says it is still there (.alive), by one process
# per session (.pid).
check_BD_mod_feed() {
  sandbox_new BD
  load_panel 10 12 ""
  local sid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

  # Alive only while the mod keeps touching its file.
  mod_alive "$sid" && _fail "not alive without the file" "false" "true" || _pass
  mkdir -p "$MOD_DIR"
  touch "$MOD_DIR/$sid.alive"
  mod_alive "$sid" && _pass || _fail "alive just after a touch" "true" "false"
  age_file "$MOD_DIR/$sid.alive" $(( MOD_ALIVE_SECS + 30 ))
  mod_alive "$sid" && _fail "not alive once the mod has stopped touching it" "false" "true" || _pass

  # One feed per session: a live holder keeps it, a dead one gives it up.
  sleep 30 &
  local other=$!
  printf '%s\n' "$other" > "$MOD_DIR/$sid.pid"
  mod_claim "$sid" && _fail "a live holder keeps the session" "refused" "claimed" || _pass
  kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
  mod_claim "$sid" && _pass || _fail "a dead holder gives it up" "claimed" "refused"
  assert_eq "and the file names this process" "$$" "$(cat "$MOD_DIR/$sid.pid")"
  mod_claim "$sid" && _pass || _fail "the holder can claim again (after its own exec)" "claimed" "refused"

  assert_eq "green is a word" "green" "$(tier_name "$C_GREEN")"
  assert_eq "magenta is purple, the panel's own name for it" "purple" "$(tier_name "$C_MAGENTA")"
  assert_eq "no colour is no tier" "" "$(tier_name "")"

  # Headless, the session is the one named, found under any project.
  local other_proj="$HOME/.claude/projects/-elsewhere"
  mkdir -p "$other_proj"
  printf '%s\n' '{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","cwd":"/elsewhere","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}}}' > "$other_proj/$sid.jsonl"
  PANEL_HEADLESS=1 PIN_SESSION_ID="$sid" resolve_session
  assert_eq "headless finds its transcript under another project" "$other_proj/$sid.jsonl" "$latest"
  assert_eq "and its identity" "$sid" "$sess_id"

  # The file: figures from the builders' variables, tiers as words.
  session_stats_refresh
  sc="$C_RED"; src="$C_GREEN"; tc="$C_YELLOW"; pc="$C_GREEN"; spendc="$C_RED"; avgc="$C_RED"; mtc="$C_CYAN"
  today_amt=6.70; today_pred=23.21; typical_so_far=80; avg_session_cost=5.38
  has_block=1; blk_cost=6.70; blk_cph=7.28; blk_rem=244; burn_label=High; burn_color="$C_RED"
  spend30=5363.4; prev_spend30=159; avg_daily_30=184.9; prev_avg_daily_30=5.5
  week_cost=95.4; month_cost=455.6; proj_spend=742; last_slow=1000
  top_rows=$(printf '%s\t%s\t%s\t%s\n' "$sid" 4.98 11000000 "2026-10-05T07:45:28Z" "other" 1.2 2000000 "2026-10-05T06:00:00Z")
  summary_block="  Proxy State: PRIMARY"
  printf '%s' '{"daily":[{"period":"2026-10-04","totalCost":12.5,"totalTokens":9,"modelBreakdowns":[{"modelName":"claude-opus-5-5","cost":12.5}]}]}' > "$SBX/recent.json"
  # Claude Code's name for a project is its path with every / made -, so a
  # repo with a dash in its name is only recoverable against the disk.
  mkdir -p "$HOME/work/my-repo"
  local enc; enc=$(cd "$HOME/work/my-repo" && pwd -P | tr '/.' '--')
  printf '{"session":[{"projectPath":"%s","totalCost":40,"lastActivity":"2099-01-01"},{"projectPath":"-old","totalCost":99,"lastActivity":"2000-01-01"}]}' "$enc" > "$SBX/all.json"
  MJ_RECENT_FILE="$SBX/recent.json" MJ_ALL_SESS_FILE="$SBX/all.json" mod_json_write "$sid"
  local f="$MOD_DIR/$sid.json"
  assert_eq "session cost" "0.0026" "$(jq -r '.session.cost | . * 10000 | round / 10000 | tostring | .[0:6]' "$f")"
  assert_eq "session tier as a word" "red" "$(jq -r '.session.tier' "$f")"
  assert_eq "model tier" "cyan" "$(jq -r '.session.model_tier' "$f")"
  assert_eq "context from this tick's parse" "1300" "$(jq -r '.session.ctx | floor' "$f")"
  assert_eq "today and its forecast" "6.7 23.21 yellow" "$(jq -r '"\(.today.cost) \(.today.pred) \(.today.tier)"' "$f")"
  assert_eq "the block" "true 244 High red" "$(jq -r '"\(.block.active) \(.block.rem) \(.block.label) \(.block.tier)"' "$f")"
  assert_eq "30 days" "5363.40 159.00" "$(num "$(jq -r '.days30.spend' "$f")") $(num "$(jq -r '.days30.prev' "$f")")"
  assert_eq "daily series with models" "2026-10-04 12.5 12.5" "$(jq -r '.daily[0] | "\(.d) \(.cost) \(.models["claude-opus-5-5"])"' "$f")"
  assert_eq "projects within 30 days only, named from the disk" "my-repo 40" "$(jq -r '[.projects[] | "\(.name) \(.cost)"] | join(",")' "$f")"
  assert_eq "top sessions, dearest first" "$sid other" "$(jq -r '[.top[].sid] | join(" ")' "$f")"
  assert_eq "turn series" "1" "$(jq -r '.turns.turns | length' "$f")"
  assert_eq "the panel rows ride along" "  Proxy State: PRIMARY" "$(jq -r '.summary' "$f")"
  assert_eq "thresholds" "30 50 70" "$(jq -r '.thresholds | "\(.ctx_yellow|floor) \(.ctx_red|floor) \(.ctx_purple|floor)"' "$f")"
  assert_eq "nothing left behind but the file" "" "$(ls "$MOD_DIR" | grep '\.tmp$')"
}
