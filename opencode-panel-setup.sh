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

hr() { local w="$1" ch="${2:--}"; printf '%*s\n' "$w" '' | tr ' ' "$ch"; }
header() { local w="$1" title="$2"; printf '%s%s%s\n' "$C_BOLD$C_CYAN" "$title" "$C_RESET"; hr "$w"; }
# Erases to end of line after every printed row before the newline, so a
# frame whose lines are shorter than the previous frame's (e.g. right after
# a pane resize) never leaves trailing characters from the old frame
# ghosting through the new one — same fix as ccusage-panel.sh.
clear_eol() { awk '{ printf "%s\033[K\n", $0 }'; }

# Same thresholds and floor as ccusage-panel.sh, so "red"/"purple" mean the
# same thing across both tools. A multiple alone is not enough: in a cheap
# session, a turn well above the average in relative terms can still be a
# trivial number in absolute terms, so nothing colors below the floor no
# matter how many times over the average it is.
COST_TIER_YELLOW_MULT=1.5
COST_TIER_RED_MULT=2.0
COST_TIER_PURPLE_MULT=3.0
COST_TIER_MIN_TURN_ALERT=0.50

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
  printf '\033[H'
  cols=$(tput cols 2>/dev/null || echo 60)
  (( cols < 40 )) && cols=40
  rows=$(tput lines 2>/dev/null || echo 24)
  (( rows < 10 )) && rows=10

  {
  printf '%s%s OpenCode usage — %s %s(refresh %ss)%s\n' \
    "$C_BOLD" "──" "$(date '+%a %H:%M:%S')" "$C_DIM" "$REFRESH" "$C_RESET"
  hr "$cols" "="

  if ! command -v opencode >/dev/null 2>&1; then
    echo "opencode CLI not found on PATH."
  else
    list_json=$(opencode session list --format json 2>/dev/null)
    session_id=""
    if [ -n "$list_json" ]; then
      session_id=$(jq -r "$FIND_LATEST" <<<"$list_json" 2>/dev/null)
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
      printf '%s  7-day avg session: $%.3f%s\n' "$C_DIM" "$avg_session_cost" "$C_RESET"
    fi
    echo

    header "$cols" "THIS SESSION — PER TURN"
    if [ -n "$session_id" ]; then
      export_json=$(opencode export "$session_id" 2>/dev/null)
      if [ -n "$export_json" ]; then
        export_tmp=$(mktemp)
        printf '%s\n' "$export_json" > "$export_tmp"
        python3 - "$export_tmp" "$TURN_ROWS" "$avg_session_cost" "$COST_TIER_YELLOW_MULT" "$COST_TIER_RED_MULT" "$COST_TIER_PURPLE_MULT" "$COST_TIER_MIN_TURN_ALERT" <<'PYEOF'
import json, sys

path, max_rows, avg_baseline = sys.argv[1], int(sys.argv[2]), float(sys.argv[3] or 0)
YELLOW_MULT, RED_MULT, PURPLE_MULT = (float(x) for x in sys.argv[4:7])
MIN_TURN_ALERT = float(sys.argv[7])

def fmt_k(n):
    if abs(n) >= 1000:
        return f"{n/1000:.0f}k"
    return str(n)

turns, seen = [], set()
try:
    with open(path) as f:
        lines = f.readlines()
except OSError:
    lines = []

for line in lines:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        continue
    if d.get("type") != "message":
        continue
    data = d.get("data", {})
    if data.get("role") != "assistant":
        continue
    mid = d.get("id")
    if not mid or mid in seen:
        continue
    seen.add(mid)

    tokens = data.get("tokens", {}) or {}
    in_tok = tokens.get("input", 0)
    cache = tokens.get("cache", {}) or {}
    cache_read = cache.get("read", 0)
    cache_write = cache.get("write", 0)
    cost = data.get("cost", 0) or 0

    total_ctx = in_tok + cache_read + cache_write
    cache_pct = (cache_read / total_ctx * 100) if total_ctx else 0.0

    provider = data.get("providerID", "?")
    model = data.get("modelID", "unknown")
    label = f"{provider}/{model}"[:16]

    # Δ is new cache writes this turn, matching the ccusage panel's
    # convention: it's exactly the tokens that weren't already cached,
    # i.e. what a context spike looks like.
    turns.append((label, total_ctx, cache_write, cache_pct, cost))

RED, YELLOW, PURPLE, RESET = "\033[31m", "\033[33m", "\033[38;5;129m", "\033[0m"
total_n = len(turns)
shown = turns[-max_rows:]
if not shown:
    print("  (no assistant turns yet)")
else:
    session_avg = sum(t[4] for t in turns) / total_n if total_n else 0
    # Prefer the 7-day cross-session baseline when we have one; fall back
    # to this session's own average otherwise.
    avg_cost = avg_baseline if avg_baseline > 0 else session_avg
    if total_n > len(shown):
        print(f"  (showing last {len(shown)} of {total_n} turns)")
    print(f"  {'Turn':<6}{'Model':<17}{'Ctx':>7}{'Δ':>8}{'Cache':>7}{'Cost':>8}")
    start_idx = total_n - len(shown) + 1
    for i, (label, total_ctx, delta, cache_pct, cost) in enumerate(shown):
        turn_no = start_idx + i
        row = (f"  {turn_no:<6}{label:<17}{fmt_k(total_ctx):>7}"
               f"{'+' + fmt_k(delta):>8}{cache_pct:>6.0f}%{'$' + format(cost, '.3f'):>8}")
        # Below the absolute floor, never color a turn no matter its
        # multiple of the average, same reasoning as ccusage-panel.sh.
        if cost < MIN_TURN_ALERT:
            print(row)
        elif avg_cost > 0 and cost > avg_cost * PURPLE_MULT:
            print(f"{PURPLE}{row}{RESET}")
        elif avg_cost > 0 and cost > avg_cost * RED_MULT:
            print(f"{RED}{row}{RESET}")
        elif avg_cost > 0 and cost > avg_cost * YELLOW_MULT:
            print(f"{YELLOW}{row}{RESET}")
        else:
            print(row)
    if avg_cost > 0:
        print(f"  (avg ${avg_cost:.3f}/turn, min ${MIN_TURN_ALERT:.2f} to color: purple >{PURPLE_MULT:g}x, red >{RED_MULT:g}x, yellow >{YELLOW_MULT:g}x)")
    session_cost = sum(t[4] for t in turns)
    print(f"  session total so far: ${session_cost:.3f} ({total_n} assistant turns)")
PYEOF
        rm -f "$export_tmp"
      else
        echo "  (couldn't export session $session_id — 'opencode export' may need a newer CLI version)"
      fi
    else
      echo "  (no OpenCode session found — run 'opencode session list --format json' to check)"
    fi
    echo

    # ---- today / week / month: shown as opencode's own output, not
    # parsed, per the note at the top of the installer ----
    header "$cols" "TODAY (opencode stats --days 1)"
    opencode stats --days 1 2>/dev/null | head -n 6 || echo "  (opencode stats not available)"
    echo
    header "$cols" "LAST 7 DAYS (opencode stats --days 7)"
    opencode stats --days 7 2>/dev/null | head -n 6 || echo "  (opencode stats not available)"
  fi
  } | head -n "$((rows - 1))" | clear_eol
  printf '\033[0J'

  sleep "$REFRESH"
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

log "start: TERM_PROGRAM=${TERM_PROGRAM:-unset} PWD=$PWD"

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
