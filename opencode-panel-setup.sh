#!/usr/bin/env bash
# Installs the OpenCode live usage panel + auto-split launcher.
#
# What this sets up:
#   ~/.local/bin/opencode-panel.sh        - live stats panel (per-turn
#                                            breakdown of the current
#                                            session, 7-day baseline
#                                            flagging, today/week/month
#                                            via `opencode stats`)
#   ~/.local/bin/opencode-panel-launch.sh - opens a right-hand Ghostty
#                                            split running the panel above
#   ~/.zshrc (appended, idempotent)       - a preexec hook that runs the
#                                            launcher once per terminal
#                                            window, the first time an
#                                            `opencode*` command is typed
#
# Requirements: macOS + Ghostty (for the auto-split part — the panel
# script itself works in any terminal), the `opencode` CLI on your PATH,
# and jq. Accessibility permission for Ghostty/Terminal is needed for the
# System Events automation (macOS will prompt the first time).
#
# What this does NOT try to do: parse `opencode stats --json`. As of the
# version this was written against, session list JSON is confirmed
# (`opencode session list --format json`) and session export JSON is
# confirmed (`opencode export <id>`), but the exact JSON shape of
# `opencode stats --json` is not, so the today/week/month section below
# shells out to plain `opencode stats` and shows its own output rather
# than guessing at field names. If your installed version supports
# `--json` on stats cleanly, that section is the one to upgrade.
#
# Safe to re-run: overwrites the two scripts with the latest version and
# skips the .zshrc block if it's already present.
set -uo pipefail

BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"

echo "Installing opencode-panel.sh ..."
cat > "$BIN_DIR/opencode-panel.sh" <<'PANEL_EOF'
#!/usr/bin/env bash
# Live OpenCode usage panel: per-turn breakdown of the current session
# (turn/model/context/Δ cache write/cache hit %/cost), a 7-day average
# session cost used to flag expensive turns, and today/week/month via
# `opencode stats` in its own native format (see the note in the
# installer about why that part isn't parsed as JSON).
set -uo pipefail
export LC_ALL=C LC_NUMERIC=C

REFRESH="${1:-5}"
TURN_ROWS="${2:-20}"

C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
C_CYAN=$'\033[36m'; C_YELLOW=$'\033[33m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'

# A short colored title, not a full-width divider bar — a bar drawn at
# $cols but rendered later in a narrower/resized pane just wraps into a
# confusing second row of "=" or "-", which is worse than no rule at all.
header() { local title="$1"; printf '%s%s%s\n' "$C_BOLD$C_CYAN" "$title" "$C_RESET"; }
# Erases to end of line after every printed row before the newline, so a
# frame whose lines are shorter than the previous frame's (e.g. right after
# a pane resize) never leaves trailing characters from the old frame
# ghosting through the new one — same fix as ccusage-panel.sh. Also
# truncates to $COLS first: \033[K can't stop an over-long line from
# wrapping onto an extra physical row, which in a narrow pane let a frame's
# row count silently exceed $rows and desync the cursor-home redraw below.
clear_eol() { awk -v w="${COLS:-999}" '{ if (length($0) > w) $0 = substr($0, 1, w); printf "%s\033[K\n", $0 }'; }

fmt_money() { printf '$%.2f' "${1:-0}"; }
fmt_m() { awk -v n="${1:-0}" 'BEGIN{ printf "%.1fM", n/1000000 }'; }
# value yellow_threshold red_threshold -> green/yellow/red. No historical
# baseline to compare against (unlike the Claude Code panel's ccusage-backed
# tier_color) — Together AI/opencode has no equivalent of ccusage's flexible
# --since/--until session query, so these are fixed heuristic dollar/percent
# cutoffs rather than "vs. your own recent average". Adjust if they don't
# match your actual usage pattern.
threshold_color() {
  local v="$1" yt="$2" rt="$3" color="$C_GREEN"
  awk -v v="$v" -v t="$yt" 'BEGIN{exit !(v+0>t)}' && color="$C_YELLOW"
  awk -v v="$v" -v t="$rt" 'BEGIN{exit !(v+0>t)}' && color="$C_RED"
  printf '%s' "$color"
}

# Looks up a model's context-window size via `opencode models --verbose`,
# which takes ~1s (it hits models.dev), so the result is cached to disk for
# 10 minutes — a model's context limit never changes mid-session, and this
# runs on every 5s refresh tick otherwise.
model_context_limit() {
  local provider="$1" model="$2"
  local cache_dir="$HOME/.cache/opencode-panel-model-limits"
  mkdir -p "$cache_dir" 2>/dev/null
  local cache_key cache_file cache_age
  cache_key=$(printf '%s_%s' "$provider" "$model" | tr '/ ' '__')
  cache_file="$cache_dir/$cache_key"
  if [ -f "$cache_file" ]; then
    cache_age=$(( $(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
    if [ "$cache_age" -lt 600 ]; then
      cat "$cache_file"
      return
    fi
  fi
  local limit
  limit=$(opencode models "$provider" --verbose 2>/dev/null | python3 -c '
import sys, json, re
provider, target = sys.argv[1], sys.argv[2]
text = sys.stdin.read()
for block in re.split(r"\n(?=" + re.escape(provider) + r"/)", text.strip()):
    parts = block.split("\n", 1)
    if len(parts) != 2:
        continue
    try:
        d = json.loads(parts[1])
    except json.JSONDecodeError:
        continue
    if d.get("id") == target:
        print((d.get("limit") or {}).get("context", 0))
        break
' "$provider" "$model" 2>/dev/null)
  [ -z "$limit" ] && limit=0
  echo "$limit" > "$cache_file" 2>/dev/null
  printf '%s' "$limit"
}

# jq expression tried against two plausible `session list --format json`
# shapes (flat time_created, or nested time.created / sessionID), sorted
# newest first. If neither field exists on your version, this falls back
# to whatever order the CLI already returns.
FIND_LATEST='sort_by(.time_created // .time.created // .timeCreated // .created // 0) | reverse | .[0] | (.id // .sessionID // .session_id // "")'
BASELINE_AVG='
  [ .[] | (.cost // .totalCost // .data.cost // null) ] | map(select(. != null and . > 0)) |
  if length >= 3 then (add/length) else 0 end
'

while true; do
  SECONDS=0
  # Cursor-home only, NOT a full \033[2J clear — a full clear blanks the
  # whole pane for one frame before the redraw lands, which reads as a
  # visible flicker every refresh. This stays purely additive-overwrite
  # only because clear_eol() (above) truncates every line to $COLS, so a
  # frame's physical row count can never silently exceed $rows.
  printf '\033[H'
  cols=$(tput cols 2>/dev/null || echo 60)
  (( cols < 40 )) && cols=40
  rows=$(tput lines 2>/dev/null || echo 24)
  (( rows < 10 )) && rows=10
  export COLS="$cols"

  {
  printf '%s%s OpenCode usage — %s %s(refresh %ss)%s\n' \
    "$C_BOLD" "──" "$(date '+%a %H:%M:%S')" "$C_DIM" "$REFRESH" "$C_RESET"
  printf '  %s(💵 figures = API-equivalent value, not a real bill on flat-rate plans)%s\n' "$C_DIM" "$C_RESET"

  if ! command -v opencode >/dev/null 2>&1; then
    echo "opencode CLI not found on PATH."
  else
    list_json=$(opencode session list --format json 2>/dev/null)
    session_id=""
    if [ -n "$list_json" ]; then
      # Scoped to sessions whose .directory matches THIS project — not the
      # newest session across every opencode session on the machine. The
      # launcher (opencode-panel-launch.sh) always opens this panel via a
      # same-cwd Ghostty split, so $PWD reliably names the project this
      # panel belongs to. Without this, a second opencode session open in
      # another directory would hijack "session:" (and everything below
      # it) the moment it became the most recently created session
      # anywhere — the same cross-session bug fixed in ccusage-panel.sh.
      project_list_json=$(jq -c --arg d "$PWD" '[ .[] | select((.directory // "") == $d) ]' <<<"$list_json" 2>/dev/null)
      if [ -n "$project_list_json" ] && [ "$project_list_json" != "[]" ]; then
        session_id=$(jq -r "$FIND_LATEST" <<<"$project_list_json" 2>/dev/null)
      fi
    fi

    # ---- 7-day baseline, from the same list (no per-session export) ----
    since7_ms=$(( $(date -v-7d +%s 2>/dev/null || date -d '7 days ago' +%s) * 1000 ))
    avg_session_cost=0
    if [ -n "$list_json" ]; then
      recent_json=$(jq -c --argjson since "$since7_ms" \
        '[ .[] | select((.time_created // .time.created // .timeCreated // .created // 0) >= $since) ]' \
        <<<"$list_json" 2>/dev/null)
      [ -n "$recent_json" ] && avg_session_cost=$(jq -r "$BASELINE_AVG" <<<"$recent_json" 2>/dev/null)
      [ -z "$avg_session_cost" ] && avg_session_cost=0
    fi

    # session_id can be a long opaque id; clip it to fit the pane so it
    # can't wrap and shift the row-count math for `head -n` below.
    sess_disp="${session_id:-none found}"
    sess_maxw=$(( cols - 10 )); (( sess_maxw < 10 )) && sess_maxw=10
    if [ "${#sess_disp}" -gt "$sess_maxw" ]; then
      sess_disp="${sess_disp:0:$((sess_maxw - 3))}..."
    fi
    echo "session: $sess_disp"
    if awk -v a="$avg_session_cost" 'BEGIN{exit !(a>0)}'; then
      printf '%s  7-day avg session: $%.2f%s\n' "$C_DIM" "$avg_session_cost" "$C_RESET"
    fi
    echo

    # `opencode stats` takes ~0.5s per call (Node/Bun startup, not the
    # query itself) — fetched once per day-range here and reused below by
    # both the headline block and the TODAY/LAST 7 DAYS sections, instead
    # of hitting the same range twice per refresh tick.
    today_stats=$(opencode stats --days 1 2>/dev/null)
    week_stats=$(opencode stats --days 7 2>/dev/null)
    month_stats=$(opencode stats --days 30 2>/dev/null)
    stats_field() { awk -F'\\$' -v pat="$2" '$0 ~ pat {gsub(/[ │]/,"",$2); print $2}' <<<"$1"; }

    # ---- headline status block, "icon Label: value" per row like the
    # Claude Code panel. `opencode export` is fetched once here and its
    # temp file reused below by the per-turn table, instead of exporting
    # the same session twice per refresh tick. There is no OpenCode
    # equivalent of Claude Code's 5-hour billing block (Together AI and
    # the other providers here bill per-token continuously with no block
    # reset), so "Current Time Block" / "All Sessions Burn Rate" are
    # skipped rather than faked.
    export_tmp=""
    if [ -n "$session_id" ]; then
      export_json=$(opencode export "$session_id" 2>/dev/null)
      if [ -n "$export_json" ]; then
        export_tmp=$(mktemp)
        printf '%s\n' "$export_json" > "$export_tmp"
      fi
    fi

    if [ -n "$export_tmp" ]; then
      IFS=$'\t' read -r model_label session_cost sess_elapsed_h last_ctx_tokens provider_id model_id \
        < <(python3 - "$export_tmp" <<'PYEOF'
import json, sys, time

path = sys.argv[1]
try:
    with open(path) as f:
        doc = json.load(f)
except (OSError, json.JSONDecodeError):
    doc = {}

info = doc.get("info", {}) or {}
model = info.get("model", {}) or {}
provider_id = model.get("providerID", "?")
model_id = model.get("id", "unknown")
label = model_id.split("/")[-1][:20] or "unknown"

cost = info.get("cost", 0) or 0
created_ms = (info.get("time", {}) or {}).get("created", 0) or 0
# Floor elapsed time at 3 minutes — a rate computed over the first few
# seconds of a session swings wildly and would flash red/green noise.
elapsed_h = max((time.time() * 1000 - created_ms) / 3_600_000, 0.05) if created_ms else 0.05

last_ctx = 0
for m in doc.get("messages", []):
    minfo = m.get("info", {}) or {}
    if minfo.get("role") != "assistant":
        continue
    tokens = minfo.get("tokens", {}) or {}
    cache = tokens.get("cache", {}) or {}
    last_ctx = tokens.get("input", 0) + cache.get("read", 0) + cache.get("write", 0)

print(f"{label}\t{cost}\t{elapsed_h:.4f}\t{last_ctx}\t{provider_id}\t{model_id}")
PYEOF
      )

      printf '  🤖 Model: %s\n' "${model_label:-unknown}"

      sc=$(threshold_color "${session_cost:-0}" 1 5)
      printf '  💰 Session Value: %s%s%s\n' "$sc" "$(fmt_money "${session_cost:-0}")" "$C_RESET"

      sess_rate=$(awk -v c="${session_cost:-0}" -v h="${sess_elapsed_h:-0.05}" 'BEGIN{ printf "%.2f", (h>0? c/h:0) }')
      rc=$(threshold_color "$sess_rate" 2 5)
      printf '  📈 Session Burn Rate: %s$%s/hr%s\n' "$rc" "$sess_rate" "$C_RESET"

      today_cost=$(stats_field "$today_stats" "Total Cost")
      [ -z "$today_cost" ] && today_cost=0
      tc=$(threshold_color "$today_cost" 5 20)
      printf '  📅 Today Value: %s%s%s\n' "$tc" "$(fmt_money "$today_cost")" "$C_RESET"

      # Projects the CURRENT session's burn rate across a flat 10h work
      # day — same convention as the Claude Code panel's predicted-spend
      # line, standing in for a per-block rate since there's no block here.
      today_pred=$(awk -v r="$sess_rate" 'BEGIN{ printf "%.2f", r*10 }')
      pc=$(threshold_color "$today_pred" 5 20)
      printf '  🔮 Today'"'"'s Predicted Value: %s%s%s\n' "$pc" "$(fmt_money "$today_pred")" "$C_RESET"

      if [ "${last_ctx_tokens:-0}" -gt 0 ] 2>/dev/null; then
        ctx_limit=$(model_context_limit "${provider_id:-}" "${model_id:-}")
        if [ "${ctx_limit:-0}" -gt 0 ] 2>/dev/null; then
          ctx_pct=$(awk -v t="$last_ctx_tokens" -v w="$ctx_limit" 'BEGIN{ printf "%.0f", (w>0? t*100/w:0) }')
          cc=$(threshold_color "$ctx_pct" 50 80)
          printf '  🧠 Context Usage: %s / %s tokens (%s%s%%%s)\n' \
            "$(fmt_m "$last_ctx_tokens")" "$(fmt_m "$ctx_limit")" "$cc" "$ctx_pct" "$C_RESET"
        fi
      fi

      folder_full=$(jq -r --arg sid "$session_id" \
        '.[] | select((.id // .sessionID // .session_id) == $sid) | (.directory // "")' \
        <<<"$list_json" 2>/dev/null)
      [ -n "$folder_full" ] && printf '  📁 Folder: %s\n' "$(basename "$folder_full")"

      week_avg_cost=$(stats_field "$week_stats" "Avg Cost.Day")
      if [ -n "$week_avg_cost" ]; then
        wc=$(threshold_color "$week_avg_cost" 5 20)
        printf '  📊 7-Day Avg Daily Value: %s%s%s\n' "$wc" "$(fmt_money "$week_avg_cost")" "$C_RESET"
      fi

      month_cost=$(stats_field "$month_stats" "Total Cost")
      if [ -n "$month_cost" ]; then
        mc=$(threshold_color "$month_cost" 50 200)
        printf '  💵 30-Day Value: %s%s%s\n' "$mc" "$(fmt_money "$month_cost")" "$C_RESET"
      fi
      echo
    fi

    header "THIS SESSION — PER TURN"
    if [ -n "$export_tmp" ]; then
      python3 - "$export_tmp" "$TURN_ROWS" <<'PYEOF'
import json, sys

path, max_rows = sys.argv[1], int(sys.argv[2])

def fmt_k(n):
    if abs(n) >= 1000:
        return f"{n/1000:.0f}k"
    return str(n)

turns = []
try:
    with open(path) as f:
        doc = json.load(f)
except (OSError, json.JSONDecodeError):
    doc = {}

# `opencode export` prints one pretty-printed JSON object — {"info": ...,
# "messages": [{"info": {...}, "parts": [...]}]} — not JSON-lines, and each
# message's fields (role/tokens/cost/modelID/providerID) live directly on
# its own "info", not nested under a "data" key. The original version of
# this parser assumed a JSONL shape that never matched a real export, so
# every session showed "no assistant turns yet" regardless of activity.
for m in doc.get("messages", []):
    info = m.get("info", {}) or {}
    if info.get("role") != "assistant":
        continue

    tokens = info.get("tokens", {}) or {}
    in_tok = tokens.get("input", 0)
    cache = tokens.get("cache", {}) or {}
    cache_read = cache.get("read", 0)
    cache_write = cache.get("write", 0)
    cost = info.get("cost", 0) or 0

    total_ctx = in_tok + cache_read + cache_write
    cache_pct = (cache_read / total_ctx * 100) if total_ctx else 0.0

    provider = info.get("providerID", "?")
    model = info.get("modelID", "unknown")
    label = f"{provider}/{model}"[:16]

    # Δ is new cache writes this turn, matching the ccusage panel's
    # convention: it's exactly the tokens that weren't already cached,
    # i.e. what a context spike looks like.
    turns.append((label, total_ctx, cache_write, cache_pct, cost))

total_n = len(turns)
shown = turns[-max_rows:]
if not shown:
    print("  (no assistant turns yet)")
else:
    if total_n > len(shown):
        print(f"  (showing last {len(shown)} of {total_n} turns)")
    print(f"  {'Turn':<6}{'Model':<17}{'Ctx':>7}{'Δ':>8}{'Cache':>7}{'Cost':>8}")
    start_idx = total_n - len(shown) + 1
    for i, (label, total_ctx, delta, cache_pct, cost) in enumerate(shown):
        turn_no = start_idx + i
        print(f"  {turn_no:<6}{label:<17}{fmt_k(total_ctx):>7}"
              f"{'+' + fmt_k(delta):>8}{cache_pct:>6.0f}%{'$' + format(cost, '.2f'):>8}")
    session_cost = sum(t[4] for t in turns)
    print(f"  session total so far: ${session_cost:.2f} ({total_n} assistant turns)")
PYEOF
      rm -f "$export_tmp"
    elif [ -n "$session_id" ]; then
      echo "  (couldn't export session $session_id — 'opencode export' may need a newer CLI version)"
    else
      echo "  (no OpenCode session found — run 'opencode session list --format json' to check)"
    fi
    echo

    # ---- today / week: `opencode stats` renders fixed 60-column boxes
    # (OVERVIEW + COST & TOKENS + TOOL USAGE, ~30 lines each) that don't
    # fit a narrow side panel — a 58-col pane wraps every box line, and
    # printing both sections in full blows past the panel's row budget
    # before TOOL USAGE or the 7-day section ever render. Pull just the
    # headline fields into plain "label: value" lines instead, same
    # compact style as the rest of this panel. $today_stats/$week_stats
    # were already fetched above for the headline block — reused here
    # rather than calling `opencode stats` a second time per range.
    extract_stats() {
      sed -n '/Sessions/p;/Messages/p;/^│Days/p;/Total Cost/p;/Avg Cost.Day/p' \
        | sed -E 's/ *│ *$//; s/ {2,}/: /; s/^│/  /'
    }
    header "TODAY"
    if [ -n "$today_stats" ]; then
      echo "$today_stats" | extract_stats
    else
      echo "  (opencode stats not available)"
    fi
    echo
    header "LAST 7 DAYS"
    if [ -n "$week_stats" ]; then
      echo "$week_stats" | extract_stats
    else
      echo "  (opencode stats not available)"
    fi
  fi
  } | head -n "$((rows - 1))" | clear_eol
  printf '\033[0J'

  # Each refresh shells out to `opencode` 4-5 times (session list, export,
  # up to three stats calls) at ~0.5s of Node/Bun startup apiece — that's
  # ~2.5s of unavoidable overhead before REFRESH's own sleep even starts,
  # so a plain `sleep "$REFRESH"` after that silently turns a "5s refresh"
  # into an ~8-9s one. Subtract the work already spent this tick so the
  # labeled cadence is honest; floor at 1s in case a tick ever runs long.
  elapsed=$SECONDS
  remaining=$(( REFRESH - elapsed ))
  (( remaining < 1 )) && remaining=1
  sleep "$remaining"
done
PANEL_EOF
chmod +x "$BIN_DIR/opencode-panel.sh"

echo "Installing opencode-panel-launch.sh ..."
cat > "$BIN_DIR/opencode-panel-launch.sh" <<'LAUNCH_EOF'
#!/usr/bin/env bash
# Opens a right-hand Ghostty split running the live OpenCode panel, shrinks
# it to ~1/3 of the window width, then returns keyboard focus to the left
# (original) pane. Invoked once per terminal window by the opencode
# split-panel autolaunch hook in ~/.zshrc. Needs the ctrl+shift+h/l
# resize_split keybinds in ~/.config/ghostty/config (installed by
# opencode-panel-setup.sh). Same mechanism as claude-panel-launch.sh, kept
# as a separate script and a separate log so installing both doesn't have
# one clobber the other's diagnostics.
#
# Every invocation writes a run to $LOG, one line per step, prefixed with
# a shared run id so concurrent/rapid invocations don't interleave into an
# unreadable mess. Read it with:
#   tail -50 ~/.cache/opencode-panel-launch.log
#
# This retries up to 3 times and, critically, VERIFIES success by checking
# for an actual new opencode-panel.sh process afterward rather than
# trusting AppleScript's own exit code — a stale frontmost check or a
# silent internal early "return" inside the AppleScript both exit 0 with
# no stderr, so a report of success is not the same thing as success.
set -uo pipefail

LOG="$HOME/.cache/opencode-panel-launch.log"
mkdir -p "$(dirname "$LOG")"
RUN_ID="$(date '+%H%M%S')-$$"
log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RUN_ID" "$1" >> "$LOG"; }

panel_pids() { pgrep -f '[b]in/opencode-panel\.sh' 2>/dev/null | sort; }

log "start: TERM_PROGRAM=${TERM_PROGRAM:-unset} TMUX=${TMUX:-unset} PWD=$PWD"

# Inside tmux, TERM_PROGRAM gets overridden (often to "tmux") regardless of
# the outer terminal, so the Ghostty check below never sees "ghostty" even
# when Ghostty is the real host — the launcher aborted silently for every
# tmux user. tmux has its own native split primitive that needs no
# Accessibility permission and no keystroke simulation, so prefer it
# whenever we're inside a tmux client at all, before falling through to the
# Ghostty/osascript path. Same fix as claude-panel-launch.sh.
if [ -n "${TMUX:-}" ]; then
  if ! command -v tmux >/dev/null 2>&1; then
    log "abort: TMUX is set but tmux binary not found"
    exit 0
  fi
  if tmux split-window -h -l 33% "~/.local/bin/opencode-panel.sh" 2>>"$LOG"; then
    tmux select-pane -L >>"$LOG" 2>&1
    log "done: tmux split-window succeeded"
  else
    log "done: tmux split-window FAILED"
  fi
  exit 0
fi

if [ "${TERM_PROGRAM:-}" != "ghostty" ]; then
  log "abort: not running inside Ghostty (TERM_PROGRAM=${TERM_PROGRAM:-unset})"
  exit 0
fi
if ! command -v osascript >/dev/null 2>&1; then
  log "abort: no osascript on this system (not macOS?)"
  exit 0
fi

ghostty_procs=$(pgrep -x ghostty 2>/dev/null | wc -l | tr -d ' ')
log "context: ${ghostty_procs} ghostty process(es) running"

# A bare permission-probe first — if Accessibility access isn't granted,
# every subsequent step will fail the same way, so say so once clearly
# instead of three confusing retries.
probe=$(osascript -e 'tell application "System Events" to get name of first process' 2>&1)
probe_status=$?
if [ "$probe_status" -ne 0 ]; then
  log "abort: System Events probe failed (exit=$probe_status): $probe"
  log "abort: likely missing Accessibility permission — check System Settings > Privacy & Security > Accessibility for Ghostty"
  exit 0
fi

attempt=0
max_attempts=3
success=0

while [ "$attempt" -lt "$max_attempts" ] && [ "$success" -eq 0 ]; do
  attempt=$((attempt + 1))
  log "attempt $attempt/$max_attempts: begin"

  before_pids=$(panel_pids)

  # Brand-new windows can take a beat to become frontmost at the
  # Accessibility API level — poll instead of checking once and giving up.
  front=""
  polls=0
  for _ in $(seq 1 20); do
    polls=$((polls + 1))
    front=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null)
    [ "$front" = "ghostty" ] && break
    sleep 0.1
  done
  if [ "$front" != "ghostty" ]; then
    log "attempt $attempt: frontmost never became ghostty after $polls polls (last saw '$front') — retrying"
    sleep 0.5
    continue
  fi
  log "attempt $attempt: frontmost confirmed ghostty after $polls poll(s)"

  # Settle delay: frontmost can flip true right as a cold `open -na` launch
  # is still mid-activation-animation, before the window can reliably
  # receive keystrokes.
  sleep 0.3

  # Everything below — the frontmost re-check, the window-width read, the
  # resize math, and every keystroke — happens inside ONE osascript call,
  # for the same reason as the Claude Code version: splitting it across
  # two calls lets frontmost change out from under the second one, and
  # both halves separately exit 0.
  result=$(osascript <<'APPLESCRIPT' 2>&1
tell application "System Events"
  set frontApp to first application process whose frontmost is true
  if name of frontApp is not "ghostty" then return "skip: frontmost is " & (name of frontApp)
  tell frontApp
    set winSize to size of front window
    set winWidth to item 1 of winSize
    set numPresses to round ((winWidth / 6) / 40)
    delay 0.3
    keystroke "d" using command down
    delay 0.6
    keystroke "~/.local/bin/opencode-panel.sh"
    key code 36
    delay 0.3
    keystroke "h" using control down
    delay 0.2
    repeat numPresses times
      keystroke "l" using {control down, shift down}
      delay 0.05
    end repeat
  end tell
  return "ok: width=" & winWidth & " presses=" & numPresses
end tell
APPLESCRIPT
  )
  osa_status=$?
  log "attempt $attempt: osascript exit=$osa_status result=$result"

  # Ground truth: did an actual new panel process appear? Don't trust the
  # AppleScript's own report of success — verify it.
  sleep 1
  after_pids=$(panel_pids)
  new_pids=$(comm -13 <(echo "$before_pids") <(echo "$after_pids") 2>/dev/null)
  if [ -n "$new_pids" ]; then
    log "attempt $attempt: VERIFIED — new panel process(es): $(echo "$new_pids" | tr '\n' ' ')"
    success=1
  else
    log "attempt $attempt: FAILED — no new panel process appeared (before=[$(echo "$before_pids" | tr '\n' ' ')] after=[$(echo "$after_pids" | tr '\n' ' ')])"
    sleep 0.5
  fi
done

if [ "$success" -eq 1 ]; then
  log "done: succeeded on attempt $attempt/$max_attempts"
else
  log "done: GAVE UP after $max_attempts attempts — panel did not launch"
  log "done: troubleshooting — confirm ctrl+shift+h/l keybinds exist in ~/.config/ghostty/config, confirm ~/.local/bin/opencode-panel.sh is executable, try running it manually"
fi

exit 0
LAUNCH_EOF
chmod +x "$BIN_DIR/opencode-panel-launch.sh"

ZSHRC="$HOME/.zshrc"
MARKER="# --- opencode split-panel autolaunch"
if [ -f "$ZSHRC" ] && grep -qF "$MARKER" "$ZSHRC"; then
  echo "~/.zshrc already has the OpenCode autolaunch hook — leaving it as-is."
else
  echo "Adding the OpenCode autolaunch hook to ~/.zshrc ..."
  cat >> "$ZSHRC" <<'ZSHRC_EOF'

# --- opencode split-panel autolaunch (installed by opencode-panel-setup.sh) ---
_opencode_panel_autolaunch() {
  case "$1" in
    opencode*) ;;
    *) return ;;
  esac
  [ -n "${OPENCODE_PANEL_LAUNCHED:-}" ] && return
  export OPENCODE_PANEL_LAUNCHED=1
  ~/.local/bin/opencode-panel-launch.sh &
}
autoload -Uz add-zsh-hook
add-zsh-hook preexec _opencode_panel_autolaunch
# --- end opencode split-panel autolaunch ---
ZSHRC_EOF
fi

GHOSTTY_CONF="$HOME/.config/ghostty/config"
if [ -f "$GHOSTTY_CONF" ]; then
  added_keybind=0
  if ! grep -qF "keybind = ctrl+shift+h=resize_split:left,40" "$GHOSTTY_CONF"; then
    printf '%s\n' "keybind = ctrl+shift+h=resize_split:left,40" >> "$GHOSTTY_CONF"
    added_keybind=1
  fi
  if ! grep -qF "keybind = ctrl+shift+l=resize_split:right,40" "$GHOSTTY_CONF"; then
    printf '%s\n' "keybind = ctrl+shift+l=resize_split:right,40" >> "$GHOSTTY_CONF"
    added_keybind=1
  fi
  if [ "$added_keybind" -eq 1 ]; then
    echo "Added resize_split keybinds to ~/.config/ghostty/config."
  else
    echo "~/.config/ghostty/config already has the resize_split keybinds — leaving as-is."
  fi
else
  echo "No ~/.config/ghostty/config found — skipping resize keybinds (the split will stay 50/50)."
fi

echo
echo "Done. Open a NEW terminal window/tab (or 'source ~/.zshrc') and type"
echo "any 'opencode...' command — it'll auto-split right and start the panel."
echo "Run the panel manually any time with: ~/.local/bin/opencode-panel.sh"
