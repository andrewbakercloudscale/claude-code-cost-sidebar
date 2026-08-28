#!/usr/bin/env bash
# Installs the Claude Code live usage panel + auto-split launcher.
#
# What this sets up:
#   ~/.local/bin/ccusage-panel.sh        - live stats panel (context %,
#                                           per-turn cost, active block burn
#                                           rate, today/3-day/week/month,
#                                           top sessions)
#   ~/.local/bin/claude-panel-launch.sh  - opens a right-hand Ghostty split
#                                           running the panel above
#   ~/.local/bin/claude-panel-keyblock   - compiled helper (clang, from a
#                                           heredoc source below) that
#                                           swallows real keyboard input for
#                                           a few seconds while the launcher
#                                           above is driving synthetic
#                                           keystrokes, so accidental typing
#                                           during window setup can't land
#                                           in the new split
#   ~/.zshrc (appended, idempotent)      - a preexec hook that runs the
#                                           launcher once per terminal
#                                           window, the first time a
#                                           `claude*` command is typed
#   ~/.local/bin/ghostty-claude-launcher  - patched in place (idempotent)
#                                           if present, so a Finder Service
#                                           / Automator launch path (which
#                                           execs `claude` directly, with
#                                           no interactive shell involved)
#                                           also gets the split panel
#   ~/.local/bin/claude-cost-alert-check.sh - UserPromptSubmit hook script:
#                                           alerts in the chat itself (works
#                                           over Remote Control) when session
#                                           cost hits red/purple vs its 7-day
#                                           average, or the panel launcher
#                                           failed
#   ~/.claude/settings.json (merged via jq, idempotent) - wires the hook
#                                           above into UserPromptSubmit
#
# Requirements: macOS + Ghostty (for the auto-split part — the panel script
# itself works in any terminal), Node.js (for `ccusage`), jq, clang (Xcode
# Command Line Tools, for the keyboard-guard helper — optional, skipped with
# a warning if missing), and Accessibility permission granted to
# Ghostty/Terminal for the System Events automation, PLUS Accessibility +
# Input Monitoring granted to claude-panel-keyblock for the keyboard guard
# (macOS will prompt the first time each isn't yet granted).
#
# Safe to re-run: overwrites the two scripts with the latest version and
# skips the .zshrc block if it's already present.
set -uo pipefail

BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"

echo "Installing ccusage-panel.sh ..."
cat > "$BIN_DIR/ccusage-panel.sh" <<'PANEL_EOF'
#!/usr/bin/env bash
# Live Claude Code usage panel — everything ccusage knows: context %, live
# block burn rate + projection, today's breakdown, 3-day trend, week/month
# totals, top sessions today, PLUS a per-turn breakdown of the current
# session (turn/model/context size/context growth/cache hit %/est. cost).
# Run this in a Ghostty split (super+d) to keep it visible while you work.
# Auto-launched by the ccusage split-panel autolaunch hook in ~/.zshrc — see
# ~/.local/bin/claude-panel-launch.sh.
set -uo pipefail
export LC_ALL=C LC_NUMERIC=C

REFRESH="${1:-5}"
TURN_ROWS="${2:-12}"
# Set by the autolaunch hook (~/.zshrc) for a bare `claude` invocation,
# which it forces to run with a known --session-id — lets this panel open
# that EXACT transcript instead of guessing "most recently modified file in
# this project directory", which still can't tell two concurrent sessions
# in the same directory apart. Empty for anything else (manual runs,
# `claude --resume`, etc.), which fall back to the directory-scoped guess.
PIN_SESSION_ID="${3:-}"
# Recorded once so the unpinned session-detection fallback below can tell
# "a session that started after I did" from "a session that was already
# running when I started" — see that fallback for why this matters.
PANEL_START_EPOCH=$(date +%s)

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
C_CYAN=$'\033[36m'; C_YELLOW=$'\033[33m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'

fmt_num() {
  awk -v n="$1" 'BEGIN{
    n=n+0; neg=(n<0); if(neg) n=-n;
    n=int(n+0.5); s=sprintf("%d",n); out=""; l=length(s);
    for(i=1;i<=l;i++){ out=out substr(s,i,1); if((l-i)%3==0 && i!=l) out=out "," }
    print (neg?"-":"") out;
  }'
}
fmt_money() { printf '$%.2f' "${1:-0}"; }
fmt_m() { awk -v n="${1:-0}" 'BEGIN{ printf "%.1fM", n/1000000 }'; }
fmt_hm() { local m=${1:-0}; m=${m%.*}; printf '%dh %02dm' $((m/60)) $((m%60)); }

# ---- traffic-light thresholds, shared by every colored figure in the panel ----
TIER_YELLOW_MULT=1.5
TIER_RED_MULT=2.0
BURN_YELLOW=3
BURN_RED=6
CTX_YELLOW=40
CTX_RED=60
CTX_PURPLE=90
# A value only gets colored once it clears an absolute floor — in a cheap
# session (avg $0.05) a $0.13 turn is >2x average and would false-positive
# red on money nobody would look twice at.
MIN_SESSION_ALERT=5.00
MIN_DAILY_ALERT=15.00
MIN_TREND_ALERT=2.00

# value baseline yellow_mult red_mult floor -> green/yellow/red
tier_color() {
  local v="$1" a="$2" ym="$3" rm="$4" floor="${5:-0}" color="$C_GREEN"
  awk -v v="$v" -v a="$a" -v f="$floor" 'BEGIN{exit !(a+0>0 && v+0>=f)}' || { printf '%s' "$color"; return; }
  awk -v v="$v" -v a="$a" -v m="$ym" 'BEGIN{exit !(v+0>a*m)}' && color="$C_YELLOW"
  awk -v v="$v" -v a="$a" -v m="$rm" 'BEGIN{exit !(v+0>a*m)}' && color="$C_RED"
  printf '%s' "$color"
}
# value yellow_threshold red_threshold -> green/yellow/red (no baseline needed)
threshold_color() {
  local v="$1" yt="$2" rt="$3" color="$C_GREEN"
  awk -v v="$v" -v t="$yt" 'BEGIN{exit !(v+0>t)}' && color="$C_YELLOW"
  awk -v v="$v" -v t="$rt" 'BEGIN{exit !(v+0>t)}' && color="$C_RED"
  printf '%s' "$color"
}
# value yellow_threshold red_threshold purple_threshold -> green/yellow/red/purple
# <=yt green, >yt && <=rt yellow, >rt && <=pt red, >pt purple.
ctx_tier_color() {
  local v="$1" yt="$2" rt="$3" pt="$4" color="$C_GREEN"
  awk -v v="$v" -v t="$yt" 'BEGIN{exit !(v+0>t)}' && color="$C_YELLOW"
  awk -v v="$v" -v t="$rt" 'BEGIN{exit !(v+0>t)}' && color="$C_RED"
  awk -v v="$v" -v t="$pt" 'BEGIN{exit !(v+0>t)}' && color="$C_MAGENTA"
  printf '%s' "$color"
}
# Only Sonnet 5 and Fable 5 have a native 1M window; CLAUDE_CODE_DISABLE_1M_CONTEXT=1
# forces those two back to Sonnet 4.6's 200k boundary — see the comment above the
# "Context cap" line below for why that distinction matters.
context_window_size() {
  local size=200000
  case "$1" in
    claude-sonnet-5|claude-fable-5) size=1000000 ;;
  esac
  if [ "$size" = "1000000" ] && [ "${CLAUDE_CODE_DISABLE_1M_CONTEXT:-0}" = "1" ]; then
    size=200000
  fi
  printf '%s' "$size"
}
# model id -> green (cheapest tier, e.g. Haiku) / yellow (mid, e.g. Sonnet) /
# red (most expensive, e.g. Opus/Fable/Mythos) — mirrors the PRICES table in
# the per-turn-table python block below, but keyed on model-name substrings
# since this runs in bash, before that table's exact $/1M figures are in scope.
model_tier_color() {
  case "${1,,}" in
    *haiku*) printf '%s' "$C_GREEN" ;;
    *opus*|*fable*|*mythos*) printf '%s' "$C_RED" ;;
    *) printf '%s' "$C_YELLOW" ;;
  esac
}
# A short colored title, not a full-width divider bar — a bar that's drawn
# at $cols but rendered later in a narrower/resized pane just wraps into a
# confusing second row of "=" or "-", which is worse than no rule at all.
header() { local title="$1"; printf '%s%s%s\n' "$C_BOLD$C_CYAN" "$title" "$C_RESET"; }
# Erases to end of line after every printed row before the newline, so a
# frame whose lines are shorter than the previous frame's (e.g. right after
# a pane resize, or just because the numbers got shorter) never leaves
# trailing characters from the old frame ghosting through the new one.
# Also truncates to $COLS first: \033[K only erases stray characters
# trailing on the SAME physical row, it can't stop an over-long line from
# wrapping onto an extra physical row. In a narrow pane that wrapping let a
# frame's physical row count silently exceed $rows, so the next frame's
# cursor-home (below) landed mid old-content instead of at the true top,
# gluing fragments of consecutive frames together.
#
# Width must be measured on the VISIBLE text only. Raw $0 inflates past the
# line's actual on-screen width two ways: ANSI color codes are invisible
# bytes, and LC_ALL=C (set at the top, needed for numeric formatting
# elsewhere) makes awk's length() count bytes rather than characters, so
# every line's leading multi-byte UTF-8 emoji counts as 3-4 "characters"
# instead of 1. Both inflations made ordinary lines that would never have
# wrapped get hard-truncated anyway, chopping real content off the end
# (e.g. losing the trailing ")" on a 44-char line in a 44-col pane). Strip
# ANSI codes, then subtract UTF-8 continuation bytes (10xxxxxx, i.e.
# \200-\277) — each is one extra byte contributed by a multi-byte
# character, not a visible column — to get the true visible length before
# comparing to width. Only fall back to plain (uncolored) truncated text in
# the genuine-overflow case, and correct the cut point by the same
# continuation-byte count rather than slicing the raw ANSI-laden string.
clear_eol() { awk -v w="${COLS:-999}" '{ line = $0; plain = line; gsub(/\033\[[0-9;]*m/, "", plain); cont = plain; n_cont = gsub(/[\200-\277]/, "", cont); vis_len = length(plain) - n_cont; if (vis_len > w) plain = substr(plain, 1, w + n_cont); printf "%s\033[K\n", (vis_len > w ? plain : line) }'; }

# ---- persisted hourly-cost buckets, used by "Today's Predicted Value" ----
# Forecasts the rest of today from this machine's own historical hour-of-day
# spend pattern, instead of extrapolating ccusage's live burnRate.costPerHour
# (a seconds-scale figure that spikes hugely right after any single pricey
# turn, then decays as cheaper turns dilute it — e.g. $35/hr -> $4.64/hr ->
# $2.21/hr across three refreshes with nothing unusual happening). A full
# 30-day JSONL scan is too slow to redo every 5s refresh, so this only
# rebuilds when the cache is stale; every other refresh just reads the file.
HOURLY_BUCKET_CACHE="$HOME/.cache/claude-hourly-buckets.json"
HOURLY_BUCKET_TTL=900
HOURLY_BUCKET_WINDOW_DAYS=30

refresh_hourly_buckets() {
  local cache_mtime now_epoch lock_dir lock_age
  now_epoch=$(date +%s)
  if [ -f "$HOURLY_BUCKET_CACHE" ]; then
    cache_mtime=$(stat -f %m "$HOURLY_BUCKET_CACHE" 2>/dev/null || stat -c %Y "$HOURLY_BUCKET_CACHE" 2>/dev/null || echo 0)
    if (( now_epoch - cache_mtime < HOURLY_BUCKET_TTL )); then
      return
    fi
  fi

  # Every open panel runs this same loop, so more than one can notice the
  # cache is stale in the same tick. mkdir is atomic on POSIX (no flock
  # dependency) — whichever panel wins the mkdir does the (expensive)
  # rebuild; the rest just keep using the still-valid cache this refresh
  # instead of duplicating the same 30-day scan. Both would compute the
  # same answer from the same shared JSONL files anyway, so this only
  # avoids wasted work, not a correctness issue.
  lock_dir="$HOURLY_BUCKET_CACHE.lock"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    # Held by another panel's rebuild — unless it died mid-rebuild and
    # left the lock behind, which a real rebuild never takes this long.
    lock_age=$(( now_epoch - $(stat -f %m "$lock_dir" 2>/dev/null || stat -c %Y "$lock_dir" 2>/dev/null || echo "$now_epoch") ))
    if (( lock_age > 60 )); then
      rmdir "$lock_dir" 2>/dev/null
      mkdir "$lock_dir" 2>/dev/null || return
    else
      return
    fi
  fi

  mkdir -p "$(dirname "$HOURLY_BUCKET_CACHE")"
  # Same per-model pricing table as the per-turn breakdown below (JSONL
  # entries carry token usage but no precomputed cost) — kept as a separate
  # copy since each heredoc here is a standalone python3 invocation.
  python3 - "$HOURLY_BUCKET_CACHE" "$HOURLY_BUCKET_WINDOW_DAYS" <<'BUCKET_PYEOF'
import glob, json, os, sys, time, datetime as dt

cache_path, window_days = sys.argv[1], int(sys.argv[2])

PRICES = {
    "claude-sonnet-5":   (2.00, 10.00),
    "claude-opus-5":     (5.00, 25.00),
    "claude-haiku-4-5":  (1.00, 5.00),
    "claude-sonnet-4-6": (3.00, 15.00),
    "claude-opus-4-8":   (5.00, 25.00),
    "claude-opus-4-7":   (5.00, 25.00),
    "claude-opus-4-6":   (5.00, 25.00),
    "claude-fable-5":    (10.00, 50.00),
    "claude-mythos-5":   (10.00, 50.00),
}
DEFAULT_PRICE = (3.00, 15.00)
CACHE_READ_MULT, CACHE_WRITE_5M_MULT, CACHE_WRITE_1H_MULT = 0.1, 1.25, 2.0

now = time.time()
cutoff = now - window_days * 86400

bucket_cost = [0.0] * 24
bucket_days = [set() for _ in range(24)]
seen = set()

for path in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")):
    try:
        # A file's mtime is >= its last entry's timestamp (append-only) —
        # if that's still before the window, nothing inside can be in range.
        if os.path.getmtime(path) < cutoff:
            continue
        with open(path) as f:
            lines = f.readlines()
    except OSError:
        continue
    for line in lines:
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if d.get("type") != "assistant":
            continue
        msg = d.get("message", {})
        usage = msg.get("usage")
        mid = msg.get("id")
        ts_str = d.get("timestamp")
        if not usage or not mid or not ts_str or mid in seen:
            continue
        try:
            ts_utc = dt.datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        except ValueError:
            continue
        if ts_utc.timestamp() < cutoff:
            continue
        seen.add(mid)

        model = msg.get("model", "unknown")
        in_tok = usage.get("input_tokens", 0)
        out_tok = usage.get("output_tokens", 0)
        cr_tok = usage.get("cache_read_input_tokens", 0)
        cc_tok = usage.get("cache_creation_input_tokens", 0)
        cc = usage.get("cache_creation") or {}
        cw_1h = cc.get("ephemeral_1h_input_tokens", cc_tok if not cc else 0)
        cw_5m = cc.get("ephemeral_5m_input_tokens", 0)

        price_in, price_out = PRICES.get(model, DEFAULT_PRICE)
        cost = (
            in_tok * price_in
            + out_tok * price_out
            + cr_tok * price_in * CACHE_READ_MULT
            + cw_1h * price_in * CACHE_WRITE_1H_MULT
            + cw_5m * price_in * CACHE_WRITE_5M_MULT
        ) / 1_000_000

        local = ts_utc.astimezone()
        h = local.hour
        bucket_cost[h] += cost
        bucket_days[h].add(local.date().isoformat())

buckets = []
for h in range(24):
    days = len(bucket_days[h])
    avg = bucket_cost[h] / days if days else 0.0
    buckets.append({"hour": h, "totalCost": round(bucket_cost[h], 4), "days": days, "avgCost": round(avg, 4)})

out = {"generatedAt": int(now), "windowDays": window_days, "buckets": buckets}
tmp_path = cache_path + ".tmp"
with open(tmp_path, "w") as f:
    json.dump(out, f)
os.replace(tmp_path, cache_path)
BUCKET_PYEOF
  rmdir "$lock_dir" 2>/dev/null
}

# Save the real terminal fd BEFORE the loop ever redirects fd1 through a
# command-substitution pipe — fd3 keeps pointing at the actual pane device
# no matter what fd1 becomes inside a $(...), and unlike /dev/tty it still
# works for a process with no controlling terminal at all (e.g. one
# relaunched via `nohup ... &` with stdout pointed straight at a pty device
# file) as long as that fd itself is a real tty.
exec 3>&1

while true; do
  # Cursor-home only, NOT a full \033[2J clear — a full clear blanks the
  # whole pane for one frame before the redraw lands, which reads as a
  # visible flicker every refresh. Staying purely additive-overwrite only
  # works because clear_eol() (above) truncates every line to $COLS, so a
  # frame's physical row count can never silently exceed $rows and desync
  # this cursor-home overwrite against the previous frame.
  printf '\033[H'
  # `tput cols`/`tput lines` run inside $(...) have their OWN stdout
  # redirected to the capture pipe, so the ioctl they'd normally use to ask
  # the terminal for its real size fails and they silently return the
  # compiled-in terminfo default (80x24) — a fixed ceiling that has nothing
  # to do with the pane's actual height. `stty size` doesn't have this
  # problem because it reads the size off the fd it's given, so pointing it
  # at fd3 (see above) gets the real, live pane dimensions.
  read -r rows cols < <(stty size <&3 2>/dev/null)
  [ -z "$cols" ] && cols=60
  [ -z "$rows" ] && rows=24
  (( cols < 40 )) && cols=40
  (( rows < 10 )) && rows=10
  export COLS="$cols"

  refresh_hourly_buckets

  # ---- active 5h block: fetched once here (not down in the ACTIVE BLOCK
  # section) so the summary line above can show the same burn-rate-derived
  # color as the detailed section — one source of truth, one API call.
  block_json=$(ccusage blocks --active --json --offline 2>/dev/null)
  has_block=$(jq -r '.blocks | length // 0' <<<"$block_json" 2>/dev/null)
  if [ "${has_block:-0}" = "1" ]; then
    IFS=$'\t' read -r blk_start blk_end blk_cost blk_tokens blk_elapsedSec blk_tpm blk_rem blk_projCost blk_projTokens blk_models <<<"$(jq -r '
      .blocks[0] |
      [
        (.startTime[0:19]+"Z" | fromdateiso8601 | strftime("%H:%M")),
        (.endTime[0:19]+"Z"   | fromdateiso8601 | strftime("%H:%M")),
        .costUSD, .totalTokens,
        ((.startTime[0:19]+"Z" | fromdateiso8601) as $s | (now - $s)),
        .burnRate.tokensPerMinute,
        .projection.remainingMinutes, .projection.totalCost, .projection.totalTokens,
        (.models | join(", "))
      ] | @tsv
    ' <<<"$block_json")"
    # blk_cph is the block's TRUE average $/hr (cost ÷ elapsed time), not
    # ccusage's own burnRate.costPerHour — that field is a seconds-scale
    # instantaneous rate that spikes 10x+ right after any single pricey
    # turn and decays within minutes (same failure mode already worked
    # around for "Today's Predicted Value" above), so it disagreed wildly
    # with the block's actual spend-so-far (e.g. reported $18.93/hr while
    # the block had spent $0.81 in 44 minutes — a true rate of ~$1.11/hr).
    # Floor elapsed at 3 minutes for the same reason sess_elapsed_h does.
    blk_elapsed_h=$(awk -v s="$blk_elapsedSec" 'BEGIN{ h=s/3600; if(h<0.05) h=0.05; print h }')
    blk_cph=$(awk -v c="$blk_cost" -v h="$blk_elapsed_h" 'BEGIN{ printf "%.2f", c/h }')
    burn_color=$(threshold_color "$blk_cph" "$BURN_YELLOW" "$BURN_RED")
    burn_label="Normal"
    [ "$burn_color" = "$C_YELLOW" ] && burn_label="Elevated"
    [ "$burn_color" = "$C_RED" ] && burn_label="High"
  fi

  # ---- current session identity: fetched once here (not inside the
  # guaranteed subshell below) so TOP SESSIONS TODAY, further down, can
  # mark which row is THIS session — a command-substitution subshell can
  # read these variables outside itself but never write them back out.
  #
  # Scoped to THIS project's own transcript directory, not
  # ~/.claude/projects/*/*.jsonl globally — with a second Claude Code
  # session open in another repo, the global glob picks up whichever
  # session most recently wrote a line, so "THIS SESSION" would flip
  # between two unrelated conversations turn-count-and-all every few
  # refreshes (e.g. jumping from turn 50 in this project back to turn 16
  # in another one). The launcher (claude-panel-launch.sh) always opens
  # this panel via a same-cwd Ghostty split, so $PWD reliably names the
  # project this panel belongs to; Claude Code encodes that project's
  # transcript directory as $PWD with every "/" replaced by "-".
  project_dir="$HOME/.claude/projects/$(printf '%s' "$PWD" | tr '/' '-')"
  if [ -n "$PIN_SESSION_ID" ]; then
    latest="$project_dir/$PIN_SESSION_ID.jsonl"
    # The pinned session may not have written its first line yet (osascript
    # is still typing into the new pane) — treat "not there yet" as "no
    # session", same as the unpinned case; the next 5s refresh picks it up.
    [ -f "$latest" ] || latest=""
  else
    # "Most recently modified" picks whichever session is actively being
    # chatted with — including one that's NOT this pane's, if another
    # session in this same project dir is currently mid-conversation. That
    # misattributes an unrelated, already-running session's cost/turns to a
    # brand-new, still-empty session opened without going through the
    # PIN_SESSION_ID launcher path (e.g. a GUI window, `claude --resume`,
    # an IDE-embedded terminal).
    #
    # Prefer instead the newest transcript file CREATED after this panel
    # process itself started (birth time, via macOS `stat -f %B`, not
    # mtime) — a file that didn't exist yet when this panel launched can
    # only be a session that started alongside or after it, which is the
    # best available guess for "the session in this pane" without an
    # explicit pin. Falls back to the old mtime guess only when no such
    # post-launch file exists (e.g. this panel outlived every session it
    # ever watched).
    latest=""
    newest_birth=0
    for f in "$project_dir"/*.jsonl; do
      [ -f "$f" ] || continue
      birth=$(stat -f %B "$f" 2>/dev/null) || continue
      if (( birth > PANEL_START_EPOCH && birth > newest_birth )); then
        newest_birth=$birth
        latest="$f"
      fi
    done
    [ -n "$latest" ] || latest=$(ls -t "$project_dir"/*.jsonl 2>/dev/null | head -1)
  fi
  if [ -n "$latest" ]; then
    IFS=$'\t' read -r sess_id model_id model_label folder_name sess_start_epoch < <(python3 - "$latest" <<'PYEOF'
import datetime, json, os, sys

path = sys.argv[1]
sid = os.path.basename(path).removesuffix(".jsonl")
model = "unknown"
folder = ""
first_ts = None
try:
    with open(path) as f:
        for line in f:
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not folder and d.get("cwd"):
                folder = os.path.basename(d["cwd"])
            if not first_ts and d.get("timestamp"):
                first_ts = d["timestamp"]
            if d.get("type") == "assistant":
                m = d.get("message", {}).get("model")
                if m:
                    model = m
except OSError:
    pass

rest = model.removeprefix("claude-")
parts = rest.split("-")
name = parts[0].capitalize()
nums = parts[1:]
if len(nums) >= 2:
    label = f"{name} {nums[0]}.{nums[1]}"
elif len(nums) == 1:
    label = f"{name} {nums[0]}"
else:
    label = name

epoch = 0
if first_ts:
    epoch = int(datetime.datetime.fromisoformat(first_ts.replace("Z", "+00:00")).timestamp())
print(f"{sid}\t{model}\t{label}\t{folder}\t{epoch}")
PYEOF
    )
    # Floor elapsed time at 3 minutes — a session-so-far rate computed over
    # the first few seconds swings wildly and would flash red/green noise.
    sess_elapsed_h=$(awk -v s="$sess_start_epoch" -v n="$(date +%s)" 'BEGIN{ h=(n-s)/3600; if(h<0.05) h=0.05; print h }')
  fi

  # Everything through the per-turn table is GUARANTEED — printed in full,
  # never truncated, even on a short pane — so "show N turns" always means
  # N turns, not "N turns if there's room after the other sections." Only
  # the sections below it (active block onward, less essential) compete
  # for whatever pane height is left over.
  guaranteed=$( {
  printf '%s%s Claude Code usage — %s (refresh %ss)%s\n' \
    "$C_BOLD" "──" "$(date '+%a %H:%M:%S')" "$REFRESH" "$C_RESET"
  # ---- baselines: average per-session cost over 7 days, total spend over
  # 30 days. Session average needs >=3 real sessions to trust — otherwise a
  # single earlier tiny/huge session would skew it.
  since7=$(date -v-7d +%Y%m%d 2>/dev/null || date -d '7 days ago' +%Y%m%d)
  baseline_json=$(ccusage session --json --since "$since7" --offline 2>/dev/null)
  avg_session_cost=$(jq -r '
    [.session[].totalCost] | map(select(. > 0.05)) |
    if length >= 3 then (add/length) else 0 end
  ' <<<"$baseline_json" 2>/dev/null)
  [ -z "$avg_session_cost" ] && avg_session_cost=0

  since30=$(date -v-29d +%Y%m%d 2>/dev/null || date -d '29 days ago' +%Y%m%d)
  spend30=$(ccusage daily --json --since "$since30" --offline 2>/dev/null | jq -r '.totals.totalCost // 0')
  [ -z "$spend30" ] && spend30=0
  avg_daily_30=$(awk -v s="$spend30" 'BEGIN{ printf "%.4f", s/29 }')

  # ---- trend baselines: the SAME two windows one period earlier, so the
  # 7-day-avg and 30-day-spend lines can be traffic-lit against "am I
  # spending more than I was a week/month ago" rather than against
  # themselves (a baseline has nothing to compare to but its own past).
  prev7_since=$(date -v-14d +%Y%m%d 2>/dev/null || date -d '14 days ago' +%Y%m%d)
  prev7_until=$(date -v-8d +%Y%m%d 2>/dev/null || date -d '8 days ago' +%Y%m%d)
  prev7_avg=$(ccusage session --json --since "$prev7_since" --until "$prev7_until" --offline 2>/dev/null | jq -r '
    [.session[].totalCost] | map(select(. > 0.05)) |
    if length >= 3 then (add/length) else 0 end
  ' 2>/dev/null)
  [ -z "$prev7_avg" ] && prev7_avg=0

  prev30_since=$(date -v-58d +%Y%m%d 2>/dev/null || date -d '58 days ago' +%Y%m%d)
  prev30_until=$(date -v-30d +%Y%m%d 2>/dev/null || date -d '30 days ago' +%Y%m%d)
  prev_spend30=$(ccusage daily --json --since "$prev30_since" --until "$prev30_until" --offline 2>/dev/null | jq -r '.totals.totalCost // 0')
  [ -z "$prev_spend30" ] && prev_spend30=0
  prev_avg_daily_30=$(awk -v s="$prev_spend30" 'BEGIN{ printf "%.4f", s/29 }')

  # ---- live status line (current session) ----
  # sess_id/model_id/model_label/folder_name/sess_start_epoch were already
  # resolved once, up top, before this subshell — needs the REAL
  # session_id and model.id: a placeholder session_id ("live") matches no
  # recorded session (session cost silently comes back $-0.00), and an
  # unset model.id makes ccusage assume an old 200k context window instead
  # of Sonnet 5's actual 1M, so context% reads >100%.
  if [ -n "$latest" ]; then
    payload=$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","model":{"id":"%s","display_name":"%s"},"workspace":{"current_dir":"%s","project_dir":"%s"},"version":"1.0","output_style":{"name":"default"}}' \
      "$sess_id" "$latest" "$PWD" "$model_id" "$model_label" "$PWD" "$PWD")
    statusline_out=$(echo "$payload" | ccusage statusline -B text 2>/dev/null)
    # One metric per line rather than piping the whole thing through `fold`
    # — a fold-wrapped line breaks mid-word depending on pane width, which
    # reads badly at 1/3 width. ccusage joins fields with " | "; split on
    # that and print each on its own line instead.
    old_ifs="$IFS"
    IFS='|' read -ra statusline_segs <<< "$statusline_out"
    IFS="$old_ifs"
    n_segs=${#statusline_segs[@]}
    for i in "${!statusline_segs[@]}"; do
      seg="${statusline_segs[$i]}"
      seg="${seg#"${seg%%[![:space:]]*}"}"
      seg="${seg%"${seg##*[![:space:]]}"}"
      if [ "$i" -eq 0 ]; then
        # "🤖 Sonnet 5" -> "🤖 Model: Sonnet 5" — every metric below gets
        # the same "icon  Label: value" shape, icons unchanged.
        m_emoji="${seg%% *}"; m_rest="${seg#* }"
        mtc=$(model_tier_color "${model_id:-}")
        printf '  %s Model: %s%s%s\n' "$m_emoji" "$mtc" "$m_rest" "$C_RESET"
      elif [ "$i" -eq 1 ]; then
        # The cost segment ("💰 $X session / $Y today / $Z block (...)")
        # is the widest one and the one most likely to wrap mid-word on a
        # narrow pane — give session/today/block their own lines. Split
        # only on " / " (space-slash-space), the separator ccusage uses
        # between those three fields — a bare "/" also turns up inside
        # the trailing burn rate, e.g. "$2.10/hr", and must not be split.
        IFS=$'\n' read -rd '' -a cost_parts < <(printf '%s' "$seg" | sed 's# / #\n#g'; printf '\0')
        # Session/today $ figures are colored against their own baselines
        # (7-day avg session, 30-day daily avg); ccusage's own text for the
        # third ("block") field is discarded here — the block/burn lines
        # below are reconstructed from the JSON block fetch above instead,
        # since that's the same real number the ACTIVE BLOCK section uses
        # and doesn't depend on scraping ccusage's rendered string.
        sess_part="${cost_parts[0]}"
        sess_emoji="${sess_part%% *}"
        if [[ "$sess_part" =~ \$(-?[0-9.]+) ]]; then
          sess_amt="${BASH_REMATCH[1]}"
          sc=$(tier_color "$sess_amt" "$avg_session_cost" "$TIER_YELLOW_MULT" "$TIER_RED_MULT" "$MIN_SESSION_ALERT")
          # THIS session's own $/hr (spend so far ÷ time since its first
          # message) — separate from the block burn rate below, which is
          # every session's combined spend in the current 5h window, not
          # just this one. Shown on the same row as the spend it's derived
          # from rather than its own line.
          sess_rate=$(awk -v c="$sess_amt" -v h="$sess_elapsed_h" 'BEGIN{ printf "%.2f", c/h }')
          src=$(threshold_color "$sess_rate" "$BURN_YELLOW" "$BURN_RED")
          printf '  %s Session: %s$%s%s, Burn %s$%s/hr%s\n' \
            "$sess_emoji" "$sc" "$sess_amt" "$C_RESET" "$src" "$sess_rate" "$C_RESET"
        else
          printf '  %s\n' "$sess_part"
        fi

        today_part="${cost_parts[1]:-}"
        if [[ "$today_part" =~ \$(-?[0-9.]+) ]]; then
          today_amt="${BASH_REMATCH[1]}"
          tc=$(tier_color "$today_amt" "$avg_daily_30" "$TIER_YELLOW_MULT" "$TIER_RED_MULT" "$MIN_DAILY_ALERT")
          # today_amt (actual, already spent) + a forecast for the hours
          # still remaining today. Deliberately NOT a flat current-rate
          # extrapolation (blk_cph*10) — that rate is a seconds-scale figure
          # that spikes 10x+ right after a single pricey turn and decays
          # within minutes, which made this line swing wildly (e.g.
          # $350 -> $46 -> $22 across three 5s refreshes with nothing
          # unusual happening).
          #
          # The remaining-hours forecast itself is the persisted bucket
          # cache's historical average per hour-of-day, SCALED by how
          # today's pace compares to a typical day's pace so far — not used
          # unscaled. An unscaled historical average ignores today entirely:
          # on a quiet day (e.g. $17.93 spent by 14:48 against a ~$274
          # historical average for hours 0-14) it forecast $215 for the
          # day, back near the 30-day average, regardless of how light
          # today had actually been. pace_ratio = today_amt ÷ the same
          # buckets' historical average for hours 0..now; ratio 1 (no
          # scaling) when there's no historical baseline yet (cold cache).
          current_hour=$(( 10#$(date +%H) ))
          IFS=$'\t' read -r typical_so_far remaining_avg <<<"$(jq -r --argjson ch "$current_hour" '
            ( [.buckets[]? | select(.hour <= $ch) | .avgCost] | add // 0 ) as $ts |
            ( [.buckets[]? | select(.hour >  $ch) | .avgCost] | add // 0 ) as $ra |
            [$ts, $ra] | @tsv
          ' "$HOURLY_BUCKET_CACHE" 2>/dev/null)"
          [ -z "$typical_so_far" ] && typical_so_far=0
          [ -z "$remaining_avg" ] && remaining_avg=0
          today_pred=$(awk -v b="$today_amt" -v ts="$typical_so_far" -v ra="$remaining_avg" 'BEGIN{
            ratio = (ts > 0) ? b/ts : 1
            printf "%.2f", b + ratio*ra
          }')
          pc=$(tier_color "$today_pred" "$avg_daily_30" "$TIER_YELLOW_MULT" "$TIER_RED_MULT" "$MIN_DAILY_ALERT")
          printf '  📅 Today Value: %s$%s%s (proj %s$%s%s)\n' \
            "$tc" "$today_amt" "$C_RESET" "$pc" "$today_pred" "$C_RESET"
        fi

        if [ "${has_block:-0}" = "1" ]; then
          printf '  ⏳ Current Time Block: %s%s%s (%s left)\n' "$burn_color" "$(fmt_money "$blk_cost")" "$C_RESET" "$(fmt_hm "$blk_rem")"
          # This is the true average burn rate (blk_cost ÷ elapsed time)
          # across ALL sessions active in the current 5h block, not just
          # this one — ccusage's block cost total is already aggregated
          # across every concurrent session; see blk_cph derivation above
          # for why it's recomputed here instead of trusting ccusage's own
          # burnRate.costPerHour.
          printf '  🔥 All Sessions Burn Rate: %s%s/hr%s (%s)\n' \
            "$burn_color" "$(fmt_money "$blk_cph")" "$C_RESET" "$burn_label"
        else
          printf '  ⏳ Current Time Block: (no active block)\n'
        fi
      elif [ "$i" -eq $((n_segs - 1)) ] && [[ "$seg" =~ ([0-9,]+)\ \(([0-9]+)%\) ]]; then
        # Context segment — recompute the window size and % ourselves
        # rather than trust ccusage's own %. ccusage assumes each model's
        # native window (1M for Sonnet 5) regardless of whether
        # CLAUDE_CODE_DISABLE_1M_CONTEXT forced the real active boundary
        # back to 200k, which is exactly the mismatch that made context
        # usage impossible to keep in check this week.
        ctx_tokens="${BASH_REMATCH[1]//,/}"
        win_size=$(context_window_size "$model_id")
        ctx_pct=$(awk -v t="$ctx_tokens" -v w="$win_size" 'BEGIN{ printf "%.0f", (w>0? t*100/w:0) }')
        ctx_color=$(ctx_tier_color "$ctx_pct" "$CTX_YELLOW" "$CTX_RED" "$CTX_PURPLE")
        forced_note=""
        if [ "$win_size" = "200000" ] && [[ "$model_id" == "claude-sonnet-5" || "$model_id" == "claude-fable-5" ]]; then
          forced_note=" [forced 200k]"
        fi
        printf '  🧠 Context Usage: %s%s / %s tokens (%s%%)%s%s\n' \
          "$ctx_color" "$(fmt_m "$ctx_tokens")" "$(fmt_m "$win_size")" "$ctx_pct" "$C_RESET" "$forced_note"
      elif [ "$i" -ne 2 ] || [ "$n_segs" -lt 4 ]; then
        # Skip ccusage's own middle "burn rate" segment when present (i==2
        # of 4) — already printed above from the JSON fetch; anything else
        # prints as-is (nothing currently falls here besides the two cases
        # above, but kept as a safety net if ccusage adds a segment).
        printf '  %s\n' "$seg"
      fi
    done
    # Show just the project folder name (from the transcript's own "cwd"
    # field), not Claude Code's sanitized full-path directory name — the
    # latter is the whole path with slashes turned into dashes and can run
    # well past a narrow 1/3-width split.
    folder_disp="${folder_name:-unknown}"
    folder_maxw=$(( cols - 12 )); (( folder_maxw < 10 )) && folder_maxw=10
    if [ "${#folder_disp}" -gt "$folder_maxw" ]; then
      folder_disp="${folder_disp:0:$((folder_maxw - 3))}..."
    fi
    if [ "${has_block:-0}" = "1" ]; then
      printf '  📁 Folder: %s   proj. %s\n' "$folder_disp" "$(fmt_money "$blk_projCost")"
    else
      printf '  📁 Folder: %s\n' "$folder_disp"
    fi
    # Both trend lines below are colored against the SAME window one period
    # earlier (this week's avg vs last week's, this month's spend vs last
    # month's) — a baseline has no natural threshold of its own, but a
    # widening gap vs its own past is exactly the "am I burning through
    # tokens faster than before" signal worth a color for.
    spendc=$(tier_color "$spend30" "$prev_spend30" "$TIER_YELLOW_MULT" "$TIER_RED_MULT" "$MIN_TREND_ALERT")
    if awk -v a="$avg_daily_30" 'BEGIN{exit !(a>0)}'; then
      avgc=$(tier_color "$avg_daily_30" "$prev_avg_daily_30" "$TIER_YELLOW_MULT" "$TIER_RED_MULT" "$MIN_TREND_ALERT")
      printf '  💵 30-Day Value: %s%s%s (avg %s%s/day%s)\n' \
        "$spendc" "$(fmt_money "$spend30")" "$C_RESET" "$avgc" "$(fmt_money "$avg_daily_30")" "$C_RESET"
    else
      printf '  💵 30-Day Value: %s%s%s\n' "$spendc" "$(fmt_money "$spend30")" "$C_RESET"
    fi
  else
    echo "no active Claude Code session found"
  fi
  echo

  # ---- per-turn breakdown of the current session ----
  # ccusage doesn't expose per-message cost (session/daily/blocks only give
  # per-session/day/block totals), so this reads the transcript directly and
  # prices each turn itself. Rates below are Anthropic's published per-model
  # $/1M input & output; cache read/write are the standard multiples of the
  # input rate (0.1x read, 1.25x 5m write, 2x 1h write). Sonnet 5's launch
  # rate of $2/$10 was made permanent on 2026-08-10, cancelling the planned
  # increase to $3/$15; verify this has not changed again before trusting it.
  if [ -n "$latest" ]; then
    python3 - "$latest" "$TURN_ROWS" "$C_BOLD$C_CYAN" "$C_RESET" \
      "$C_DIM" "$C_CYAN" "$C_GREEN" "$C_BLUE" "$C_RED" "$C_YELLOW" \
      "${burn_color:-$C_RESET}" "$(fmt_money "${blk_cph:-0}")" <<'PYEOF'
import json, sys

path, max_rows, c_head, c_reset = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
col_turn, col_model, col_input, col_cache, col_cost, col_mid_tier = sys.argv[5:11]
burn_color, burn_str = sys.argv[11], sys.argv[12]

PRICES = {  # model id -> (input $/1M, output $/1M)
    "claude-sonnet-5":   (2.00, 10.00),
    "claude-opus-5":     (5.00, 25.00),
    "claude-haiku-4-5":  (1.00, 5.00),
    "claude-sonnet-4-6": (3.00, 15.00),
    "claude-opus-4-8":   (5.00, 25.00),
    "claude-opus-4-7":   (5.00, 25.00),
    "claude-opus-4-6":   (5.00, 25.00),
    "claude-fable-5":    (10.00, 50.00),
    "claude-mythos-5":   (10.00, 50.00),
}
DEFAULT_PRICE = (3.00, 15.00)
CACHE_READ_MULT, CACHE_WRITE_5M_MULT, CACHE_WRITE_1H_MULT = 0.1, 1.25, 2.0

def model_label(model_id):
    rest = model_id.removeprefix("claude-")
    parts = rest.split("-")
    name = parts[0].capitalize()
    nums = parts[1:]
    if len(nums) >= 2:
        return f"{name} {nums[0]}.{nums[1]}"
    if len(nums) == 1:
        return f"{name} {nums[0]}"
    return name

def fmt_k(n):
    if abs(n) >= 1000:
        return f"{n/1000:.0f}k"
    return str(n)

def model_tier_color(model_id):
    m = model_id.lower()
    if "haiku" in m:
        return col_input
    if "opus" in m or "fable" in m or "mythos" in m:
        return col_cost
    return col_mid_tier

turns, seen = [], set()
try:
    with open(path) as f:
        lines = f.readlines()
except OSError:
    lines = []

for line in lines:
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        continue
    if d.get("type") != "assistant":
        continue
    msg = d.get("message", {})
    usage = msg.get("usage")
    mid = msg.get("id")
    if not usage or not mid or mid in seen:
        continue
    seen.add(mid)

    model = msg.get("model", "unknown")
    in_tok = usage.get("input_tokens", 0)
    out_tok = usage.get("output_tokens", 0)
    cr_tok = usage.get("cache_read_input_tokens", 0)
    cc_tok = usage.get("cache_creation_input_tokens", 0)
    cc = usage.get("cache_creation") or {}
    cw_1h = cc.get("ephemeral_1h_input_tokens", cc_tok if not cc else 0)
    cw_5m = cc.get("ephemeral_5m_input_tokens", 0)

    total_ctx = in_tok + cr_tok + cc_tok
    cache_pct = (cr_tok / total_ctx * 100) if total_ctx else 0.0

    price_in, price_out = PRICES.get(model, DEFAULT_PRICE)
    cost = (
        in_tok * price_in
        + out_tok * price_out
        + cr_tok * price_in * CACHE_READ_MULT
        + cw_1h * price_in * CACHE_WRITE_1H_MULT
        + cw_5m * price_in * CACHE_WRITE_5M_MULT
    ) / 1_000_000

    turns.append((model_label(model), total_ctx, cc_tok, cache_pct, cost, model))

total_n = len(turns)
shown = turns[-max_rows:]
head_label = f"{c_head}This Session{c_reset}, Burn  {burn_color}{burn_str}/hr{c_reset}"
if not shown:
    print(head_label)
    print("  (no assistant turns yet)")
else:
    print(head_label)
    turn_h = f"{col_turn}{'Turn':<5}{c_reset}"
    model_h = f"{col_model}{'Model':<10}{c_reset}"
    input_h = f"{col_input}{'Input (Δ)':>12}{c_reset}"
    cache_h = f"{col_cache}{'Cache':>6}{c_reset}"
    cost_h = f"{col_cost}{'Cost':>8}{c_reset}"
    print(f"  {turn_h}{model_h}{input_h}{cache_h}{cost_h}")
    start_idx = total_n - len(shown) + 1
    # Newest turn first — this table sits at a fixed position above the
    # sections below it, so the most recent activity would otherwise be the
    # one row that scrolls out of view first as the session grows.
    for i in reversed(range(len(shown))):
        label, total_ctx, delta, cache_pct, cost, model = shown[i]
        turn_no = start_idx + i
        input_cell = f"{fmt_k(total_ctx)} (+{fmt_k(delta)})"
        label_cell = f"{model_tier_color(model)}{label:<10}{c_reset}"
        print(f"  {turn_no:<5}{label_cell}{input_cell:>12}{cache_pct:>5.0f}%{'$' + format(cost, '.2f'):>8}")
PYEOF
  else
    header "THIS SESSION"
    echo "  (no active Claude Code session found)"
  fi
  } )
  printf '%s\n' "$guaranteed" | clear_eol
  used_lines=$(printf '%s\n' "$guaranteed" | wc -l | tr -d ' ')
  remaining=$(( rows - 1 - used_lines ))

  if (( remaining > 0 )); then
  {
  echo

  # ---- recent: today's totals/models + 3-day trend + week/month, one
  # header. Was three separate headers (TODAY, LAST 3 DAYS, WEEK / MONTH)
  # with a bar chart eating 3 rows for 3 numbers — merged so this whole
  # block reliably fits above the fold instead of scrolling off a short
  # pane.
  header "Recent"
  daily_json=$(ccusage daily --json --last 1 --offline 2>/dev/null)
  if [ -n "$daily_json" ] && [ "$(jq -r '.daily | length' <<<"$daily_json" 2>/dev/null)" != "0" ]; then
    IFS=$'\t' read -r tCost tTok tIn tOut tCacheC tCacheR <<<"$(jq -r '
      .totals | [.totalCost, .totalTokens, .inputTokens, .outputTokens, .cacheCreationTokens, .cacheReadTokens] | @tsv
    ' <<<"$daily_json")"
    printf '  today    %s  %s tok\n' "$(fmt_money "$tCost")" "$(fmt_m "$tTok")"
    models_line=""
    while IFS=$'\t' read -r mname mcost mtok; do
      [ -z "$mname" ] && continue
      seg="${mname#claude-} $(fmt_money "$mcost") ($(fmt_m "$mtok"))"
      models_line="${models_line:+$models_line  |  }$seg"
    done < <(jq -r '.daily[0].modelBreakdowns[]? | [.modelName, .cost, (.inputTokens+.outputTokens+.cacheCreationTokens+.cacheReadTokens)] | @tsv' <<<"$daily_json")
    printf '  %s\n' "$models_line"
  else
    echo "  (no usage yet today)"
  fi
  since3=$(date -v-2d +%Y%m%d 2>/dev/null || date -d '2 days ago' +%Y%m%d)
  trend_json=$(ccusage daily --json --since "$since3" --offline 2>/dev/null)
  if [ -n "$trend_json" ]; then
    trend_line=""
    while IFS=$'\t' read -r day dcost dtok; do
      [ -z "$day" ] && continue
      seg="${day:5} $(fmt_money "$dcost")"
      trend_line="${trend_line:+$trend_line  }$seg"
    done < <(jq -r '.daily[] | [.period, .totalCost, .totalTokens] | @tsv' <<<"$trend_json")
    printf '  3d    %s\n' "$trend_line"
  fi
  week_cost=$(ccusage weekly --json --last 1 --offline 2>/dev/null | jq -r '.totals.totalCost // 0')
  month_cost=$(ccusage monthly --json --last 1 --offline 2>/dev/null | jq -r '.totals.totalCost // 0')
  printf '  week  %s   month  %s\n' "$(fmt_money "$week_cost")" "$(fmt_money "$month_cost")"
  echo

  # ---- top sessions today: which session is consuming the day's spend ----
  header "TOP SESSIONS TODAY"
  session_json=$(ccusage session --json --since "$(date +%Y%m%d)" --offline 2>/dev/null)
  if [ -n "$session_json" ] && [ "$(jq -r '.session | length' <<<"$session_json" 2>/dev/null)" != "0" ]; then
    while IFS=$'\t' read -r sid scost stok slast; do
      [ -z "$sid" ] && continue
      lasthm=$(jq -rn --arg t "$slast" '($t[0:19]+"Z") | fromdateiso8601 | strftime("%H:%M")' 2>/dev/null)
      row=$(printf '%-10s %8s  %s tok  last %s' "${sid:0:10}" "$(fmt_money "$scost")" "$(fmt_m "$stok")" "$lasthm")
      if [ "$sid" = "${sess_id:-}" ]; then
        printf '  %s%s *this%s\n' "$C_BOLD" "$row" "$C_RESET"
      else
        printf '  %s\n' "$row"
      fi
    done < <(jq -r '.session | sort_by(-.totalCost) | .[0:5][] | [.period, .totalCost, .totalTokens, .metadata.lastActivity] | @tsv' <<<"$session_json")
  else
    echo "  (none)"
  fi
  } | head -n "$remaining" | clear_eol
  fi
  printf '\033[0J'

  sleep "$REFRESH"
done
PANEL_EOF
chmod +x "$BIN_DIR/ccusage-panel.sh"

echo "Installing claude-panel-keyblock (keyboard guard for the auto-split) ..."
# Swallows real keyboard input system-wide for a few seconds while
# claude-panel-launch.sh is driving synthetic keystrokes into the new split,
# so typing during that window can't land in the wrong pane or get
# interleaved into the command being typed and corrupt it.
#
# Safety valves against ever getting "stuck blocked":
#   - the event tap is owned by this process; macOS tears it down the moment
#     the process exits, crashes, or is killed — there is no way to leave
#     the keyboard blocked after this process is gone
#   - CFRunLoopRunInMode returns on its own after $1 seconds even if no
#     events arrive, so the normal path always exits by itself
#   - a SIGALRM backstop fires ~2s after that in case the run loop ever
#     wedges, and the duration argument is hard-capped at 15s regardless of
#     what's passed in
#
# Real vs. synthetic keystrokes are told apart via kCGEventSourceUnixProcessID:
# hardware-originated events report source pid 0; keystrokes that "System
# Events" (osascript's keystroke command) posts on our behalf report ITS
# pid. So real typing gets dropped and the launcher's own automation still
# gets through untouched.
KEYBLOCK_SRC="$(mktemp -t claude-panel-keyblock).c"
cat > "$KEYBLOCK_SRC" <<'KEYBLOCK_EOF'
#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static CGEventRef tap_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    (void)proxy; (void)type; (void)refcon;
    int64_t source_pid = CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
    if (source_pid == 0) {
        return NULL; /* hardware-originated keystroke: swallow it */
    }
    return event; /* synthetic (posted by System Events on our behalf): let it through */
}

static void on_alarm(int sig) {
    (void)sig;
    _exit(0); /* hard backstop: exit unconditionally, tearing the tap down with us */
}

int main(int argc, char **argv) {
    double duration = argc > 1 ? atof(argv[1]) : 2.5;
    if (duration <= 0 || duration > 15) duration = 2.5;

    signal(SIGALRM, on_alarm);
    alarm((unsigned int)duration + 2);

    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown)
                      | CGEventMaskBit(kCGEventKeyUp)
                      | CGEventMaskBit(kCGEventFlagsChanged);
    CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                                          kCGEventTapOptionDefault, mask, tap_callback, NULL);
    if (!tap) {
        fprintf(stderr, "claude-panel-keyblock: failed to create event tap "
                        "(grant Accessibility + Input Monitoring to this binary)\n");
        return 1;
    }
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, duration, false);

    CGEventTapEnable(tap, false);
    CFMachPortInvalidate(tap);
    CFRelease(tap);
    CFRelease(src);
    return 0;
}
KEYBLOCK_EOF
if command -v clang >/dev/null 2>&1; then
  if clang -O2 -Wall -framework ApplicationServices -framework CoreFoundation \
      -o "$BIN_DIR/claude-panel-keyblock" "$KEYBLOCK_SRC" 2>/tmp/claude-panel-keyblock-build.log; then
    chmod +x "$BIN_DIR/claude-panel-keyblock"
    echo "Built ~/.local/bin/claude-panel-keyblock."
    echo "NOTE: the first time it runs, macOS will ask you to grant it Accessibility"
    echo "and Input Monitoring access (System Settings > Privacy & Security) — approve"
    echo "both, otherwise it just logs a failure and the launcher proceeds unblocked."
  else
    echo "WARNING: failed to build claude-panel-keyblock (see /tmp/claude-panel-keyblock-build.log)."
    echo "The auto-split launcher will still work, just without the keyboard guard."
  fi
else
  echo "WARNING: no clang found — skipping claude-panel-keyblock (keyboard guard)."
  echo "The auto-split launcher will still work, just without the keyboard guard."
fi
rm -f "$KEYBLOCK_SRC"

echo "Installing claude-panel-launch.sh ..."
cat > "$BIN_DIR/claude-panel-launch.sh" <<'LAUNCH_EOF'
#!/usr/bin/env bash
# Opens a right-hand Ghostty split running the live ccusage panel, shrinks
# it to ~1/3 of the window width (splits are created 50/50 by default),
# then returns keyboard focus to the left (original) pane. Invoked once
# per terminal window by the ccusage split-panel autolaunch hook in
# ~/.zshrc, or directly by ~/.local/bin/ghostty-claude-launcher. Needs the
# ctrl+shift+h/l resize_split keybinds in ~/.config/ghostty/config
# (installed by claude-panel-setup.sh).
#
# Every invocation writes a run to $LOG, one line per step, prefixed with
# a shared run id so concurrent/rapid invocations (opening several windows
# at once) don't interleave into an unreadable mess. Read it with:
#   tail -50 ~/.cache/claude-panel-launch.log
#
# This retries up to 3 times and, critically, VERIFIES success by checking
# for an actual new ccusage-panel.sh process afterward rather than trusting
# AppleScript's own exit code — an early version logged "ok" while doing
# nothing, because a stale frontmost check or a silent internal early
# "return" inside the AppleScript both exit 0 with no stderr.
set -uo pipefail

LOG="$HOME/.cache/claude-panel-launch.log"
mkdir -p "$(dirname "$LOG")"
RUN_ID="$(date '+%H%M%S')-$$"
log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RUN_ID" "$1" >> "$LOG"; }

panel_pids() { pgrep -f '[b]in/ccusage-panel\.sh' 2>/dev/null | sort; }

# Passed by the autolaunch hook only for a bare `claude` invocation, which
# it forces to run with this same ID via --session-id — lets the panel open
# that exact transcript instead of guessing by mtime. Empty for anything
# else, and the panel falls back to its own directory-scoped guess.
PIN_SID="${1:-}"
PANEL_CMD="~/.local/bin/ccusage-panel.sh"
[ -n "$PIN_SID" ] && PANEL_CMD="~/.local/bin/ccusage-panel.sh 5 12 $PIN_SID"

log "start: TERM_PROGRAM=${TERM_PROGRAM:-unset} TMUX=${TMUX:-unset} PWD=$PWD PIN_SID=${PIN_SID:-none}"

# Inside tmux, TERM_PROGRAM gets overridden (often to "tmux") regardless of
# the outer terminal, so the Ghostty check below never sees "ghostty" even
# when Ghostty is the real host — the launcher aborted silently for every
# tmux user. tmux has its own native split primitive that needs no
# Accessibility permission and no keystroke simulation, so prefer it
# whenever we're inside a tmux client at all, before falling through to the
# Ghostty/osascript path.
if [ -n "${TMUX:-}" ]; then
  if ! command -v tmux >/dev/null 2>&1; then
    log "abort: TMUX is set but tmux binary not found"
    exit 0
  fi
  if tmux split-window -h -l 33% "$PANEL_CMD" 2>>"$LOG"; then
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

  # Block real keyboard input for the settle delay + the whole keystroke
  # sequence below (worst case, a wide monitor's resize-repeat loop, runs
  # ~4s) so anything typed while the window is still settling can't land in
  # the new split or get woven into the command being typed into it. Fully
  # self-bounded: it exits on its own after the duration below even if this
  # script dies first — see claude-panel-keyblock's own comments for the
  # safety valves. Best-effort: missing binary or ungranted permissions
  # just mean no guard, same as before this existed.
  if [ -x "$HOME/.local/bin/claude-panel-keyblock" ]; then
    "$HOME/.local/bin/claude-panel-keyblock" 6 >>"$LOG" 2>&1 &
    log "attempt $attempt: keyboard guard started (pid $!, 6s)"
  fi

  # Settle delay: frontmost can flip true right as a cold `open -na` launch
  # is still mid-activation-animation, before the window can reliably
  # receive keystrokes.
  sleep 0.3

  # Everything below — the frontmost re-check, the window-width read, the
  # resize math, and every keystroke — happens inside ONE osascript call.
  # Splitting this across two calls previously let frontmost change out
  # from under the second one, and both halves would separately exit 0.
  result=$(osascript <<APPLESCRIPT 2>&1
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
    keystroke "$PANEL_CMD"
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
  log "done: troubleshooting — confirm ctrl+shift+h/l keybinds exist in ~/.config/ghostty/config, confirm ~/.local/bin/ccusage-panel.sh is executable, try running it manually"
fi

exit 0
LAUNCH_EOF
chmod +x "$BIN_DIR/claude-panel-launch.sh"

ZSHRC="$HOME/.zshrc"
MARKER="# --- ccusage split-panel autolaunch"
if [ -f "$ZSHRC" ] && grep -qF "$MARKER" "$ZSHRC"; then
  echo "~/.zshrc already has the autolaunch hook — leaving it as-is."
else
  echo "Adding the autolaunch hook to ~/.zshrc ..."
  cat >> "$ZSHRC" <<'ZSHRC_EOF'

# --- ccusage split-panel autolaunch (installed by claude-panel-setup.sh) ---
# Fires once per terminal window, the first time a `claude*` command runs:
# opens a right-hand Ghostty split running the live usage panel, then
# returns focus to the left pane.
#
# A fresh `claude` invocation (no existing-session flag — the common
# "fresh session in a new window" case) is additionally pinned to a known
# session ID, so the panel can open that EXACT transcript instead of
# guessing "most recently modified file in this project directory" — a
# guess that still can't tell two concurrent `claude` sessions in the SAME
# directory apart. This used to require the command to be the literal bare
# word "claude" with NO arguments at all, which almost never happens in
# practice — `claude --dangerously-skip-permissions`, `caffeinate -d claude`,
# and similar everyday variants all failed the exact-string match, so
# CLAUDE_PANEL_PIN_SID was never set and the panel silently fell back to the
# directory-scoped guess on every real launch, occasionally showing a stale
# session's turns when the project directory held more than one transcript.
# Now any `claude ...` invocation is pinned UNLESS it already carries its
# own session semantics (--resume/-r, --continue/-c, --session-id) — those
# already know which transcript they mean and forcing a second --session-id
# onto them would conflict. preexec can't rewrite the command it's about to
# run, so it exports CLAUDE_PANEL_PIN_SID instead; the `claude` wrapper below
# injects --session-id and chains to whatever `claude` function/alias
# already existed (e.g. an npm/AWS credential-check wrapper some machines
# define) rather than replacing it. The wrap-once guard uses an unexported
# variable so each new shell re-captures whatever `claude` is currently
# defined, instead of re-wrapping its own wrapper on a repeated `source
# ~/.zshrc`.
if [ -z "${_CCUSAGE_CLAUDE_WRAPPED:-}" ]; then
  (( $+functions[claude] )) && functions -c claude _ccusage_claude_orig
  _CCUSAGE_CLAUDE_WRAPPED=1
fi
claude() {
  local -a args
  if [ -n "${CLAUDE_PANEL_PIN_SID:-}" ]; then
    args=(--session-id "$CLAUDE_PANEL_PIN_SID")
    unset CLAUDE_PANEL_PIN_SID
  fi
  if (( $+functions[_ccusage_claude_orig] )); then
    _ccusage_claude_orig "${args[@]}" "$@"
  else
    command claude "${args[@]}" "$@"
  fi
}
_ccusage_panel_autolaunch() {
  case "$1" in
    claude*) ;;
    *) return ;;
  esac
  [ -n "${CCUSAGE_PANEL_LAUNCHED:-}" ] && return
  export CCUSAGE_PANEL_LAUNCHED=1

  local pin_sid=""
  case "$1" in
    *--session-id*|*--resume*|*--continue*|*' -r '*|*' -r'|*' -c '*|*' -c')
      ;;
    *)
      pin_sid=$(uuidgen | tr '[:upper:]' '[:lower:]')
      export CLAUDE_PANEL_PIN_SID="$pin_sid"
      ;;
  esac
  ~/.local/bin/claude-panel-launch.sh "$pin_sid" &
}
autoload -Uz add-zsh-hook
add-zsh-hook preexec _ccusage_panel_autolaunch
# --- end ccusage split-panel autolaunch ---
ZSHRC_EOF
fi

# If a `ghostty-claude-launcher` script exists (e.g. a Finder Service /
# Automator workflow that runs `open -na Ghostty.app --args -e
# ghostty-claude-launcher <folder>`), patch it too — that path execs
# `claude` directly with no interactive shell involved, so the preexec
# hook above never fires for it. Best-effort: inserts the launcher call
# immediately before the file's last line (its own launch line).
GCL="$BIN_DIR/ghostty-claude-launcher"
GCL_MARKER="# Auto-open the live ccusage stats panel"
if [ -f "$GCL" ] && grep -qF "$GCL_MARKER" "$GCL"; then
  echo "~/.local/bin/ghostty-claude-launcher already patched — leaving it as-is."
elif [ -f "$GCL" ]; then
  echo "Patching ~/.local/bin/ghostty-claude-launcher (Finder Service launch path) ..."
  tmp=$(mktemp)
  gcl_lines=$(wc -l < "$GCL")
  head -n "$((gcl_lines - 1))" "$GCL" > "$tmp"
  cat >> "$tmp" <<'GCL_EOF'

# Auto-open the live ccusage stats panel in a right-hand split. This
# window is always freshly created by the Finder Service (`open -na`), so
# there's no risk of double-launching — runs in the background so it
# doesn't delay Claude Code starting.
[ -x "$HOME/.local/bin/claude-panel-launch.sh" ] && "$HOME/.local/bin/claude-panel-launch.sh" &
GCL_EOF
  tail -n 1 "$GCL" >> "$tmp"
  mv "$tmp" "$GCL"
  chmod +x "$GCL"
else
  echo "No ~/.local/bin/ghostty-claude-launcher found — skipping (not using that Finder Service workflow)."
fi

# The launcher shrinks the new split to ~1/3 width via repeated
# ctrl+shift+l presses — needs these two resize_split keybinds in
# Ghostty's own config (idempotent: skip any already present).
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

echo "Installing claude-cost-alert-check.sh ..."
cat > "$BIN_DIR/claude-cost-alert-check.sh" <<'ALERT_EOF'
#!/usr/bin/env bash
# UserPromptSubmit hook. Alerts (via systemMessage, shown in the chat
# transcript itself, which works over Remote Control too since it's part
# of the session, not a local notification) when EITHER:
#   - this session's cost is RED or PURPLE vs the 7-day average session
#     cost (>2x / >3x, same thresholds as ccusage-panel.sh, so "red"
#     means the same thing here and in the panel), or
#   - the ccusage split-panel launcher's last attempt for this window
#     failed (see ~/.local/bin/claude-panel-launch.sh)
# Silent (no output) otherwise, in particular NOT on yellow, per request.
#
# Throttled per session so it fires once per tier increase and once per
# distinct launch failure, not on every single prompt: state is kept in
# ~/.cache/claude-cost-alert-state/<session_id>.json.
set -uo pipefail

STATE_DIR="$HOME/.cache/claude-cost-alert-state"
LAUNCH_LOG="$HOME/.cache/claude-panel-launch.log"
mkdir -p "$STATE_DIR"

YELLOW_MULT=1.5
RED_MULT=2.0
PURPLE_MULT=3.0
MIN_SESSION_ALERT=5.00  # never alert below this, no matter the multiple

# Claude Code passes this hook's own session_id on stdin as JSON (the
# UserPromptSubmit payload) — read that instead of guessing "most recently
# modified transcript file" via `ls -t ~/.claude/projects/*/*.jsonl`, which
# picks up whichever session anywhere on the machine last wrote a line and
# would alert on (or throttle-state-track) the WRONG session whenever a
# second Claude Code window is active.
hook_input=$(cat)
session_id=$(jq -r '.session_id // empty' <<<"$hook_input" 2>/dev/null)
[ -z "$session_id" ] && exit 0
state_file="$STATE_DIR/$session_id.json"

since7=$(date -v-7d +%Y%m%d 2>/dev/null || date -d '7 days ago' +%Y%m%d)
avg_session_cost=$(ccusage session --json --since "$since7" --offline 2>/dev/null | jq -r '
  [.session[].totalCost] | map(select(. > 0.05)) |
  if length >= 3 then (add/length) else 0 end
' 2>/dev/null)
[ -z "$avg_session_cost" ] && avg_session_cost="0"

session_cost=$(ccusage session --json -i "$session_id" --offline 2>/dev/null | jq -r '.totalCost // 0')
[ -z "$session_cost" ] && session_cost="0"

tier="normal"
if awk -v v="$session_cost" -v f="$MIN_SESSION_ALERT" 'BEGIN{exit !(v>=f)}'; then
  if awk -v a="$avg_session_cost" -v v="$session_cost" -v m="$PURPLE_MULT" 'BEGIN{exit !(a>0 && v>a*m)}'; then
    tier="purple"
  elif awk -v a="$avg_session_cost" -v v="$session_cost" -v m="$RED_MULT" 'BEGIN{exit !(a>0 && v>a*m)}'; then
    tier="red"
  elif awk -v a="$avg_session_cost" -v v="$session_cost" -v m="$YELLOW_MULT" 'BEGIN{exit !(a>0 && v>a*m)}'; then
    tier="yellow"
  fi
fi

last_launch_line=""
launch_failed=0
if [ -f "$LAUNCH_LOG" ]; then
  last_launch_line=$(grep "done:" "$LAUNCH_LOG" | tail -1)
  [[ "$last_launch_line" == *"GAVE UP"* ]] && launch_failed=1
fi

prev_tier="normal"
prev_launch_line=""
if [ -f "$state_file" ]; then
  prev_tier=$(jq -r '.tier // "normal"' "$state_file" 2>/dev/null)
  prev_launch_line=$(jq -r '.launch_line // ""' "$state_file" 2>/dev/null)
fi

severity() { case "$1" in normal) echo 0 ;; yellow) echo 1 ;; red) echo 2 ;; purple) echo 3 ;; *) echo 0 ;; esac; }

alert_cost=0
if { [ "$tier" = "red" ] || [ "$tier" = "purple" ]; } && [ "$(severity "$tier")" -gt "$(severity "$prev_tier")" ]; then
  alert_cost=1
fi

alert_launch=0
if [ "$launch_failed" -eq 1 ] && [ "$last_launch_line" != "$prev_launch_line" ]; then
  alert_launch=1
fi

# Persist state unconditionally (tracks de-escalation too, so a later
# re-escalation to the same tier alerts again).
python3 - "$state_file" "$tier" "$last_launch_line" <<'PYEOF'
import json, sys
path, tier, launch_line = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "w") as f:
    json.dump({"tier": tier, "launch_line": launch_line}, f)
PYEOF

if [ "$alert_cost" -eq 0 ] && [ "$alert_launch" -eq 0 ]; then
  exit 0
fi

python3 - "$alert_cost" "$alert_launch" "$tier" "$session_cost" "$avg_session_cost" <<'PYEOF'
import json, sys

alert_cost, alert_launch, tier, session_cost, avg_session_cost = sys.argv[1:6]
parts = []
if alert_launch == "1":
    parts.append("the usage panel failed to launch for this window (see ~/.cache/claude-panel-launch.log)")
if alert_cost == "1":
    parts.append(
        f"session cost is {tier.upper()} (${float(session_cost):.2f} vs a 7-day average of ${float(avg_session_cost):.2f})"
    )
msg = "warning: " + "; ".join(parts)
print(json.dumps({
    "systemMessage": msg,
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": msg,
    },
}))
PYEOF
ALERT_EOF
chmod +x "$BIN_DIR/claude-cost-alert-check.sh"

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
ALERT_CMD="~/.local/bin/claude-cost-alert-check.sh"
if [ -f "$CLAUDE_SETTINGS" ]; then
  if jq -e --arg cmd "$ALERT_CMD" '
      (.hooks.UserPromptSubmit // []) | any(.hooks[]?.command == $cmd)
    ' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
    echo "~/.claude/settings.json already has the cost-alert hook — leaving as-is."
  else
    tmp=$(mktemp)
    jq --arg cmd "$ALERT_CMD" '
      .hooks //= {} |
      .hooks.UserPromptSubmit //= [] |
      .hooks.UserPromptSubmit += [{"hooks": [{"type": "command", "command": $cmd, "timeout": 5}]}]
    ' "$CLAUDE_SETTINGS" > "$tmp" && mv "$tmp" "$CLAUDE_SETTINGS"
    echo "Added the cost-alert hook to ~/.claude/settings.json (UserPromptSubmit)."
  fi
else
  echo "No ~/.claude/settings.json found — skipping the cost-alert hook."
fi

echo
echo "Done. Open a NEW terminal window/tab (or 'source ~/.zshrc') and type"
echo "any 'claude...' command — it'll auto-split right and start the panel."
echo "Same goes for the 'Launch Claude Code in Ghostty' Finder Service, if"
echo "you use one (patched above when present)."
echo "Run the panel manually any time with: ~/.local/bin/ccusage-panel.sh"
if [ -x "$BIN_DIR/claude-panel-keyblock" ]; then
  echo
  echo "The first auto-split will prompt macOS for two more permissions, for"
  echo "claude-panel-keyblock this time — grant BOTH Accessibility and Input"
  echo "Monitoring (System Settings > Privacy & Security) or the keyboard"
  echo "guard silently no-ops and typing during window setup can interfere"
  echo "again, same as before it existed."
fi
