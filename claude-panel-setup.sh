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

# ---- two refresh tiers ----
# $REFRESH is the FAST tick: the "This Session" per-turn table only. That
# table is the one thing that has to track the conversation as it happens,
# and it is also the cheapest thing here — it reads one transcript file and
# is cached on that file's own mtime+size (turn_table_cached), so an idle
# pane re-renders it for free and a pane mid-turn pays exactly one parse per
# turn that lands.
#
# $SLOW_REFRESH is everything else: the summary block, Recent, and Top
# Sessions Today. Each of those is built from `ccusage` reports, and EVERY
# ccusage invocation reparses the whole (hundreds-of-MB) transcript corpus —
# ~3 CPU-seconds a scan. At the old single 10s tier that was ~4 full corpus
# scans every 10 seconds on a pane being actively typed into, because the
# corpus-change gate below (correctly) sees the corpus changing on every
# turn and refetches. That is the CPU heat; none of those figures — a 7/30
# day baseline, today's total, a 5h block average, the day's session
# ranking — moves meaningfully inside two minutes.
#
# Both rates are printed on the section headers they govern, so what the
# panel claims about itself stays true. (The label lying about the rate is
# a bug this panel has had before: it used to say "refresh 5s" while the
# numbers only moved every 10, since they shared one 10s cache.)
REFRESH="${1:-10}"
TURN_ROWS="${2:-12}"
SLOW_REFRESH="${SLOW_REFRESH:-120}"
# "10s", "2m", "1m30s" — used to label each section with its own rate.
fmt_interval() {
  local s="${1:-0}"
  if (( s < 60 )); then printf '%ds' "$s"
  elif (( s % 60 == 0 )); then printf '%dm' "$(( s / 60 ))"
  else printf '%dm%ds' "$(( s / 60 ))" "$(( s % 60 ))"; fi
}
# Computed once, printed on every section header. Each section states the
# rate it ACTUALLY redraws at, so a glance at the panel tells you how old the
# number under the heading can be. Nothing here should ever be a hardcoded
# string: the last time a label named a rate independently of the code that
# set it, the header claimed 5s while the figures moved every 10.
RATE_FAST="$(fmt_interval "$REFRESH")"
RATE_SLOW="$(fmt_interval "$SLOW_REFRESH")"
# Always appended at the END of a heading, never in the middle: header()
# wraps its whole argument in bold cyan, and this tag closes with a reset,
# so anything placed after it would lose the heading's own colour.
rate_tag() { printf '%s(refresh %s)%s' "$C_ELECTRIC" "$1" "$C_RESET"; }
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
# ---- clock seam ----
# Every wall-clock read in this file goes through these two, so a test can
# pin "now" with PANEL_FAKE_NOW (an epoch) and reach the boundaries that are
# otherwise only reachable by waiting: midnight rollover, and a 5h block
# ageing out. Both are places where the panel's answer depends on the CLOCK
# and not on the transcript corpus -- which is precisely what
# corpus_changed_since() cannot see, so they are the two boundaries most
# likely to break silently.
#
# BSD date takes a base time with -r. GNU date cannot be pinned the same
# way, so under a pinned clock the GNU branch REFUSES rather than quietly
# answering from the real clock: a test that believes it moved the clock and
# did not is worse than a test that cannot run at all.
panel_now() {
  if [ -n "${PANEL_FAKE_NOW:-}" ]; then printf '%s' "$PANEL_FAKE_NOW"; else date +%s; fi
}
panel_date() {
  if [ -z "${PANEL_FAKE_NOW:-}" ]; then date "$@"; return; fi
  case " $* " in
    *" -d "*)
      printf 'panel_date: PANEL_FAKE_NOW cannot pin GNU date -d\n' >&2
      return 64 ;;
  esac
  date -r "$PANEL_FAKE_NOW" "$@"
}

PANEL_START_EPOCH=$(panel_now)

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
C_CYAN=$'\033[36m'; C_YELLOW=$'\033[33m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'
# Electric blue (#7DF9FF), used only for the per-section "(refresh Ns)"
# tags. 24-bit rather than one of the 8 basic codes because every one of
# those is already carrying meaning in this panel — cyan is section
# headings, blue/green/yellow/red/magenta are all traffic-light states — and
# a rate tag is metadata about the panel, not a reading from it, so it
# should not collide with any of them. clear_eol()'s ANSI stripper matches
# \033[<digits and semicolons>m, which covers this form too, so width
# accounting is unaffected.
C_ELECTRIC=$'\033[38;2;125;249;255m'

fmt_num() {
  awk -v n="$1" 'BEGIN{
    n=n+0; neg=(n<0); if(neg) n=-n;
    n=int(n+0.5); s=sprintf("%d",n); out=""; l=length(s);
    for(i=1;i<=l;i++){ out=out substr(s,i,1); if((l-i)%3==0 && i!=l) out=out "," }
    print (neg?"-":"") out;
  }'
}
fmt_money() { printf '$%.2f' "${1:-0}"; }
fmt_m() { awk -v n="${1:-0}" 'BEGIN{ printf "%.2fM", n/1000000 }'; }
fmt_hm() { local m=${1:-0}; m=${m%.*}; printf '%dh %02dm' $((m/60)) $((m%60)); }

# Claude Burst (https://github.com/andrewbakercloudscale/claude-burst) is a
# personal, opt-in local proxy -- most people running this panel won't have
# it installed. Print nothing at all (not even a placeholder row) unless
# both the binary and its config are actually present, so the panel stays
# identical for everyone else.
proxy_state_line() {
  command -v claude-burst >/dev/null 2>&1 || return
  local cfg="$HOME/.config/claude-burst/config.json"
  [ -f "$cfg" ] || return
  local state="$HOME/.config/claude-burst/state.json"
  local primary secondary overflow_until now route_label route_color
  primary=$(jq -r '.primary.provider // "?"' "$cfg" 2>/dev/null)
  secondary=$(jq -r '.secondary.provider // "?"' "$cfg" 2>/dev/null)
  primary="${primary%-passthrough}"
  secondary="${secondary%-passthrough}"
  overflow_until=0
  [ -f "$state" ] && overflow_until=$(jq -r '.overflow_until // 0' "$state" 2>/dev/null)
  now=$(panel_now)
  if [ "${overflow_until:-0}" -gt "$now" ] 2>/dev/null; then
    route_label="SECONDARY ($secondary)"; route_color="$C_YELLOW"
  else
    route_label="PRIMARY ($primary)"; route_color="$C_GREEN"
  fi
  printf '  🔀 Proxy State: %s%s%s\n' "$route_color" "$route_label" "$C_RESET"
}

# There's no Anthropic API call for "what plan is this account on" — the
# closest thing is ~/.claude.json's oauthAccount block, which Claude Code
# itself populates from the account API at login and refreshes periodically
# (organizationType e.g. "claude_max", organizationRateLimitTier e.g.
# "default_claude_max_20x"). Absent entirely for API-key auth (no
# subscription to report), so silently print nothing rather than "Unknown".
# Cached on its own long TTL, not tied to CCUSAGE_CACHE_TTL — a plan
# practically never changes mid-session, so there's no reason to re-parse
# a multi-hundred-KB json file every 5-10s just to re-read the same string.
LICENSE_CACHE_TTL=300
license_line() {
  local acct_file="$HOME/.claude.json" label now mtime
  # $CCUSAGE_CACHE_DIR is defined later in the file (with the rest of the
  # ccusage cache machinery) -- computed here, not as a top-level global,
  # so this function is safe to define before that point under `set -u`.
  local LICENSE_CACHE="$CCUSAGE_CACHE_DIR/license.txt"
  now=$(panel_now)

  # Route-aware: claude-burst's secondary path hits a totally different
  # vendor (config's secondary.provider, e.g. "openai-compatible" against
  # Together/GLM) billed by its own API key — nothing to do with the
  # Anthropic Max/Pro seat below. Showing "Max (20x)" while traffic is
  # actually on secondary would be wrong, not just stale, so check the same
  # overflow state proxy_state_line() checks and short-circuit first.
  if command -v claude-burst >/dev/null 2>&1; then
    local cfg="$HOME/.config/claude-burst/config.json"
    if [ -f "$cfg" ]; then
      local state="$HOME/.config/claude-burst/state.json" overflow_until active_provider
      overflow_until=0
      [ -f "$state" ] && overflow_until=$(jq -r '.overflow_until // 0' "$state" 2>/dev/null)
      if [ "${overflow_until:-0}" -gt "$now" ] 2>/dev/null; then
        active_provider=$(jq -r '.secondary.provider // "?"' "$cfg" 2>/dev/null)
      else
        active_provider=$(jq -r '.primary.provider // "?"' "$cfg" 2>/dev/null)
      fi
      if [[ "$active_provider" != *oauth* ]]; then
        printf '  📜 License: %s%s%s\n' "$C_YELLOW" "API key (${active_provider%-passthrough})" "$C_RESET"
        return
      fi
    fi
  fi

  if [ -f "$LICENSE_CACHE" ]; then
    mtime=$(stat -f %m "$LICENSE_CACHE" 2>/dev/null || stat -c %Y "$LICENSE_CACHE" 2>/dev/null || echo 0)
    if (( now - mtime < LICENSE_CACHE_TTL )); then
      label=$(cat "$LICENSE_CACHE")
    fi
  fi
  if [ -z "${label:-}" ]; then
    [ -f "$acct_file" ] || return
    local org_type mult
    org_type=$(jq -r '.oauthAccount.organizationType // empty' "$acct_file" 2>/dev/null)
    if [ -z "$org_type" ]; then
      printf 'none' > "$LICENSE_CACHE.$$.tmp" && mv "$LICENSE_CACHE.$$.tmp" "$LICENSE_CACHE"
      return
    fi
    case "$org_type" in
      claude_max)        label="Max" ;;
      claude_pro)         label="Pro" ;;
      claude_team)        label="Team" ;;
      claude_enterprise)  label="Enterprise" ;;
      claude_free)        label="Free" ;;
      *) label="${org_type#claude_}" ;;
    esac
    mult=$(jq -r '.oauthAccount.organizationRateLimitTier // empty' "$acct_file" 2>/dev/null | grep -oE '[0-9]+x$')
    [ -n "$mult" ] && label="$label ($mult)"
    printf '%s' "$label" > "$LICENSE_CACHE.$$.tmp" && mv "$LICENSE_CACHE.$$.tmp" "$LICENSE_CACHE"
  fi
  [ "$label" = "none" ] && return
  printf '  📜 License: %s%s%s\n' "$C_CYAN" "$label" "$C_RESET"
}

# ---- traffic-light thresholds, shared by every colored figure in the panel ----
TIER_YELLOW_MULT=1.5
TIER_RED_MULT=2.0
BURN_YELLOW=3
BURN_RED=6
CTX_YELLOW=40
CTX_RED=60
CTX_PURPLE=80
# A value only gets colored once it clears an absolute floor — in a cheap
# session (avg $0.05) a $0.13 turn is >2x average and would false-positive
# red on money nobody would look twice at.
MIN_SESSION_ALERT=5.00
MIN_DAILY_ALERT=15.00
MIN_TREND_ALERT=2.00
MIN_DELTA_ALERT=1000

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
# model id -> green (cheapest tier, e.g. Haiku) / yellow (mid, e.g. Sonnet) /
# cyan (most expensive, e.g. Opus/Fable/Mythos) — mirrors the PRICES table in
# the per-turn-table python block below, but keyed on model-name substrings
# since this runs in bash, before that table's exact $/1M figures are in scope.
#
# The top tier is cyan and NOT red on purpose. Red everywhere else in this
# panel means "a threshold was crossed" — an over-average session, a burn
# rate past BURN_RED, a turn that spiked. The model is a deliberate choice
# that holds for the whole session, so colouring it red made the panel open
# on a standing alarm that never cleared and could not be acted on, which
# dulls the red that does mean something. Spend on an expensive model still
# shows up in red, on the Session/Today/Burn lines that actually measure it.
model_tier_color() {
  case "${1,,}" in
    *haiku*) printf '%s' "$C_GREEN" ;;
    *opus*|*fable*|*mythos*) printf '%s' "$C_CYAN" ;;
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
  now_epoch=$(panel_now)
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
    "claude-fable-5-1":  (10.00, 50.00),
    "claude-mythos-5":   (10.00, 50.00),
    "claude-mythos-5-1": (10.00, 50.00),
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
        # No nested breakdown means the write used the default 5-minute TTL
        # (the 1h breakdown only appears when the extended-cache beta was
        # actually used) — defaulting the whole cc_tok count to the 2x 1h
        # multiplier instead overstated cache-write cost ~60% on every such
        # entry.
        if cc:
            cw_1h = cc.get("ephemeral_1h_input_tokens", 0)
            cw_5m = cc.get("ephemeral_5m_input_tokens", 0)
        else:
            cw_1h = 0
            cw_5m = cc_tok

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

# ---- shared ccusage cache/lock, used by every `ccusage` call below ----
# Every open panel forked its OWN `ccusage` process for every one of ~13
# sequential calls per refresh, PLUS one more forked in parallel per session
# file on disk for "Top Sessions" -- with a few terminals open and a few
# dozen sessions, that's 100+ node processes spawned every 5s, several
# caught mid-fork pegged at 100%+ CPU. That's the battery drain. This wraps
# every call in a cache keyed by its exact arguments, shared across every
# panel via the filesystem, so at most one panel actually runs a given query
# per $CCUSAGE_CACHE_TTL -- everyone else (including this same panel on its
# next refresh) just reads the file. Same mkdir-lock pattern as
# refresh_hourly_buckets() above (atomic on POSIX, no flock dependency),
# generalized from one fixed python rebuild to arbitrary ccusage subcommands.
CCUSAGE_CACHE_DIR="$HOME/.cache/ccusage-panel-cache"
# Every ccusage-backed figure now lives on the slow tier, so the shared TTL
# tracks it -- but deliberately SHORTER than the tier, not equal to it.
#
# Equal was measured to be wrong. A slow tick at t=$SLOW_REFRESH finds an
# entry written at t=0 aged exactly $SLOW_REFRESH, and `age < TTL` is then a
# coin flip decided by a second's rounding: land on the TTL side and the tick
# serves the old entry WITHOUT consulting the corpus gate, so the section
# skips to the tick after -- an observed 240s effective refresh on a header
# advertising 120s. Which is the panel's oldest bug wearing a new hat.
#
# Three quarters of the tier means a slow tick always finds the TTL lapsed
# and always defers to corpus_changed_since(), which is the right arbiter:
# refetch iff the answer can actually have changed. The TTL's remaining job
# is only to stop N panels stampeding the same query at once.
TTL_LIVE=$(( SLOW_REFRESH * 3 / 4 ))
(( TTL_LIVE < 5 )) && TTL_LIVE=5

# The history bucket serves a stale answer even when the corpus HAS changed
# and the answer is known to be different. That is a real departure from the
# rule above -- "refetch iff the answer can have changed" -- and it is taken
# deliberately, for the one report where nothing anybody watches lives: the
# day's session RANKING and the 7-day session baselines. A ranking does not
# reorder inside a quarter of an hour, and an average over seven days moves
# by less than its own rounding. Measured on a 653MB corpus, `session` costs
# 0.71 CPU-s per fetch against 0.036 for an entire fast tick.
#
# 900 is 7.5 slow ticks, deliberately not a whole multiple: the same
# rounding coin-flip the comment above describes applies to every bucket,
# not just the one it was first found in.
TTL_HISTORY=$(( SLOW_REFRESH * 15 / 2 ))
(( TTL_HISTORY < TTL_LIVE )) && TTL_HISTORY=$TTL_LIVE
mkdir -p "$CCUSAGE_CACHE_DIR"

# ---- prune the per-session caches --------------------------------------
# Three of the caches below are keyed by SESSION, not by query, so they do
# not converge on a fixed set of files the way the `<key>.json` query cache
# does -- `turns-<key>.out`, `sessid-<key>.tsv` and `todaytok-<key>.tsv`
# gain one entry per session and never lose one. There are already 200+
# transcripts in ~/.claude/projects on this machine, and nothing ever
# removed the entries for the ones last touched months ago. Same shape as
# opencode-panel.sh's `export-*.json`, which is pruned; this side was
# flagged as a known gap when that one was written and is fixed here.
#
# `errors-<pid>.log` is the same problem with a faster clock: one per panel
# PROCESS. restore_tty removes it on a clean exit, but that trap is only
# installed when stdin is a tty, so a panel killed with SIGKILL, or run
# without a terminal, leaves its file behind for good.
#
# A cache entry is only rewritten on a MISS, so an entry being served from
# cache does not keep its own mtime fresh -- 7 days here means "no session
# whose transcript last moved a week ago", and deleting one costs exactly
# one refetch the next time that session is shown. A live panel's error log
# is truncated every slow tick (120s), so it can never approach the cutoff.
#
# Once per panel launch, not per tick: a `find` over a few hundred small
# files is cheap, but it is not free, and nothing here changes fast enough
# to need it more often.
find "$CCUSAGE_CACHE_DIR" -maxdepth 1 \
  \( -name 'turns-*.out' -o -name 'sessid-*.tsv' -o -name 'todaytok-*.tsv' \
     -o -name 'errors-*.log' -o -name '*.tmp' \) -mtime +7 -delete 2>/dev/null

# ---- why every temp file carries a pid -----------------------------------
# The write pattern throughout this file is `> "$f.tmp" && mv "$f.tmp" "$f"`,
# so the rename is atomic and a reader never sees half a file. The TEMP name
# was not per-process though, and three of these caches are keyed by session
# with no lock around them -- so two panels open on the same session both
# wrote `<file>.tmp`, one renamed it, and the other's `mv` failed on a path
# that no longer existed.
#
# That is not a silent loss: the builders' stderr is routed into
# PANEL_ERR_FILE, so it rendered as `! mv: ...tmp: No such file or
# directory` on the panel itself. Found by running the panel and reading it
# while a second one was open -- which is the only way it could have been
# found, since with one panel running there is nothing to race.
#
# `$$` makes the temp name unique per process; the rename stays atomic
# because it is still a rename within one directory. A panel killed between
# the write and the rename leaves its temp behind, which is what the `.tmp`
# glob in the prune above is for.

# ---- errors are rendered, never swallowed ------------------------------
# Everything in this panel is a number, and a number that failed to compute
# looks exactly like a number that computed to zero. Almost every call here
# ends in `2>/dev/null` -- correctly, because a chatty stderr would shred a
# 1/3-width pane -- so without somewhere for failures to go, a broken query,
# a jq that could not parse, or a builder that died on an unbound variable
# all render as $0.00 and nothing else.
#
# A FILE rather than a variable, because the section builders run inside
# $(...) subshells and a global set in there cannot be read back out. The
# loop truncates it once per slow tick, so what shows is what just failed
# rather than everything that ever has.
PANEL_ERR_FILE="$CCUSAGE_CACHE_DIR/errors-$$.log"
: > "$PANEL_ERR_FILE" 2>/dev/null
panel_error() { printf '%s\n' "$1" >> "$PANEL_ERR_FILE" 2>/dev/null; }
# The history bucket's own rate. Sections fed by it must advertise THIS, not
# the tick rate: the tick is how often they are redrawn, which is not how
# often the numbers in them can change. A header that names the redraw rate
# while the data underneath is a quarter of an hour old is the panel's
# oldest recurring bug, and it has always looked exactly this reasonable.
RATE_HISTORY="$(fmt_interval "$TTL_HISTORY")"

# Which bucket a query belongs in is decided by the QUERY, never by the call
# site, so two callers of the same report cannot disagree about how fresh it
# is. An unclassified query lands in the live bucket on purpose: a new query
# nobody has thought about must be wrongly EXPENSIVE, never wrongly stale.
#
# `daily` is deliberately NOT in the history bucket, despite being the
# obvious candidate: the same payload that carries the 7/30-day baselines
# also carries TODAY'S total, and today's total is one of the numbers this
# panel exists to watch climb. Deferring it 15 minutes would make it step
# rather than move, and only while turns are landing -- which is precisely
# when someone is looking at it. The baselines would happily be deferred;
# they just do not arrive on their own.
#
# So the freshness of Today is what actually costs here, and no arrangement
# of TTLs can change that: it is one corpus scan per tick or a stale number.
# Phase 2 (drop the statusline fetch) and Phase 3 (incremental rollup) are
# the levers on it; this one is not.
ccusage_ttl_for() {
  # Every query is `claude <subcommand> ...` now, so the subcommand is the
  # SECOND word. Keyed on the first, everything would read as "claude" and
  # land in the live bucket -- which is the safe direction, but silently,
  # and the history bucket would quietly stop existing.
  local q="$1"
  [ "$q" = "claude" ] && q="${2:-}"
  case "$q" in
    session|weekly|monthly) printf '%s' "$TTL_HISTORY" ;;
    *)                      printf '%s' "$TTL_LIVE" ;;
  esac
}

# Spread the expiries. Without this every entry is seeded when the panel
# starts and they all lapse on the same tick, for the life of the pane --
# one lurching frame and one CPU spike instead of several small ones, and
# synchronised across every open panel rather than merely within one.
#
# Derived from the cache key, NOT from $RANDOM or the pid: every panel on
# this machine must compute the SAME expiry for the same query, or N panels
# stagger into N separate fetches of one shared entry and the cross-panel
# cache stops being a cache. Deterministic per key is what makes it shared.
#
# Subtracted, never added, so the effective TTL is at most the advertised
# one. A label may under-promise freshness; it may never over-promise it.
ccusage_ttl_jittered() { # $1 = subcommand, $2 = cache key, $3 = 2nd word
  local ttl j
  ttl=$(ccusage_ttl_for "$1" "${3:-}")
  j=$(( 0x$(printf '%s' "$2" | cut -c1-2) % 15 ))
  printf '%s' $(( ttl - ttl * j / 100 ))
}

# ---- corpus-change gate ----
# The TTL above exists so that N panels (and the cost-alert hook) share ONE
# fetch per window instead of N -- that part is doing its job and stays at
# 10s. What it does NOT do is notice that the answer cannot have changed:
# with TTL == refresh, every redraw finds the entry just expired and pays a
# full re-scan, even on a pane nobody has typed into for an hour.
#
# But a ccusage report is a pure function of the transcript corpus. If no
# transcript has been written since a cache entry was produced, re-running
# the query cannot produce a different answer -- so the entry stays valid
# past its TTL. This checks that directly, and it is ~300x cheaper than the
# scan it avoids (0.01 CPU-seconds against 2.99 for a full refresh's
# queries), because `-print -quit` stops at the first newer path rather than
# walking the whole tree.
#
# Deliberately NOT restricted to *.jsonl: a file being added or removed
# updates its parent directory's mtime but not any file's, so filtering to
# transcripts alone would miss new sessions and archived ones. Matching
# every path under the tree is conservative -- it can only cause an
# unnecessary refetch, never a missed change.
#
# The cache file is never touched on a gate hit. Its mtime must keep meaning
# "the corpus state this content was computed from"; bumping it to now would
# move the comparison point forward past writes this check has not actually
# examined.
corpus_changed_since() {
  [ -n "$(find "$HOME/.claude/projects" -newer "$1" -print -quit 2>/dev/null)" ]
}

# `blocks --active` used to be exempted from this gate, because its
# projection counts down (remainingMinutes) and a gated entry would freeze
# the "Nh Nm left" readout on an idle pane -- so it paid a full corpus scan
# every tick forever, on the busiest and the idlest pane alike, purely to
# re-read a clock.
#
# It is gated now. The two fields that actually move with the wall clock are
# both derived from the block's OWN start/end timestamps, which do not
# change for the life of the block: the panel keeps startTime/endTime as
# epochs and recomputes "time left" and "elapsed hours" itself on every fast
# tick (see the loop). Everything genuinely fetched here -- the block's cost
# and token totals -- can only change when a turn is written, which is
# exactly what this gate tests. So nothing is exempt: every query is a pure
# function of the transcript corpus.
ccusage_query_is_gated() { :; }

# $1... = ccusage subcommand + args, e.g. `blocks --active --json --offline`.
# Prints the (possibly cached) JSON to stdout.
ccusage_cached() {
  local key cache_file lock_dir now_epoch cache_mtime lock_age waited out have_lock
  local ttl
  key=$(printf '%s' "$*" | shasum -a 256 | cut -c1-16)
  cache_file="$CCUSAGE_CACHE_DIR/$key.json"
  lock_dir="$cache_file.lock"
  now_epoch=$(panel_now)
  ttl=$(ccusage_ttl_jittered "$1" "$key" "${2:-}")

  if [ -f "$cache_file" ]; then
    cache_mtime=$(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)
    if (( now_epoch - cache_mtime < ttl )); then
      cat "$cache_file"
      return
    fi
    # TTL lapsed, but nothing this answer depends on has changed.
    if ccusage_query_is_gated "$1" && ! corpus_changed_since "$cache_file"; then
      cat "$cache_file"
      return
    fi
  fi

  have_lock=1
  if ! mkdir "$lock_dir" 2>/dev/null; then
    have_lock=0
    # A real ccusage call finishes in well under this -- a lock this old was
    # left behind by a panel that died mid-fetch. Reclaim it rather than
    # leaving every panel serving a permanently stale cache forever.
    lock_age=$(( now_epoch - $(stat -f %m "$lock_dir" 2>/dev/null || stat -c %Y "$lock_dir" 2>/dev/null || echo "$now_epoch") ))
    if (( lock_age > 30 )); then
      rmdir "$lock_dir" 2>/dev/null
      mkdir "$lock_dir" 2>/dev/null && have_lock=1
    fi
  fi

  if [ "$have_lock" = 0 ]; then
    # Another panel is already refetching this exact query -- serve the
    # stale-but-recent copy rather than block this panel's whole refresh on
    # someone else's in-flight fetch.
    if [ -f "$cache_file" ]; then
      cat "$cache_file"
      return
    fi
    # No cache at all yet for this key (its very first fetch, e.g. two
    # panels launched together) -- briefly wait for the winner instead of
    # rendering this row blank for a whole refresh cycle.
    waited=0
    while [ -d "$lock_dir" ] && [ ! -f "$cache_file" ] && (( waited < 10 )); do
      sleep 0.1
      waited=$(( waited + 1 ))
    done
    if [ -f "$cache_file" ]; then
      cat "$cache_file"
      return
    fi
    # Still nothing -- fetch it ourselves, unlocked, rather than wait
    # indefinitely; an occasional duplicate fetch beats a stuck panel.
  fi

  local err_tmp rc
  err_tmp="$cache_file.err"
  out=$(ccusage "$@" 2>"$err_tmp"); rc=$?
  # Empty counts as failure as much as a non-zero exit: every query here
  # returns a JSON object, and "" parses to nothing while looking like a
  # quiet day.
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    panel_error "ccusage $1 ${2:-} failed (exit $rc): $(tr -d '\n' < "$err_tmp" | cut -c1-80)"
    rm -f "$err_tmp"
    # Serve the last good answer if there is one, rather than replacing it
    # with the failure -- but the failure is on screen either way.
    [ -f "$cache_file" ] && cat "$cache_file"
    [ "$have_lock" = 1 ] && rmdir "$lock_dir" 2>/dev/null
    return 0
  fi
  rm -f "$err_tmp"
  printf '%s' "$out" > "$cache_file.$$.tmp" && mv "$cache_file.$$.tmp" "$cache_file"
  [ "$have_lock" = 1 ] && rmdir "$lock_dir" 2>/dev/null
  printf '%s' "$out"
}

# ---- one daily+weekly+monthly load instead of four separate ones ----
# `daily --last 1`, `weekly --last 1`, `monthly --last 1` and `daily --since
# <30d>` were four independent ccusage invocations per refresh, and since
# EVERY invocation reparses the whole transcript corpus (which reaches hundreds of MB) to
# answer, that was four full scans for four numbers. ccusage's own
# `--sections` flag emits all three reports from a single load, so ask for
# that once and pick the wanted period out of each: ~4x less CPU, and no
# reimplementation of ccusage's week/month boundary rules -- deriving these
# from a daily window by hand would have meant hardcoding "weeks start
# Monday", which is ccusage's business to define, not ours.
#
# Deliberately NO `--since` here. `--since` truncates the weekly and monthly
# ROWS as well as the daily ones -- with a mid-month `--since`,
# ccusage's own monthly row for that month reads only the tail of it, not
# the month's true total -- so
# passing the 30-day bound to save payload would have silently understated
# month-to-date on the 31st of any 31-day month, when the 29-day window no
# longer reaches the 1st. Full range costs the same scan (the scan is the
# cost, not the serialization) and cannot be wrong. spend30 is recovered by
# filtering the daily rows below, which matches `daily --since <30d>`
# exactly.
# `ccusage daily` means EVERY detected agent CLI -- Codex, OpenCode, Gemini,
# Copilot and the rest -- so a panel titled "Claude Code Usage" was reporting
# other agents' spend as its own. Measured simultaneously (generic run either
# side of the scoped one, both giving the identical figure): $6823.37
# all-agent against $6809.21 Claude-only, a real $14.16.
#
# The `claude` subcommand does not accept --sections, so the one combined
# load becomes three. That is affordable only because of where each lands:
# `daily` carries TODAY and stays in the live bucket at the same 1.01 CPU-s
# the combined call cost, while `weekly` and `monthly` move to the history
# bucket (0.73 + 0.72, 96 fetches a day instead of 720) for about +2.3
# CPU-min/day. Merged back into the shape every caller already reads, so
# nothing downstream knows the difference.
recent_sections_fetch() {
  local d w m
  d=$(ccusage_cached claude daily --json --offline)
  w=$(ccusage_cached claude weekly --json --offline)
  m=$(ccusage_cached claude monthly --json --offline)
  # The scoped reports do NOT use the unified report's key names -- the
  # period each row covers is `date`, `week` and `month` respectively, where
  # `--sections` called all three `period`. Nothing errors on the
  # difference: `select(.period == $t)` simply matches no row, and Today,
  # Folder and 30-Day Value all render a confident $0.00. Caught by running
  # the panel, not by the suite, which is why the smoke test is in the
  # rollout and not optional.
  #
  # Renamed here, in the one adapter, so every consumer downstream keeps
  # reading `.period` and none of them has to know which report it came from.
  jq -c -n --argjson d "${d:-null}" --argjson w "${w:-null}" --argjson m "${m:-null}" \
    '{ daily:   [ ($d.daily   // [])[] | .period = .date  ],
       weekly:  [ ($w.weekly  // [])[] | .period = .week  ],
       monthly: [ ($m.monthly // [])[] | .period = .month ] }' 2>/dev/null
}
# Fetched once per slow tick by the loop and read from here, so the three
# cache reads and the merge above happen once rather than once per caller.
RECENT_JSON=""
recent_sections() { printf '%s' "$RECENT_JSON"; }

# The full session report, fetched once and sliced locally. Every windowed
# `session --since/--until` variant the panel used to ask for (7-day
# baseline, previous 7-day baseline, today's sessions) is the SAME report
# with a date filter applied -- and since each ccusage invocation reparses
# the whole corpus, asking four times cost four full scans for four views of
# one dataset. Verified equivalent: a windowed `session --since` returns the same
# session set as filtering this payload does, and the computed averages
# match exactly.
# `claude session` returns its array under `.sessions`; the all-agent report
# used `.session`. Normalised here to the singular every caller already
# reads, rather than renaming it in each of them.
all_sessions() {
  # Same shape drift as the daily report above: the scoped session report
  # nests under `.sessions`, names the id `sessionId` rather than `period`,
  # and puts `lastActivity` at the top level instead of under `metadata`.
  ccusage_cached claude session --json --offline \
    | jq -c '{session: [ (.sessions // .session // [])[]
        | .period = (.sessionId // .period)
        | .metadata = ((.metadata // {}) + {lastActivity: (.lastActivity // .metadata.lastActivity)}) ]}' 2>/dev/null
}

# $1 = all_sessions payload, $2 = since (YYYY-MM-DD, day-inclusive),
# $3 = until (YYYY-MM-DD, day-EXCLUSIVE) or "" for no upper bound.
# Emits {session:[...]} so callers keep reading `.session[]` unchanged.
#
# The until bound is day-EXCLUSIVE because that is what ccusage does, which
# is NOT what it does for `daily --until` (inclusive there -- see
# daily_window below). Established by testing four windows whose end date
# actually had sessions on it: ccusage's own count matched day-exclusive
# filtering in every one, and never the day-inclusive count. Guessing
# symmetry here would have quietly shifted the previous-7-day baseline and
# with it the trend colours.
#
# lastActivity is a full ISO timestamp ("YYYY-MM-DDTHH:MM:SS.sssZ"), so the
# comparison is on its [0:10] date prefix -- a bare string compare against a
# plain "YYYY-MM-DD" bound would exclude every session ON that date by accident.
sessions_window() {
  jq -c --arg a "$2" --arg b "$3" '
    { session: [ .session[]?
        | select($a == "" or (.metadata.lastActivity[0:10]) >= $a)
        | select($b == "" or (.metadata.lastActivity[0:10]) <  $b) ] }
  ' <<<"$1" 2>/dev/null
}

# $1 = recent_sections payload, $2 = since (YYYY-MM-DD),
# $3 = until (YYYY-MM-DD, day-INCLUSIVE) or "" for no upper bound.
# Emits {daily:[...], totals:{totalCost}} -- the two shapes the daily-window
# callers read. Inclusive upper bound verified against a fixed
# historical window, which totals identically derived and direct.
daily_window() {
  jq -c --arg a "$2" --arg b "$3" '
    [ .daily[]? | select(.period >= $a) | select($b == "" or .period <= $b) ] as $rows |
    { daily: $rows, totals: { totalCost: ([ $rows[].totalCost ] | add // 0) } }
  ' <<<"$1" 2>/dev/null
}

# $1 = a recent_sections payload. Rebuilds the exact shape that
# `daily --json --last 1` returned -- {daily:[row], totals:{...}} -- so both
# downstream call sites keep working untouched (one reads .totals.totalCost,
# the other also reads .daily[0].modelBreakdowns).
#
# Selects TODAY's row BY DATE rather than taking the most recent row that
# exists. ccusage omits zero-usage days from the report entirely (real
# multi-day gaps do occur in practice), so `--last 1` on a
# morning before the first turn returned YESTERDAY's figures under a line
# labelled "today:". No row means no usage today, which is exactly what the
# callers' empty-`.daily` branch already prints.
today_daily_shape() {
  jq -c --arg t "$(panel_date +%Y-%m-%d)" '
    [ .daily[]? | select(.period == $t) ] as $rows |
    { daily: $rows,
      totals: ( ($rows[0] // {}) |
        { totalCost:           (.totalCost // 0),
          totalTokens:         (.totalTokens // 0),
          inputTokens:         (.inputTokens // 0),
          outputTokens:        (.outputTokens // 0),
          cacheCreationTokens: (.cacheCreationTokens // 0),
          cacheReadTokens:     (.cacheReadTokens // 0) } ) }
  ' <<<"$1" 2>/dev/null
}

# ---- transcript-scan cache, keyed by mtime+size not TTL ----
# Both python parses below read the WHOLE transcript file every refresh —
# fine for a small session, but for a multi-million-token one (see the
# 4.66M-token session that motivated this) that's a full multi-MB re-parse
# every 5-10s, per open panel, for as long as the pane stays open — most of
# it spent re-deriving a result that hasn't changed because nothing new was
# written since the last refresh (the common case: reading/typing between
# turns, not mid-generation). Unlike ccusage_cached()'s TTL, staleness here
# has an exact signal — the file's own mtime+size — so cache on THAT: a
# turn landing invalidates it immediately, and an idle pane pays for the
# parse exactly once until the next one lands, not every 5-10s regardless.
transcript_stamp() {
  local path="$1" m s
  m=$(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null || echo 0)
  s=$(stat -f %z "$path" 2>/dev/null || stat -c %s "$path" 2>/dev/null || echo 0)
  printf '%s:%s' "$m" "$s"
}

# $1 = session id, $2 = today's date (YYYY-MM-DD). Prints that session's
# token count for today.
#
# The underlying `ccusage session --json -i <sid>` parses EVERY transcript
# under ~/.claude/projects to answer -- the `-i` only filters the OUTPUT, it
# does not narrow the scan. So the unconditional fan-out that used to live at
# the "Top Sessions Today" block re-scanned the entire corpus once per
# active session, concurrently, every refresh: 8 sessions today meant 8 full
# scans every 10s, each pegging a core. That was the single largest CPU cost
# in this panel by a wide margin, and ccusage_cached() could not help --
# every sid is a DIFFERENT cache key, so the TTL and the mkdir-lock only
# dedupe a query against itself, never the eight against each other.
#
# A session's today-slice can only change when that session's own transcript
# is written to, which is an exact signal rather than a guess -- so key on
# mtime+size like session_identity_cached() above instead of a TTL. An idle
# session then pays nothing at all, and an ordinary tick rescans only the one
# session actually being typed into. $today is folded into the stamp so the
# slice invalidates by itself at midnight rather than serving yesterday's.
session_today_tokens_cached() {
  local sid="$1" today="$2" path key cache_file stamp cached out
  path=""
  for c in "$HOME"/.claude/projects/*/"$sid".jsonl; do
    [ -f "$c" ] && { path="$c"; break; }
  done
  [ -n "$path" ] || return
  key=$(printf '%s' "$sid" | shasum -a 256 | cut -c1-16)
  cache_file="$CCUSAGE_CACHE_DIR/todaytok-$key.tsv"
  stamp=$(transcript_stamp "$path")
  if [ -f "$cache_file" ]; then
    IFS=$'\t' read -r cached _ < "$cache_file"
    if [ "$cached" = "$stamp:$today" ]; then
      cut -f2- "$cache_file"
      return
    fi
  fi
  out=$(ccusage session --json -i "$sid" --offline 2>/dev/null | jq -r --arg d "$today" '
    [.entries[]? | select(.timestamp | startswith($d)) |
      .inputTokens+.outputTokens+.cacheCreationTokens+.cacheReadTokens] | add // 0
  ' 2>/dev/null)
  # Only a real answer gets cached -- caching "" on a failed/interrupted
  # fetch would pin the empty result until the next turn landed.
  [ -n "$out" ] || return
  printf '%s\t%s\n' "$stamp:$today" "$out" > "$cache_file.$$.tmp" && mv "$cache_file.$$.tmp" "$cache_file"
  printf '%s' "$out"
}

# $1 = transcript path. Prints the cached "sid\tmodel\tlabel\tfolder\tepoch"
# tsv line, calling the identity-scan python only when path+mtime+size
# changed since the last call (by any panel).
session_identity_cached() {
  local path="$1" key cache_file stamp cached
  key=$(printf '%s' "$path" | shasum -a 256 | cut -c1-16)
  cache_file="$CCUSAGE_CACHE_DIR/sessid-$key.tsv"
  stamp=$(transcript_stamp "$path")
  if [ -f "$cache_file" ]; then
    IFS=$'\t' read -r cached _ < "$cache_file"
    if [ "$cached" = "$stamp" ]; then
      cut -f2- "$cache_file"
      return
    fi
  fi
  local out
  out=$(python3 - "$path" <<'PYEOF'
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
  printf '%s\t%s\n' "$stamp" "$out" > "$cache_file.$$.tmp" && mv "$cache_file.$$.tmp" "$cache_file"
  printf '%s' "$out"
}

# $1 = transcript path, $2... = the same color/threshold args the table
# always took MINUS burn_color/burn_str -- those are a live every-refresh
# figure independent of this file's contents, so the caller prints that
# header line itself and only asks for the (cacheable) table body here.
# Same mtime+size cache as session_identity_cached() above, and for the
# same reason: this used to re-read and re-price the ENTIRE transcript on
# every single refresh, which for a multi-million-token session is real,
# repeated CPU for a result that's usually unchanged since the last frame.
turn_table_cached() {
  local path="$1"; shift
  local key cache_file stamp cached
  key=$(printf '%s' "$path $*" | shasum -a 256 | cut -c1-16)
  cache_file="$CCUSAGE_CACHE_DIR/turns-$key.out"
  stamp=$(transcript_stamp "$path")
  if [ -f "$cache_file" ]; then
    IFS=$'\t' read -r cached < "$cache_file"
    if [ "$cached" = "$stamp" ]; then
      tail -n +2 "$cache_file"
      return
    fi
  fi
  {
    printf '%s\n' "$stamp"
    python3 - "$path" "$@" <<'PYEOF'
import json, os, sys
from datetime import datetime

path, max_rows, c_head, c_reset = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
col_turn, col_model, col_input, col_cache, col_cost, col_mid_tier = sys.argv[5:11]
col_purple = sys.argv[11]
ctx_yellow_t, ctx_red_t, ctx_purple_t = (float(x) for x in sys.argv[12:15])
delta_yellow_mult, delta_red_mult, delta_floor = (float(x) for x in sys.argv[15:18])
# Appended last so every index above keeps its meaning. Used for the cells a
# secondary-served turn genuinely cannot fill in.
c_dim = sys.argv[18]

PRICES = {  # model id -> (input $/1M, output $/1M)
    "claude-sonnet-5":   (2.00, 10.00),
    "claude-opus-5":     (5.00, 25.00),
    "claude-haiku-4-5":  (1.00, 5.00),
    "claude-sonnet-4-6": (3.00, 15.00),
    "claude-opus-4-8":   (5.00, 25.00),
    "claude-opus-4-7":   (5.00, 25.00),
    "claude-opus-4-6":   (5.00, 25.00),
    "claude-fable-5":    (10.00, 50.00),
    "claude-fable-5-1":  (10.00, 50.00),
    "claude-mythos-5":   (10.00, 50.00),
    "claude-mythos-5-1": (10.00, 50.00),
}
DEFAULT_PRICE = (3.00, 15.00)
CACHE_READ_MULT, CACHE_WRITE_5M_MULT, CACHE_WRITE_1H_MULT = 0.1, 1.25, 2.0

def model_label(model_id):
    # A secondary-served id is not an Anthropic one and must not be forced
    # through the "claude-<name>-<major>-<minor>" shape below, which turns
    # "zai-org/GLM-5.3" into the nonsense "Zai org/GLM.5.3". Show the bare
    # model, dropping the vendor path segment: "zai-org/GLM-5.3" -> "GLM-5.3".
    if not model_id.startswith("claude-"):
        return model_id.rsplit("/", 1)[-1]
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

# The ONLY copy of this rule. It used to be mirrored in the bash panel and
# "kept in sync manually", with both computing a denominator for the same
# displayed percentage; the window now travels out of here in the metadata
# line instead, so the row colours below and the Context Usage line above
# cannot be divided by different numbers.
# Every current-generation model is 1M except Haiku 4.5 (200k) — see the
# bash version's comment for why this used to be a Sonnet-5/Fable-5-only
# allowlist and why that went stale.
def context_window_size(model_id):
    if model_id not in PRICES:
        return 0
    size = 200_000 if model_id == "claude-haiku-4-5" else 1_000_000
    if size == 1_000_000 and os.environ.get("CLAUDE_CODE_DISABLE_1M_CONTEXT", "0") == "1":
        size = 200_000
    return size

# Same green/yellow/red/purple bands as the "Context Usage" line above the
# table (CTX_YELLOW/RED/PURPLE), so a turn whose running total is already
# eating most of the window reads the same way here as it does up there.
def ctx_pct_color(pct):
    if pct > ctx_purple_t:
        return col_purple
    if pct > ctx_red_t:
        return col_cost
    if pct > ctx_yellow_t:
        return col_mid_tier
    return col_input

# RAG against this session's own average turn-over-turn growth (same
# baseline-ratio shape as tier_color() in bash: 1.5x avg -> yellow, 2x avg ->
# red) so a turn that blew up context relative to this session's own pattern
# stands out, rather than against an absolute token count that means
# something different in a 200k vs 1M window.
def delta_color(d, avg):
    if avg <= 0 or d < delta_floor:
        return col_input
    if d > avg * delta_red_mult:
        return col_cost
    if d > avg * delta_yellow_mult:
        return col_mid_tier
    return col_input

# Ranks the two independent per-cell colors above (context %, delta vs
# session average) onto one scale so a row can be colored as a whole by
# whichever signal is worse, instead of only the one cell that tripped it —
# a row that's fine on context but has an outsized delta (or vice versa)
# should still read as elevated at a glance, not just in one column.
def severity_rank(color):
    if color == col_purple:
        return 3
    if color == col_cost:
        return 2
    if color == col_mid_tier:
        return 1
    return 0

# --- which turns did claude-burst actually send to the secondary? ----------
#
# The transcript cannot answer this. When an overflow window is active the
# gateway translates the reply from an openai-compatible secondary back into
# Anthropic's wire shape and, deliberately (see ServeModeler's doc comment in
# claude-burst's internal/router/provider.go), echoes back the model Claude
# Code ASKED for rather than the one that served -- Claude Code must see the
# id it requested. So ~/.claude/projects/*.jsonl records "claude-opus-5" for
# a turn GLM actually answered, and this table priced it at Opus rates: a
# confident dollar figure for a request Anthropic never billed.
#
# The gateway's own metrics.jsonl has the truth (slot, real model, tokens),
# and its timestamps match the transcript's to within milliseconds because
# both are written at the end of the same response. Match on time, and
# require the output-token count to agree as well so a coincidental
# same-second primary turn can never be mislabelled.
BURST_METRICS = os.path.expanduser("~/.config/claude-burst/metrics.jsonl")
MATCH_WINDOW_S = 3.0

def parse_iso(t):
    if not t:
        return None
    try:
        # Python's fromisoformat rejects the trailing "Z" the transcript uses.
        return datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None

def load_secondary_events():
    """[(epoch, model, output_tokens)] for secondary-served requests."""
    out = []
    try:
        with open(BURST_METRICS) as f:
            for line in f:
                try:
                    e = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if e.get("slot") != "secondary":
                    continue
                ts = parse_iso(e.get("time"))
                if ts is None or not e.get("model"):
                    continue
                out.append((ts, e["model"], e.get("output_tokens"), e.get("input_tokens")))
    except OSError:
        return []
    return out

SECONDARY_EVENTS = load_secondary_events()

def secondary_event_for(turn_ts, out_tok):
    """(model, input_tokens) for the secondary hop that served this turn, or
    None if it went to primary."""
    if turn_ts is None:
        return None
    best, best_gap = None, MATCH_WINDOW_S
    for ts, model, ev_out, ev_in in SECONDARY_EVENTS:
        gap = abs(ts - turn_ts)
        if gap > best_gap:
            continue
        # Token agreement is what makes this safe rather than merely likely.
        if ev_out is not None and out_tok is not None and ev_out != out_tok:
            continue
        best, best_gap = (model, ev_in), gap
    return best

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
    turn_ts = parse_iso(d.get("timestamp"))
    in_tok = usage.get("input_tokens", 0)
    out_tok = usage.get("output_tokens", 0)
    cr_tok = usage.get("cache_read_input_tokens", 0)
    cc_tok = usage.get("cache_creation_input_tokens", 0)
    cc = usage.get("cache_creation") or {}
    # See the same fix in the hourly-bucket PYEOF block above: no nested
    # breakdown means the default 5-minute TTL was used, not the 1h beta.
    if cc:
        cw_1h = cc.get("ephemeral_1h_input_tokens", 0)
        cw_5m = cc.get("ephemeral_5m_input_tokens", 0)
    else:
        cw_1h = 0
        cw_5m = cc_tok

    total_ctx = in_tok + cr_tok + cc_tok
    cache_pct = (cr_tok / total_ctx * 100) if total_ctx else 0.0

    # Substitute the model that really served before pricing, not after: a
    # secondary model has no entry in PRICES, and falling back to
    # DEFAULT_PRICE would just swap one invented figure for another. Cost is
    # reported as unknown for these instead.
    ev = secondary_event_for(turn_ts, out_tok)
    is_secondary = ev is not None
    if is_secondary:
        model, ev_in = ev
        # Turns served before claude-burst's 2026-09-03 message_delta fix were
        # recorded with "input_tokens": 0 -- the translator sent only
        # output_tokens, so message_start's placeholder 0 stood. The gateway
        # logged the real count either way, so prefer its figure over a zero
        # the transcript never actually measured. Post-fix turns agree, and
        # this line is then a no-op.
        if not total_ctx and ev_in:
            in_tok, total_ctx = ev_in, ev_in

    is_estimated = model not in PRICES and not is_secondary
    price_in, price_out = PRICES.get(model, DEFAULT_PRICE)
    cost = (
        in_tok * price_in
        + out_tok * price_out
        + cr_tok * price_in * CACHE_READ_MULT
        + cw_1h * price_in * CACHE_WRITE_1H_MULT
        + cw_5m * price_in * CACHE_WRITE_5M_MULT
    ) / 1_000_000

    turns.append((model_label(model), total_ctx, cc_tok, cache_pct, cost, model, is_secondary, is_estimated))

total_n = len(turns)
shown = turns[-max_rows:]
# Averaged over primary turns only. A secondary turn reports no cache at all,
# so its whole prompt lands in the delta column; mixing those in inflates the
# baseline and suppresses the very spikes delta_color exists to flag.
primary_turns = [t for t in turns if not t[6]]
avg_delta = (sum(t[2] for t in primary_turns) / len(primary_turns)) if primary_turns else 0.0
# Machine-readable first line, stripped by the shell before the table
# reaches the screen. Both figures were computed above as a by-product of
# pricing the turns, and both were previously bought a SECOND time from
# `ccusage statusline` -- 2.11 CPU-s, the most expensive query this panel
# made, and the only one whose cache key carries a session id, so it could
# not be shared between panels and cost that much again for every extra
# Claude Code session running.
print(f"#META\t{sum(t[4] for t in turns):.6f}\t{turns[-1][1] if turns else 0}"
      f"\t{context_window_size(turns[-1][5]) if turns else 0}")
turn_h = f"{col_turn}{'Turn':<5}{c_reset}"
model_h = f"{col_model}{'Model':<10}{c_reset}"
input_h = f"{col_input}{'Input (Δ)':>12}{c_reset}"
cache_h = f"{col_cache}{'Cache':>6}{c_reset}"
cost_h = f"{col_cost}{'Cost':>8}{c_reset}"
print(f"  {turn_h}{model_h}{input_h}{cache_h}{cost_h}")
if shown:
    start_idx = total_n - len(shown) + 1
    # Newest turn first — this table sits at a fixed position above the
    # sections below it, so the most recent activity would otherwise be the
    # one row that scrolls out of view first as the session grows.
    saw_secondary = False
    for i in reversed(range(len(shown))):
        label, total_ctx, delta, cache_pct, cost, model, is_secondary, is_estimated = shown[i]
        turn_no = start_idx + i
        total_str, delta_str = fmt_k(total_ctx), fmt_k(delta)
        plain_cell = f"{total_str} (+{delta_str})"
        pad = " " * max(0, 12 - len(plain_cell))
        if is_secondary:
            # Marked in the one column that has room, and explained in a
            # legend below rather than by a wider Model column -- this pane
            # is a third of a terminal wide and every column is already at
            # its minimum.
            saw_secondary = True
            label = (label[:9] + "*") if len(label) > 9 else label + "*"
            # Everything downstream of here is an Anthropic-shaped inference
            # that does not survive the trip to a third-party model:
            #   - cost: no pricing entry, so there is no figure to show
            #   - cache: the secondary reports no prompt caching at all, so a
            #     0% here means "not applicable", not "cache missed" -- and
            #     the cache bands would paint it purple, an alarm for a
            #     condition that cannot occur
            #   - context %: the window size is unknown, so ctx_pct is noise
            print(f"  {col_purple}{turn_no:<5}{label:<10}{c_reset}"
                  f"{pad}{total_str} (+{delta_str})"
                  f"{c_dim}{'--':>6}{'?':>8}{c_reset}")
            continue
        win = context_window_size(model)
        # 0 means the model is not in PRICES, so its window is unknown --
        # see context_window_size. No denominator, no percentage; the row
        # still prices and still renders, under the footnote below.
        ctx_pct = (total_ctx / win * 100) if win else 0.0
        # Cache hit % is the odd one out: low is bad (unlike ctx_pct/delta,
        # where high is bad), so its bands run the opposite direction —
        # below 95% red, below 90% purple, 95%+ reads as normal.
        cache_c = col_purple if cache_pct < 90 else (col_cost if cache_pct < 95 else col_input)
        ctx_c, delta_c = ctx_pct_color(ctx_pct), delta_color(delta, avg_delta)
        # Whole-row coloring is keyed on delta alone, not context %. Delta
        # is a one-turn spike -- an actionable, out-of-pattern event worth
        # flagging everywhere at a glance. Context % is the opposite: once
        # a long session crosses its threshold it STAYS crossed for every
        # remaining turn (it only grows), so letting it drive whole-row
        # color painted the rest of a deep Opus/long session's table solid
        # red/purple turn after turn -- true, but no longer signal, just
        # noise. Context % keeps its own dedicated Input-cell tint below.
        rank = severity_rank(delta_c)
        cost_cell = "$" + format(cost, ".2f")
        if rank > 0:
            row_c = (col_input, col_mid_tier, col_cost, col_purple)[rank]
            print(f"  {row_c}{turn_no:<5}{label:<10}{pad}{total_str} (+{delta_str}){cache_pct:>5.0f}%{cost_cell:>8}{c_reset}")
        else:
            total_colored = f"{ctx_c}{total_str}{c_reset}"
            delta_colored = f"{delta_c}{delta_str}{c_reset}"
            input_cell = f"{pad}{total_colored} (+{delta_colored})"
            cache_cell = f"{cache_c}{cache_pct:>5.0f}%{c_reset}"
            print(f"  {turn_no:<5}{label:<10}{input_cell}{cache_cell}{cost_cell:>8}")
    if any(t[7] for t in turns):
        # Named, not hidden: a model absent from PRICES is priced at
        # DEFAULT_PRICE, and that figure is a stand-in rather than a rate.
        # Add the id above and this line goes away.
        unpriced = sorted({t[5] for t in turns if t[7]})
        print(f"  {c_dim}* estimated at default rates, model not in price "
              f"table: {', '.join(unpriced)}{c_reset}")
    if saw_secondary:
        print(f"  {c_dim}* served by claude-burst secondary; not Anthropic spend{c_reset}")
PYEOF
  } > "$cache_file.$$.tmp"
  if [ $? -eq 0 ] && [ -s "$cache_file.$$.tmp" ]; then
    mv "$cache_file.$$.tmp" "$cache_file"
    tail -n +2 "$cache_file"
  else
    rm -f "$cache_file.$$.tmp"
    printf '  %sturn table unavailable: transcript parse failed%s\n' "$C_RED" "$C_RESET"
  fi
}

# ---- this session's own figures, from the parse that already happened ---
# The turn table, this session's total cost and its current context size all
# fall out of one cached transcript parse. Read three times, computed once.
#
# This is what replaces `ccusage statusline`. That query supplied exactly two
# numbers the panel could not otherwise reach -- session cost and context
# tokens -- and a third, the model name, that it had already resolved and was
# passing INTO the query to get back out again. Today and the block figures
# were already computed independently and its versions of them ignored.
#
# Set on every FAST tick, before either builder runs, so the slow-tier
# summary and the fast-tier table read the same session from the same parse
# rather than two snapshots that can disagree on screen.
SESS_TABLE=""; SESS_COST=""; SESS_CTX=""; SESS_WIN=""
session_stats_refresh() {
  SESS_TABLE=""; SESS_COST=""; SESS_CTX=""; SESS_WIN=""
  [ -n "${latest:-}" ] || return 0
  local out meta
  out=$(turn_table_cached "$latest" "$TURN_ROWS" "$C_BOLD$C_CYAN" "$C_RESET" \
    "$C_CYAN" "$C_CYAN" "$C_GREEN" "$C_BLUE" "$C_RED" "$C_YELLOW" \
    "$C_MAGENTA" "$CTX_YELLOW" "$CTX_RED" "$CTX_PURPLE" \
    "$TIER_YELLOW_MULT" "$TIER_RED_MULT" "$MIN_DELTA_ALERT" "$C_DIM")
  meta=$(printf '%s\n' "$out" | head -1)
  case "$meta" in
    '#META'*)
      SESS_COST=$(printf '%s' "$meta" | cut -f2)
      SESS_CTX=$(printf '%s' "$meta" | cut -f3)
      SESS_WIN=$(printf '%s' "$meta" | cut -f4)
      SESS_TABLE=$(printf '%s\n' "$out" | tail -n +2)
      ;;
    *)
      # A cache entry written before this line existed -- the file is keyed
      # on the transcript's mtime+size, so it stays valid and stays served
      # until the next turn lands. Render the table, leave the figures
      # empty: an absent number shows as "--", where a wrong one would show
      # as money.
      SESS_TABLE="$out"
      ;;
  esac
}

# Save the real terminal fd BEFORE the loop ever redirects fd1 through a
# command-substitution pipe — fd3 keeps pointing at the actual pane device
# no matter what fd1 becomes inside a $(...), and unlike /dev/tty it still
# works for a process with no controlling terminal at all (e.g. one
# relaunched via `nohup ... &` with stdout pointed straight at a pty device
# file) as long as that fd itself is a real tty.
exec 3>&1

# ---- swallow stray keystrokes ----
# This pane is read-only — it never reads from stdin — but the tty
# underneath it still echoes and buffers whatever gets typed into it (focus
# briefly landing here mid-launch, or a keystroke sent while Ghostty is
# still splitting the window). Left alone, that typed text sits in the
# pty's input queue and lands straight on the shell prompt the moment this
# script exits — the stray characters/garbled prompt seen whenever the
# panel dies while someone was mid-keystroke in this pane. Turn off echo
# and canonical line-buffering, drain the queue on every tick, and restore
# the tty's original settings on exit no matter how the script ends, or the
# pane's shell is left echo-less afterward — a new bug in place of the old.
#
# The drain runs INLINE, in the main shell. It used to be a background loop,
#
#   ( while :; do read -r -t 0.2 -n 4096 _ 2>/dev/null; done ) &
#
# which did not work and was not cheap. POSIX says an asynchronous command
# in a shell without job control gets its stdin redirected to /dev/null, and
# a panel is `bash ccusage-panel.sh` — non-interactive, job control off. So
# that subshell was not reading the tty at all: it read instant EOF from
# /dev/null, `read` returned immediately, and the `-t 0.2` never once
# engaged. It spun a full core for the entire life of every panel — measured
# at 101 minutes of CPU across 103 minutes of wall clock, against 4 seconds
# for the panel process that owned it — while draining exactly nothing.
#
# `min 0 time 0` above makes tty reads non-blocking, so one call returns
# whatever is queued and the next returns failure on an empty queue: the
# loop drains and stops on its own. The iteration cap is only a guard
# against someone leaning on a key; the queue is drained again on exit,
# which is the moment that actually matters.
drain_stdin() {
  [ -n "${ORIG_STTY:-}" ] || return 0
  local i=0
  while (( i < 32 )) && read -r -t 0.01 -n 1024 _ 2>/dev/null; do
    i=$(( i + 1 ))
  done
  return 0
}
if [ -t 0 ]; then
  ORIG_STTY=$(stty -g 2>/dev/null || true)
  if [ -n "$ORIG_STTY" ]; then
    stty -echo -icanon min 0 time 0 2>/dev/null
    restore_tty() {
      rm -f "$PANEL_ERR_FILE"
      drain_stdin
      stty "$ORIG_STTY" 2>/dev/null
    }
    # INT/TERM need a handler that EXITS, not just one that tidies up. A
    # trap body that returns hands control straight back to the refresh
    # loop, so `kill <panel>` was survivable: the panel caught the signal,
    # restored the tty and carried on drawing -- now with echo back ON, so
    # the pane both kept redrawing AND echoed anything typed into it. Two
    # SIGTERMs to a pair of live panels left them running and confirmed it.
    # 130 is the conventional "terminated by SIGINT" status.
    on_signal() { restore_tty; exit 130; }
    trap restore_tty EXIT
    trap on_signal INT TERM
  fi
fi

# ---- slow-tier fetch: the active 5h block ----
# One `ccusage blocks --active` call, on the slow tier. Everything about a
# block that moves with the clock rather than with the corpus is derived
# from its start/end epochs by block_clock_tick() below, so this only needs
# to run when the corpus itself can have changed.
refresh_active_block() {
  refresh_hourly_buckets

  # ---- active 5h block: fetched once here (not down in the ACTIVE BLOCK
  # section) so the summary line above can show the same burn-rate-derived
  # color as the detailed section — one source of truth, one API call.
  block_json=$(ccusage_cached claude blocks --active --json --offline)
  has_block=$(jq -r '.blocks | length // 0' <<<"$block_json" 2>/dev/null)
  if [ "${has_block:-0}" = "1" ]; then
    # `localtime` before `strftime` is required — fromdateiso8601 hands back
    # a UTC broken-down time and strftime formats whatever it's given with
    # no zone conversion of its own, so without it these clock times render
    # in UTC while everything else in the panel (the header, "This Session"
    # times) is local — a 2h-off block window on any UTC+2 machine.
    # startTime/endTime come out as EPOCHS as well as clock strings. The
    # epochs are what let the fast tick recompute "elapsed" and "time left"
    # locally every 10s without refetching the block -- see
    # ccusage_query_is_gated() for why that matters (this query was the last
    # one paying a full corpus scan per tick just to advance a countdown).
    IFS=$'\t' read -r blk_start blk_end blk_start_epoch blk_end_epoch blk_cost blk_tokens blk_tpm blk_projCost blk_projTokens blk_models <<<"$(jq -r '
      .blocks[0] |
      [
        (.startTime[0:19]+"Z" | fromdateiso8601 | localtime | strftime("%H:%M")),
        (.endTime[0:19]+"Z"   | fromdateiso8601 | localtime | strftime("%H:%M")),
        (.startTime[0:19]+"Z" | fromdateiso8601),
        (.endTime[0:19]+"Z"   | fromdateiso8601),
        .costUSD, .totalTokens,
        .burnRate.tokensPerMinute,
        .projection.totalCost, .projection.totalTokens,
        (.models | join(", "))
      ] | @tsv
    ' <<<"$block_json")"
    has_block=1
  fi
}

# Recomputed on EVERY fast tick from the block's fixed start/end epochs, so
# the countdown and the burn rate keep moving between the (slow) fetches of
# the block itself. Nothing here reads the corpus: elapsed and remaining are
# pure wall-clock arithmetic, and blk_cost only changes when a turn lands.
#
# blk_cph is the block's TRUE average $/hr (cost ÷ elapsed time), not
# ccusage's own burnRate.costPerHour — that field is a seconds-scale
# instantaneous rate that spikes 10x+ right after any single pricey turn
# and decays within minutes (same failure mode already worked around for
# "Today's Predicted Value" above), so it disagreed wildly with the block's
# actual spend-so-far (e.g. reported $18.93/hr while the block had spent
# $0.81 in 44 minutes — a true rate of ~$1.11/hr). Floor elapsed at 3
# minutes for the same reason sess_elapsed_h does.
block_clock_tick() {
  [ "${has_block:-0}" = "1" ] || return
  local now_s
  now_s=$(panel_now)
  # A block that has ENDED is not an active block, and the cached
  # `blocks --active` payload cannot notice on its own: with no new turn the
  # corpus gate correctly holds that entry, nothing refetches, and the
  # section renders a countdown pinned at "0m left" for as long as the pane
  # stays open. The end epoch is already known here, so retire the block on
  # the CLOCK -- the same clock-vs-corpus split the seam at the top exists
  # for. Idempotent: a slow tick re-reads the held payload and sets
  # has_block=1 again, and this clears it again on the same tick, before
  # anything renders.
  if [ -n "${blk_end_epoch:-}" ] && (( now_s >= blk_end_epoch )); then
    has_block=0
    return
  fi
  IFS=$'\t' read -r blk_elapsed_h blk_cph blk_rem <<<"$(awk \
    -v now="$now_s" -v st="$blk_start_epoch" -v en="$blk_end_epoch" -v c="$blk_cost" 'BEGIN{
      h=(now-st)/3600; if(h<0.05) h=0.05
      rem=int((en-now)/60); if(rem<0) rem=0
      printf "%.6f\t%.2f\t%d", h, c/h, rem
    }')"
  burn_color=$(threshold_color "$blk_cph" "$BURN_YELLOW" "$BURN_RED")
  burn_label="Normal"
  [ "$burn_color" = "$C_YELLOW" ] && burn_label="Elevated"
  [ "$burn_color" = "$C_RED" ] && burn_label="High"
}

# ---- which transcript is this pane's session? ----
# Runs on every FAST tick: a session started in this pane after the panel
# has to appear in the turn table now, not on the next slow tier. It sets
# globals rather than printing, so it is deliberately NOT called in a
# subshell -- TOP SESSIONS TODAY needs $sess_id to mark which row is this
# one, and a command-substitution subshell can read variables from outside
# itself but never write them back out.
resolve_session() {
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
    # explicit pin.
    latest=""
    newest_birth=0
    # ONE `stat` for the whole directory, not one fork per transcript. This
    # runs on every fast tick (a session started in this pane has to show up
    # now, not on the next slow tier), and a long-lived project directory
    # routinely holds dozens of past transcripts -- that was dozens of forks
    # every $REFRESH seconds to answer what a single fork answers.
    #
    # `%B %N` puts the birth epoch first and the path last, so `read -r birth
    # f` gives f the rest of the line and paths containing spaces survive.
    # On any platform without `stat -f` (i.e. not macOS) this prints nothing
    # and $latest stays empty -- exactly what the per-file `|| continue`
    # produced before, and the single-transcript fallback below still applies.
    while read -r birth f; do
      [ -n "$f" ] || continue
      case "$birth" in ''|*[!0-9]*) continue;; esac
      if (( birth > PANEL_START_EPOCH && birth > newest_birth )); then
        newest_birth=$birth
        latest="$f"
      fi
    done < <(stat -f '%B %N' "$project_dir"/*.jsonl 2>/dev/null)
    # No post-launch file yet — e.g. a brand-new session whose first line
    # (or even --session-id pin) hasn't landed on disk. Only fall back to
    # "most recently modified in this directory" when that guess is
    # unambiguous (exactly one transcript here); with more than one it's a
    # coin flip which session is actively being chatted with, and guessing
    # wrong means showing someone else's live turns/cost as this pane's —
    # worse than the honest "no session found" this pane would otherwise
    # show for the few seconds until its own file exists. A long-lived
    # project directory can easily hold a dozen-plus past transcripts, so
    # "more than one file" is the common case here, not an edge case.
    if [ -z "$latest" ]; then
      other_jsonls=("$project_dir"/*.jsonl)
      if [ "${#other_jsonls[@]}" -eq 1 ] && [ -f "${other_jsonls[0]}" ]; then
        latest="${other_jsonls[0]}"
      fi
    fi
    # A "restarted mid-conversation" fallback (most-recently-modified
    # file within the last 30 minutes) used to sit here, on the theory
    # that the panel itself was (re)started mid-conversation rather than
    # launched fresh, so PANEL_START_EPOCH is newer than even the
    # transcript this pane has been chatting in all along. Reverted:
    # "only one transcript modified recently" is NOT the same claim as
    # "only one transcript modified recently in this exact pane" — a
    # second, already-open pane in the same project directory that's
    # mid-conversation makes that file the ONLY recent one project-wide
    # while this pane is a completely different, still-blank session
    # (nothing written yet, so it can't out-recency the other pane's
    # file no matter how the window is sized). That showed a live,
    # unrelated 47-turn/$3.99 session's data in a brand-new empty pane —
    # confidently wrong, which the guessing rule this whole function
    # exists to avoid explicitly calls worse than the honest "no active
    # session found" this now falls back to instead.
  fi
  if [ -n "$latest" ]; then
    IFS=$'\t' read -r sess_id model_id model_label folder_name sess_start_epoch < <(session_identity_cached "$latest")
    # Floor elapsed time at 3 minutes — a session-so-far rate computed over
    # the first few seconds swings wildly and would flash red/green noise.
    sess_elapsed_h=$(awk -v s="$sess_start_epoch" -v n="$(panel_now)" 'BEGIN{ h=(n-s)/3600; if(h<0.05) h=0.05; print h }')
  fi
}

# ---- slow-tier render: the summary block ----
# Every figure in here is built from a `ccusage` report, and every ccusage
# invocation reparses the whole transcript corpus. Nothing it shows -- a
# 7/30-day baseline, the day so far, a 5h block average, the plan line --
# moves meaningfully inside $SLOW_REFRESH, so it is rendered once per slow
# tick into a string and reprinted verbatim on the fast ticks between.
#
# The clock in the header is therefore the time this block was COMPUTED,
# which is the honest reading of it: it is the "as of" stamp for every
# number underneath, and it advances at exactly the rate the header claims.
build_summary() {
  printf '%sClaude Code Usage — %s %s\n' \
    "$C_BOLD$C_CYAN" "$(panel_date '+%a %H:%M:%S')" "$(rate_tag "$RATE_SLOW")"
  # ---- baselines: average per-session cost over 7 days, total spend over
  # 30 days. Session average needs >=3 real sessions to trust — otherwise a
  # single earlier tiny/huge session would skew it.
  since7=$(panel_date -v-7d +%Y%m%d 2>/dev/null || panel_date -d '7 days ago' +%Y%m%d)
  since7_iso=$(panel_date -v-7d +%Y-%m-%d 2>/dev/null || panel_date -d '7 days ago' +%Y-%m-%d)
  # Fetched ONCE for the whole frame. Three sections below are three views of
  # this one report -- the 7-day baseline, the previous 7 days it is compared
  # against, and this project's share of it -- and each used to call
  # all_sessions() for itself. On a cache hit that is still a re-read and a
  # re-parse of a 150KB payload (~0.01 CPU-s each, measured), and on a tick
  # where the TTL has lapsed it is additionally a `corpus_changed_since` walk
  # each.
  #
  # Coherence is the better reason. The three calls were three separate
  # command substitutions, so a TTL lapsing between two of them handed the
  # same frame two different payloads, and the trend arrow could be coloured
  # against a baseline the figure beside it was not computed from -- section
  # 6.1's drift, arriving through the cache rather than through a bucket.
  # One fetch, one frame, one set of numbers that agree.
  all_sess=$(all_sessions)
  baseline_json=$(sessions_window "$all_sess" "$since7_iso" "")
  avg_session_cost=$(jq -r '
    [.session[].totalCost] | map(select(. > 0.05)) |
    if length >= 3 then (add/length) else 0 end
  ' <<<"$baseline_json" 2>/dev/null)
  [ -z "$avg_session_cost" ] && avg_session_cost=0

  since30=$(panel_date -v-29d +%Y%m%d 2>/dev/null || panel_date -d '29 days ago' +%Y%m%d)
  since30_iso=$(panel_date -v-29d +%Y-%m-%d 2>/dev/null || panel_date -d '29 days ago' +%Y-%m-%d)
  recent_json=$(recent_sections)
  # Same 30-day window `daily --since "$since30"` covered; summing the rows
  # reproduces that call's .totals.totalCost exactly (verified).
  spend30=$(jq -r --arg d "$since30_iso" '[.daily[]? | select(.period >= $d) | .totalCost] | add // 0' <<<"$recent_json" 2>/dev/null)
  [ -z "$spend30" ] && spend30=0
  avg_daily_30=$(awk -v s="$spend30" 'BEGIN{ printf "%.4f", s/29 }')

  # ---- trend baselines: the SAME two windows one period earlier, so the
  # 7-day-avg and 30-day-spend lines can be traffic-lit against "am I
  # spending more than I was a week/month ago" rather than against
  # themselves (a baseline has nothing to compare to but its own past).
  prev7_since=$(panel_date -v-14d +%Y%m%d 2>/dev/null || panel_date -d '14 days ago' +%Y%m%d)
  prev7_until=$(panel_date -v-8d +%Y%m%d 2>/dev/null || panel_date -d '8 days ago' +%Y%m%d)
  prev7_since_iso=$(panel_date -v-14d +%Y-%m-%d 2>/dev/null || panel_date -d '14 days ago' +%Y-%m-%d)
  prev7_until_iso=$(panel_date -v-8d +%Y-%m-%d 2>/dev/null || panel_date -d '8 days ago' +%Y-%m-%d)
  prev7_avg=$(sessions_window "$all_sess" "$prev7_since_iso" "$prev7_until_iso" | jq -r '
    [.session[].totalCost] | map(select(. > 0.05)) |
    if length >= 3 then (add/length) else 0 end
  ' 2>/dev/null)
  [ -z "$prev7_avg" ] && prev7_avg=0

  prev30_since=$(panel_date -v-58d +%Y%m%d 2>/dev/null || panel_date -d '58 days ago' +%Y%m%d)
  prev30_until=$(panel_date -v-30d +%Y%m%d 2>/dev/null || panel_date -d '30 days ago' +%Y%m%d)
  prev30_since_iso=$(panel_date -v-58d +%Y-%m-%d 2>/dev/null || panel_date -d '58 days ago' +%Y-%m-%d)
  prev30_until_iso=$(panel_date -v-30d +%Y-%m-%d 2>/dev/null || panel_date -d '30 days ago' +%Y-%m-%d)
  prev_spend30=$(daily_window "$(recent_sections)" "$prev30_since_iso" "$prev30_until_iso" | jq -r '.totals.totalCost // 0')
  [ -z "$prev_spend30" ] && prev_spend30=0
  prev_avg_daily_30=$(awk -v s="$prev_spend30" 'BEGIN{ printf "%.4f", s/29 }')

  # ---- today's spend + EOD forecast: an account-wide total, so it renders
  # fine with no session resolved yet. Only the three fields below it —
  # Model, Session, Context Usage — genuinely need one, and all three now
  # come from this pane's own transcript parse rather than from a query.
  today_daily_json=$(today_daily_shape "$recent_json")
  today_amt="0.00"
  if [ -n "$today_daily_json" ] && [ "$(jq -r '.daily | length' <<<"$today_daily_json" 2>/dev/null)" != "0" ]; then
    today_amt=$(jq -r '.totals.totalCost // 0' <<<"$today_daily_json" | awk '{printf "%.2f", $1+0}')
  fi
  # today_amt (actual, already spent) + a forecast for the hours still
  # remaining today. Deliberately NOT a flat current-rate extrapolation
  # (blk_cph*10) — that rate is a seconds-scale figure that spikes 10x+
  # right after a single pricey turn and decays within minutes, which
  # made this line swing wildly (e.g. $350 -> $46 -> $22 across three 5s
  # refreshes with nothing unusual happening).
  #
  # The remaining-hours forecast itself is the persisted bucket cache's
  # historical average per hour-of-day, SCALED by how today's pace
  # compares to a typical day's pace so far — not used unscaled. An
  # unscaled historical average ignores today entirely: on a quiet day
  # (e.g. $17.93 spent by 14:48 against a ~$274 historical average for
  # hours 0-14) it forecast $215 for the day, back near the 30-day
  # average, regardless of how light today had actually been. pace_ratio
  # = today_amt ÷ the same buckets' historical average for hours 0..now;
  # ratio 1 (no scaling) when there's no historical baseline yet (cold
  # cache).
  current_hour=$(( 10#$(panel_date +%H) ))
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

  # ---- live status line (current session) ----
  # sess_id/model_id/model_label/folder_name/sess_start_epoch were already
  # resolved once, up top, before this subshell — needs the REAL
  # session_id and model.id: a placeholder session_id ("live") matches no
  # recorded session (session cost silently comes back $-0.00), and an
  # unset model.id makes ccusage assume an old 200k context window instead
  # of Sonnet 5's actual 1M, so context% reads >100%.
  #
  # Only Model, Session, and Context Usage below actually need that
  # resolved session — everything else in this block (Today, Current
  # Block, All Sessions, Folder, 30-Day Value, Proxy State) was always
  # independently computable, but used to be gated behind the SAME
  # session check as these three, so a brand-new pane with nothing typed
  # into it yet — the overwhelmingly common first few seconds of every
  # session — showed nothing at all except "no active session found"
  # instead of the account-wide context it could show all along.
  if [ -n "$latest" ]; then
    # Model: already resolved from the transcript by resolve_session(). It
    # used to be sent to ccusage inside the statusline payload and read back
    # out of the rendered string it came home in.
    mtc=$(model_tier_color "${model_id:-}")
    printf '  🤖 Model: %s%s%s\n' "$mtc" "${model_label:-Unknown}" "$C_RESET"

    if [ -n "$SESS_COST" ]; then
      sess_amt=$(awk -v c="$SESS_COST" 'BEGIN{ printf "%.2f", c }')
      sc=$(tier_color "$sess_amt" "$avg_session_cost" "$TIER_YELLOW_MULT" "$TIER_RED_MULT" "$MIN_SESSION_ALERT")
      # THIS session's own $/hr (spend so far ÷ time since its first
      # message) — separate from the block burn rate below, which is
      # every session's combined spend in the current 5h window, not
      # just this one. Shown on the same row as the spend it's derived
      # from rather than its own line.
      sess_rate=$(awk -v c="$sess_amt" -v h="$sess_elapsed_h" 'BEGIN{ printf "%.2f", c/h }')
      src=$(threshold_color "$sess_rate" "$BURN_YELLOW" "$BURN_RED")
      printf '  💰 Session: %s$%s%s, Burn %s$%s/hr%s\n' \
        "$sc" "$sess_amt" "$C_RESET" "$src" "$sess_rate" "$C_RESET"
    else
      # The parse produced no metadata line (a pre-existing cache entry, or
      # a session with no priced turns yet). Say so rather than print a
      # figure that would be indistinguishable from a real $0.00.
      printf '  💰 Session: --, Burn --\n'
    fi
  else
    printf '  🤖 Model: %sUnknown%s\n' "$C_DIM" "$C_RESET"
    printf '  💰 Session: $-0.00, Burn $0.00/hr\n'
  fi

  tc=$(tier_color "$today_amt" "$avg_daily_30" "$TIER_YELLOW_MULT" "$TIER_RED_MULT" "$MIN_DAILY_ALERT")
  pc=$(tier_color "$today_pred" "$avg_daily_30" "$TIER_YELLOW_MULT" "$TIER_RED_MULT" "$MIN_DAILY_ALERT")
  printf '  📅 Today: %s$%s%s (by EOD: %s$%s%s)\n' \
    "$tc" "$today_amt" "$C_RESET" "$pc" "$today_pred" "$C_RESET"

  if [ "${has_block:-0}" = "1" ]; then
    printf '  ⏳ Current Block: %s%s%s (%s left)\n' "$burn_color" "$(fmt_money "$blk_cost")" "$C_RESET" "$(fmt_hm "$blk_rem")"
    # This is the true average burn rate (blk_cost ÷ elapsed time) across
    # ALL sessions active in the current 5h block, not just this one —
    # ccusage's block cost total is already aggregated across every
    # concurrent session; see blk_cph derivation above for why it's
    # recomputed here instead of trusting ccusage's own
    # burnRate.costPerHour.
    printf '  🔥 All Sessions: %s%s/hr%s (%s)\n' \
      "$burn_color" "$(fmt_money "$blk_cph")" "$C_RESET" "$burn_label"
  else
    printf '  ⏳ Current Time Block: (no active block)\n'
  fi

  if [ -n "$latest" ]; then
    # A zero window means the parser did not recognise the model, so the
    # percentage has no denominator. Fall through to N/A rather than divide
    # by a number nobody knows -- a 0% reads as an empty context window.
    if [ -n "$SESS_CTX" ] && [ "$SESS_CTX" != "0" ] \
       && [ -n "$SESS_WIN" ] && [ "$SESS_WIN" != "0" ]; then
      # Context segment — recompute the window size and % ourselves rather
      # than trust ccusage's own %. ccusage assumes each model's native
      # window (1M for Sonnet 5) regardless of whether
      # CLAUDE_CODE_DISABLE_1M_CONTEXT forced the real active boundary
      # back to 200k, which is exactly the mismatch that made context
      # usage impossible to keep in check this week.
      ctx_tokens="$SESS_CTX"
      win_size="$SESS_WIN"
      ctx_pct=$(awk -v t="$ctx_tokens" -v w="$win_size" 'BEGIN{ printf "%.0f", (w>0? t*100/w:0) }')
      ctx_color=$(ctx_tier_color "$ctx_pct" "$CTX_YELLOW" "$CTX_RED" "$CTX_PURPLE")
      forced_note=""
      # Check the env var directly rather than re-deriving "was this model
      # actually forced down" from a hardcoded model-name list — that list
      # (originally just Sonnet 5/Fable 5) is exactly what went stale and
      # caused the 1M-window bug this comment now sits next to.
      if [ "$win_size" = "200000" ] && [ "$model_id" != "claude-haiku-4-5" ] && [ "${CLAUDE_CODE_DISABLE_1M_CONTEXT:-0}" = "1" ]; then
        forced_note=" [forced 200k]"
      fi
      printf '  🧠 Context Usage: %s%s / %s tokens (%s%%)%s%s\n' \
        "$ctx_color" "$(fmt_m "$ctx_tokens")" "$(fmt_m "$win_size")" "$ctx_pct" "$C_RESET" "$forced_note"
    else
      # No context figure from the parse -- a session whose first turn has
      # not landed yet, or an older cache entry. "N/A" is the honest answer;
      # a 0% would read as an empty context window.
      printf '  🧠 Context Usage: N/A\n' 
    fi
  else
    printf '  🧠 Context Usage: N/A\n'
  fi

  # Show just the project folder name — the transcript's own "cwd" field
  # when a session is resolved (not Claude Code's sanitized full-path
  # directory name, which can run well past a narrow 1/3-width split), or
  # $PWD's own basename otherwise, since this panel is always launched
  # into a same-cwd split either way.
  if [ -n "$latest" ]; then
    folder_disp="${folder_name:-unknown}"
  else
    folder_disp="$(basename "$PWD")"
  fi
  folder_maxw=$(( cols - 12 )); (( folder_maxw < 10 )) && folder_maxw=10
  if [ "${#folder_disp}" -gt "$folder_maxw" ]; then
    folder_disp="${folder_disp:0:$((folder_maxw - 3))}..."
  fi
  # Total spend attributed to THIS project — every session whose
  # transcript lives under $project_dir, summed via ccusage's own
  # per-session costs (not a token-repricing estimate) — shown next to
  # the folder name rather than the account-wide block projection that
  # used to sit here. $project_dir needs no resolved session either.
  proj_ids_json=$(ls "$project_dir"/*.jsonl 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.jsonl$//' | jq -R -s -c 'split("\n") | map(select(length>0))')
  proj_spend=$(printf '%s' "$all_sess" | jq -r --argjson ids "$proj_ids_json" '
    [.session[] | select(.period as $p | $ids | index($p) != null) | .totalCost] | add // 0
  ')
  printf '  📁 Folder: %s (%s)\n' "$folder_disp" "$(fmt_money "$proj_spend")"
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
  proxy_state_line
  license_line
}

# ---- fast-tier render: this session's per-turn table ----
# The one section that has to track the conversation as it happens, and the
# cheapest one here: it reads a single transcript file and is cached on that
# file's own mtime+size (turn_table_cached), so an idle pane re-renders it
# for free and an active one pays exactly one parse per turn that lands. No
# ccusage call, no corpus scan -- which is why it can afford to run at
# $REFRESH while everything else runs at $SLOW_REFRESH.
build_session_table() {
  # The blank separator line between the summary block and this one. It
  # lives at the top of this function rather than the bottom of
  # build_summary(), because $(...) strips trailing newlines -- a blank line
  # emitted as the last thing in the summary would simply not survive into
  # the cached string.
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
    # Printed here, not by the (cached) table below: burn rate is a live,
    # every-refresh figure independent of the transcript file, so it can't
    # be part of output that's only recomputed when that file changes.
    # The rate label goes LAST on this line deliberately: on a narrow pane
    # clear_eol() truncates from the right, so the label is what gets cut,
    # never the burn figure it annotates.
    printf '%sThis Session%s, Burn  %s%s/hr%s %s\n' \
      "$C_BOLD$C_CYAN" "$C_RESET" "${burn_color:-$C_RESET}" "$(fmt_money "${blk_cph:-0}")" "$C_RESET" \
      "$(rate_tag "$RATE_FAST")"
    printf '%s\n' "$SESS_TABLE"
  else
    header "This Session $(rate_tag "$RATE_FAST")"
    echo "  (no active Claude Code session found)"
  fi
}

# ---- slow-tier render: Recent + Top Sessions Today ----
# Same reasoning as build_summary(), plus the expensive bit: Top Sessions
# fans out one session_today_tokens_cached() per session active today. Each
# of those is a `ccusage session -i <sid>` whose -i filters only the OUTPUT
# -- the scan is the whole corpus either way -- and each sid is its own
# cache key, so the mtime cache dedupes a session against itself but never
# the eight against each other. On the old single tier a day with eight
# live sessions meant eight concurrent full corpus scans every 10 seconds.
#
# Emitted untruncated; the caller applies `head -n $remaining` at PRINT
# time, not here, because the height left over depends on how many rows the
# fast-tier turn table happens to have this tick.
# Is the slow-tier frame due to be rebuilt this tick?
#
# A function, not three lines inline, because the third condition is the only
# part of this panel's refresh behaviour that is neither a clock nor a resize
# -- and a decision that cannot be called from a test is a decision that gets
# asserted by grepping the source for a variable name, which proves nothing
# about what the loop does with it.
#
# The three reasons a frame is due:
#   1. SLOW_REFRESH has elapsed.
#   2. The pane was resized, so the whole frame must be re-laid out.
#   3. The session identity CHANGED.
#
# (3) exists because identity is resolved on every FAST tick but rendered by
# the header, which is slow tier -- so a model learned at 10s did not reach
# the screen for up to two minutes. Every new pane starts in exactly that
# state: the panel launches with the session's first line on disk but no
# ASSISTANT line yet, so the scan correctly reports "unknown", the first
# frame renders `Model: Unknown` / `Context Usage: N/A`, and it sits there
# while the fast-tier turn table two lines below already names the model on
# every row. One frame contradicting itself, for two minutes, on every
# session start.
#
# Identity is not on a cadence at all -- it changes when it changes, and
# noticing is free because resolve_session has already run this tick. So
# redraw on the change rather than waiting for the clock. This also catches a
# genuine mid-session model switch, which had the same two-minute lag for the
# same reason.
#
# Pure: it reads the "what did the last frame show" state but never writes
# it. Those are updated where the frame is actually rendered, next to
# last_slow and last_cols, so a tick that decides "due" and then does not
# render cannot mark the identity as already shown.
slow_frame_due() { # $1 = now epoch
  (( $1 - last_slow >= SLOW_REFRESH )) && return 0
  [ "$cols" != "$last_cols" ] && return 0
  [ "${model_label:-}" != "${last_model_label:-}" ] && return 0
  return 1
}

build_trailing() {
  echo
  echo

  # ---- recent: today's totals/models + 3-day trend + week/month, one
  # header. Was three separate headers (TODAY, LAST 3 DAYS, WEEK / MONTH)
  # with a bar chart eating 3 rows for 3 numbers — merged so this whole
  # block reliably fits above the fold instead of scrolling off a short
  # pane.
  header "Recent $(rate_tag "$RATE_SLOW")"
  # Same query as today_daily_json in build_summary() — that runs in its own
  # $(...) subshell, so its value doesn't survive into this one. Re-fetching
  # here goes through ccusage_cached(), and build_summary() and this function
  # are called back to back on the same slow tick, so the entry is always
  # well inside its TTL by the time this reads it: a cache read, never a
  # second ccusage fork.
  daily_json=$(today_daily_shape "$(recent_sections)")
  if [ -n "$daily_json" ] && [ "$(jq -r '.daily | length' <<<"$daily_json" 2>/dev/null)" != "0" ]; then
    IFS=$'\t' read -r tCost tTok tIn tOut tCacheC tCacheR <<<"$(jq -r '
      .totals | [.totalCost, .totalTokens, .inputTokens, .outputTokens, .cacheCreationTokens, .cacheReadTokens] | @tsv
    ' <<<"$daily_json")"
    printf '  %stoday:%s %s | %s tokens\n' "$C_CYAN" "$C_RESET" "$(fmt_money "$tCost")" "$(fmt_m "$tTok")"
    models_line=""
    while IFS=$'\t' read -r mname mcost; do
      [ -z "$mname" ] && continue
      seg="${C_CYAN}${mname#claude-}:${C_RESET} $(fmt_money "$mcost")"
      models_line="${models_line:+$models_line | }$seg"
    done < <(jq -r '.daily[0].modelBreakdowns[]? | [.modelName, .cost] | @tsv' <<<"$daily_json")
    printf '  %s\n' "$models_line"
  else
    echo "  (no usage yet today)"
  fi
  since3=$(panel_date -v-2d +%Y%m%d 2>/dev/null || panel_date -d '2 days ago' +%Y%m%d)
  since3_iso=$(panel_date -v-2d +%Y-%m-%d 2>/dev/null || panel_date -d '2 days ago' +%Y-%m-%d)
  trend_json=$(daily_window "$(recent_sections)" "$since3_iso" "")
  if [ -n "$trend_json" ]; then
    trend_line=""
    while IFS=$'\t' read -r day dcost dtok; do
      [ -z "$day" ] && continue
      seg="${C_CYAN}${day:5}:${C_RESET} $(fmt_money "$dcost")"
      trend_line="${trend_line:+$trend_line | }$seg"
    done < <(jq -r '.daily[] | [.period, .totalCost, .totalTokens] | @tsv' <<<"$trend_json")
    printf '  %s3d:%s %s\n' "$C_CYAN" "$C_RESET" "$trend_line"
  fi
  # Current period selected by computed key, not by taking the last row:
  # a week or month with no usage yet has no row at all, and [-1] would then
  # silently report the PREVIOUS one. Absent means $0, which is the truth.
  # Week keys are Mondays -- verified against five consecutive `ccusage
  # weekly` periods and against `weekly --last 1` for the current week.
  week_start=$(panel_date -v-$(( $(panel_date +%u) - 1 ))d +%Y-%m-%d 2>/dev/null || panel_date -d "$(( $(panel_date +%u) - 1 )) days ago" +%Y-%m-%d)
  recent_json=$(recent_sections)
  week_cost=$(jq -r --arg w "$week_start" '[.weekly[]? | select(.period == $w) | .totalCost][0] // 0' <<<"$recent_json" 2>/dev/null)
  [ -z "$week_cost" ] && week_cost=0
  month_cost=$(jq -r --arg m "$(panel_date +%Y-%m)" '[.monthly[]? | select(.period == $m) | .totalCost][0] // 0' <<<"$recent_json" 2>/dev/null)
  [ -z "$month_cost" ] && month_cost=0
  printf '  %sweek:%s %s | %smonth:%s %s\n' \
    "$C_CYAN" "$C_RESET" "$(fmt_money "$week_cost")" "$C_CYAN" "$C_RESET" "$(fmt_money "$month_cost")"
  echo

  # ---- top sessions today: which session is consuming the day's spend ----
  header "Top Sessions Today $(rate_tag "$RATE_HISTORY")"
  session_json=$(sessions_window "$(all_sessions)" "$(panel_date +%Y-%m-%d)" "")
  if [ -n "$session_json" ] && [ "$(jq -r '.session | length' <<<"$session_json" 2>/dev/null)" != "0" ]; then
    # ccusage's per-session totalCost/totalTokens are all-time-per-session,
    # not date-scoped — `--since` only decides which sessions get *listed*
    # (any with activity today), so a session spanning multiple days shows
    # its FULL history here, which can exceed the whole day's real total
    # (ccusage daily). Recompute today's slice from that session's own
    # deduped entry list (`-i <id>`, which matches ccusage's authoritative
    # totalTokens exactly — re-parsing the raw JSONL ourselves double-counts
    # branches/retries). Entry-level costUSD is 0 for this account (ccusage
    # prices from its model-rate table, not per-entry), so today's cost is
    # estimated as a share of the session's all-time cost proportional to
    # its token share.
    today_str=$(panel_date +%Y-%m-%d)
    tmpdir=$(mktemp -d)
    # Wait on the pids we actually spawned, never a bare `wait`. This runs
    # inside a $(...) command substitution, and such a subshell inherits the
    # PARENT's job table without those jobs being its children -- so a bare
    # `wait` here reaches the panel's own stdin-drain background loop, prints
    # "pid N is not a child of this shell", and never retires the entry: it
    # spins, emitting that line forever. (It was survivable only while this
    # block sat inside a `| head -n` pipeline, which resets the job table.)
    fanout_pids=""
    while IFS=$'\t' read -r sid _ _ _; do
      [ -z "$sid" ] && continue
      ( session_today_tokens_cached "$sid" "$today_str" > "$tmpdir/$sid.tok" ) &
      fanout_pids="$fanout_pids $!"
    done < <(jq -r '.session[] | [.period, .totalCost, .totalTokens, .metadata.lastActivity] | @tsv' <<<"$session_json")
    for fp in $fanout_pids; do wait "$fp" 2>/dev/null; done

    top_rows=$(while IFS=$'\t' read -r sid all_cost all_tok slast; do
      [ -z "$sid" ] && continue
      ef="$tmpdir/$sid.tok"
      today_tok=""
      [ -s "$ef" ] && today_tok=$(cat "$ef")
      # Falling back to the session's ALL-TIME total is deliberate and
      # unchanged: better to overstate a multi-day session's today-slice
      # than to silently drop it out of the ranking entirely.
      [ -z "$today_tok" ] && today_tok="$all_tok"
      today_cost=$(awk -v c="$all_cost" -v tt="$today_tok" -v at="$all_tok" 'BEGIN{ printf "%.10f", (at>0 ? c*tt/at : 0) }')
      printf '%s\t%s\t%s\t%s\n' "$sid" "$today_cost" "$today_tok" "$slast"
    done < <(jq -r '.session[] | [.period, .totalCost, .totalTokens, .metadata.lastActivity] | @tsv' <<<"$session_json"))
    rm -rf "$tmpdir"

    while IFS=$'\t' read -r sid scost stok slast; do
      [ -z "$sid" ] && continue
      # localtime before strftime — see the same fix on the active-block
      # start/end times above; without it this reads ~2h behind on UTC+2.
      lasthm=$(jq -rn --arg t "$slast" '($t[0:19]+"Z") | fromdateiso8601 | localtime | strftime("%H:%M")' 2>/dev/null)
      row=$(printf '%-10s %8s  %s tokens  last %s' "${sid:0:10}" "$(fmt_money "$scost")" "$(fmt_m "$stok")" "$lasthm")
      if [ "$sid" = "${sess_id:-}" ]; then
        printf '  %s%s *this%s\n' "$C_BOLD" "$row" "$C_RESET"
      else
        printf '  %s\n' "$row"
      fi
    done < <(printf '%s\n' "$top_rows" | sort -t $'\t' -k2,2 -rn | head -5)
  else
    echo "  (none)"
  fi
}

# Slow-tier render cache: the last string each slow section produced, plus
# when it was produced. A pane width change forces a rebuild too -- the
# summary truncates the folder name against $cols, so a resized pane would
# otherwise keep a stale-width line up for as long as $SLOW_REFRESH.
last_slow=0
last_cols=0
summary_block=""
trailing_raw=""

# Test seam: source this file with PANEL_LIB_ONLY=1 to get every function
# above without entering the render loop. The tty setup further up is
# already guarded by `[ -t 0 ]`, so a sourced panel touches no terminal and
# installs no traps.
if [ -n "${PANEL_LIB_ONLY:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

last_frame=""

while true; do
  # Cursor-home only, NOT a full \033[2J clear — a full clear blanks the
  # whole pane for one frame before the redraw lands, which reads as a
  # visible flicker every refresh. Staying purely additive-overwrite only
  # works because clear_eol() (above) truncates every line to $COLS, so a
  # frame's physical row count can never silently exceed $rows and desync
  # this cursor-home overwrite against the previous frame.
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

  # Discard anything typed into this read-only pane since the last tick, so
  # it cannot land on the shell prompt when the panel exits.
  drain_stdin

  now_epoch=$(panel_now)
  resolve_session
  # Before either builder: the slow-tier summary and the fast-tier table
  # must read the same session from the same parse, or they can disagree
  # on screen about what this session has cost.
  session_stats_refresh

  slow_due=0
  slow_frame_due "$now_epoch" && slow_due=1

  # One fetch+merge per slow tick, read by every section below it. The error
  # file is cleared first so the panel reports this tick's failures rather
  # than accumulating every failure since the pane opened.
  (( slow_due )) && : > "$PANEL_ERR_FILE"
  (( slow_due )) && RECENT_JSON=$(recent_sections_fetch 2>>"$PANEL_ERR_FILE")
  (( slow_due )) && refresh_active_block
  # Always: re-derives the countdown and the $/hr denominator from the
  # block's fixed epochs. Pure arithmetic, no fetch.
  block_clock_tick

  if (( slow_due )); then
    # Any stderr from a builder -- an unbound variable, a jq parse error, a
    # python traceback -- is a crash that would otherwise show as a
    # truncated block and nothing else. This is the general catch: it does
    # not need to know what broke to report that something did.
    summary_block=$(build_summary 2>>"$PANEL_ERR_FILE")
    trailing_raw=$(build_trailing 2>>"$PANEL_ERR_FILE")
    last_slow=$now_epoch
    last_cols=$cols
    last_model_label="${model_label:-}"
  fi

  # Everything through the per-turn table is GUARANTEED — printed in full,
  # never truncated, even on a short pane — so "show N turns" always means
  # N turns, not "N turns if there's room after the other sections." Only
  # the sections below it compete for whatever pane height is left over.
  # At most three lines, so a burst of failures cannot push the turn table
  # off a short pane -- but say how many there are, or three of eight reads
  # as all of them.
  errs=""
  if [ -s "$PANEL_ERR_FILE" ]; then
    err_n=$(sort -u "$PANEL_ERR_FILE" | wc -l | tr -d ' ')
    errs=$(sort -u "$PANEL_ERR_FILE" | head -3 | while IFS= read -r e; do
      printf '  %s! %s%s\n' "$C_RED" "${e:0:$(( cols > 8 ? cols - 5 : 40 ))}" "$C_RESET"
    done)
    if (( err_n > 3 )); then
      errs="$errs"$'\n'"$(printf '  %s! and %d more failure(s)%s' "$C_RED" "$(( err_n - 3 ))" "$C_RESET")"
    fi
  fi
  guaranteed="$summary_block"${errs:+$'\n'"$errs"}$'\n'"$(build_session_table 2>>"$PANEL_ERR_FILE")"
  used_lines=$(printf '%s\n' "$guaranteed" | wc -l | tr -d ' ')
  remaining=$(( rows - 1 - used_lines ))

  # Both blocks are written to the terminal once, together, below —
  # previously the guaranteed block was printed immediately and the trailing
  # Recent/Top Sessions block followed seconds later (once its several
  # sequential `ccusage ...` calls finished), so every refresh visibly
  # redrew in two separate passes. A slow trailing fetch delays the whole
  # frame instead of half-updating it: the previous frame just stays up a
  # little longer, which reads as a pause, not a tear.
  trailing=""
  if (( remaining > 0 )) && [ -n "$trailing_raw" ]; then
    trailing=$(printf '%s\n' "$trailing_raw" | head -n "$remaining")
  fi

  # Write only when the frame actually differs from the one already on
  # screen. On a pane between slow ticks nothing in it can have moved unless
  # a turn landed: the summary block and the trailing sections are rebuilt on
  # the slow tier, and the header's clock string is rebuilt with them, so
  # eleven of every twelve fast ticks compose a frame identical to the last.
  #
  # The saving is not mostly ours. Every write is a repaint in the terminal
  # emulator too, and that cost is charged to Ghostty, once per open panel --
  # so it is the part that scales with the number of Claude Code sessions
  # running, which is the whole reason this pane is cheap to leave open.
  #
  # No separate periodic repaint is needed: a slow tick rebuilds the header
  # with a new clock string, so the frame always differs at least once every
  # $SLOW_REFRESH and the pane cannot sit stale after an external scribble.
  frame="$guaranteed"$'\n'"$trailing"
  if [ "$frame" != "$last_frame" ]; then
    printf '\033[H'
    printf '%s\n' "$guaranteed" | clear_eol
    [ -n "$trailing" ] && printf '%s\n' "$trailing" | clear_eol
    printf '\033[0J'
    last_frame="$frame"
  fi

  # Backgrounded and waited on, not a plain `sleep`. Bash defers every trap
  # until the current FOREGROUND child returns, so with a bare `sleep
  # $REFRESH` a Ctrl-C or a `kill` sat unanswered for up to a full tier --
  # measured at 9.06s on the 10s default. `wait` is interruptible, so the
  # handler runs the moment the signal lands. The orphaned sleep exits on
  # its own a few seconds later and costs nothing.
  sleep "$REFRESH" &
  wait $! 2>/dev/null
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
[ -n "$PIN_SID" ] && PANEL_CMD="~/.local/bin/ccusage-panel.sh 10 12 $PIN_SID"

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

# WHICH Ghostty instance is ours? Not a rhetorical question: every Finder
# Service launch runs `Ghostty.app/Contents/MacOS/ghostty -e ...` directly,
# which starts a new app INSTANCE rather than a new window inside the
# existing one, so several processes named "ghostty" coexist as a matter of
# routine — one per launched window, plus any whose window was closed while
# a child shell kept the process alive.
#
# Everything below used to identify its target as "the frontmost process
# named ghostty", which is only unambiguous while exactly one instance
# exists. It stopped being true on 2026-09-05: macOS reported a two-day-old
# instance as frontmost, that instance had no windows left, and all three
# attempts died on `Can't get window 1 of application process "ghostty".
# Invalid index. (-1719)` while the real window sat there in focus.
#
# Our own instance is always an ancestor of this script (ghostty -> login ->
# shell -> here), so walk up and get its pid. Everything downstream then
# addresses it by unix id instead of by name. If the walk fails we fall back
# to the old name match rather than refusing to launch, but the log says so.
ghostty_pid=""
walk=$$
depth=0
while [ -n "$walk" ] && [ "$walk" -gt 1 ] && [ "$depth" -lt 12 ]; do
  if [ "$(ps -o comm= -p "$walk" 2>/dev/null | sed 's|.*/||')" = "ghostty" ]; then
    ghostty_pid="$walk"
    break
  fi
  walk=$(ps -o ppid= -p "$walk" 2>/dev/null | tr -d ' ')
  depth=$((depth + 1))
done
if [ -n "$ghostty_pid" ]; then
  log "context: our Ghostty instance is pid $ghostty_pid (walked $depth level(s) of process ancestry)"
else
  log "context: could not identify our Ghostty instance from process ancestry — falling back to matching on the name 'ghostty', which is ambiguous when several instances are running"
fi

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

  # Ask our own instance to come to the front before polling. This isn't
  # cosmetic: System Events delivers `keystroke` to whatever application is
  # frontmost, not to the process an enclosing `tell` names, so targeting
  # the right instance and typing into the right window are one and the
  # same requirement — a check that merely observes frontmost can be
  # satisfied by an instance we are not about to type into.
  if [ -n "$ghostty_pid" ]; then
    osascript -e "tell application \"System Events\" to set frontmost of (first application process whose unix id is $ghostty_pid) to true" >/dev/null 2>&1
  fi

  # Brand-new windows can take a beat to become frontmost at the
  # Accessibility API level — poll instead of checking once and giving up.
  front=""
  polls=0
  for _ in $(seq 1 20); do
    polls=$((polls + 1))
    if [ -n "$ghostty_pid" ]; then
      front=$(osascript -e 'tell application "System Events" to get unix id of first application process whose frontmost is true' 2>/dev/null)
      [ "$front" = "$ghostty_pid" ] && break
    else
      front=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null)
      [ "$front" = "ghostty" ] && break
    fi
    sleep 0.1
  done
  if [ -n "$ghostty_pid" ] && [ "$front" != "$ghostty_pid" ]; then
    log "attempt $attempt: our Ghostty instance (pid $ghostty_pid) never became frontmost after $polls polls (last saw pid '$front') — retrying"
    sleep 0.5
    continue
  fi
  if [ -z "$ghostty_pid" ] && [ "$front" != "ghostty" ]; then
    log "attempt $attempt: frontmost never became ghostty after $polls polls (last saw '$front') — retrying"
    sleep 0.5
    continue
  fi
  log "attempt $attempt: frontmost confirmed ($([ -n "$ghostty_pid" ] && echo "pid $ghostty_pid" || echo "name match")) after $polls poll(s)"

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
  # 0 means "we never worked out which instance is ours" — the AppleScript
  # then falls back to the old, ambiguous name match.
  TARGET_PID="${ghostty_pid:-0}"

  result=$(osascript <<APPLESCRIPT 2>&1
tell application "System Events"
  -- Identify the focused instance POSITIVELY, and refuse to type if we
  -- cannot.
  --
  -- `first application process whose frontmost is true` returns whichever
  -- match comes first in System Events' own process order. That is fine
  -- with one Ghostty and wrong with several: on 2026-09-05 the shell-side
  -- poll logged "frontmost confirmed (pid 37092)" and this script, asking
  -- the identical question a second later, read pid 87107 -- an OLDER
  -- instance -- and skipped, on all three attempts, for every new window
  -- opened while a second Ghostty was alive.
  --
  -- So enumerate every ghostty and ask each one directly, rather than
  -- asking the list who is first. Proceed only when EXACTLY ONE claims
  -- frontmost and it is ours. Anything else skips.
  --
  -- Skipping is the right failure. The alternative -- assume it is ours and
  -- type anyway -- was tried and is far worse: `keystroke` goes to whatever
  -- window holds keyboard focus system-wide, NOT to the process an
  -- enclosing `tell` names (see the comment on the raise above), so a wrong
  -- guess types a shell command into whatever the user is actually working
  -- in. It did: six panels appeared in one unrelated window, and since the
  -- typed command lands in a shell that runs the autolaunch hook, it
  -- recursed into a second launcher run. No panel is a small problem;
  -- keystrokes in the wrong window is not.
  --
  -- Every skip reports the full per-instance picture, because "which of
  -- these two cases is it" is exactly what could not be answered from the
  -- old one-line message.
  set diag to ""
  set frontIds to {}
  repeat with g in (every application process whose name is "ghostty")
    set gid to unix id of g
    set gFront to frontmost of g
    set diag to diag & gid & "(front=" & (gFront as string) & ",win=" & (count of windows of g) & ") "
    if gFront then set end of frontIds to gid
  end repeat
  if $TARGET_PID is not 0 then
    if (count of frontIds) is 0 then return "skip: no ghostty instance reports frontmost -- " & diag
    if (count of frontIds) is greater than 1 then return "skip: " & (count of frontIds) & " ghostty instances claim frontmost, cannot tell which is focused -- " & diag
    if (item 1 of frontIds) is not $TARGET_PID then return "skip: focused ghostty is pid " & (item 1 of frontIds) & ", not our instance $TARGET_PID -- " & diag
    set frontApp to first application process whose unix id is $TARGET_PID
  else
    set frontApp to first application process whose frontmost is true
    if name of frontApp is not "ghostty" then return "skip: frontmost is " & (name of frontApp)
  end if
  -- A Ghostty instance whose windows have all been closed still exists as
  -- a process, and asking it for the front window raises a bare "Invalid
  -- index (-1719)" that reads like a permissions or scripting fault rather
  -- than the plain fact it is. Say the plain fact instead.
  --
  -- No backticks anywhere in this heredoc body: it is deliberately UNQUOTED
  -- (<<APPLESCRIPT, not <<'APPLESCRIPT') so $TARGET_PID/$PANEL_CMD expand --
  -- which means bash also runs any backtick-quoted text in here as a real
  -- command substitution before osascript ever sees it. A "front window"
  -- comment written with markdown-style backtick code-formatting shipped as
  -- a live bug: bash executed "front window" as a command and osascript got
  -- the AppleScript with that comment line silently missing, every run.
  if (count of windows of frontApp) is 0 then return "skip: ghostty pid " & (unix id of frontApp) & " has no windows"
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
# That fix only reached the pin/no-pin decision below though — the launch
# gate right above it (deciding whether to run the launcher AT ALL) was
# still `claude*`, anchored to the start of the command line, so any prefix
# at all (`caffeinate -d claude`, `nohup claude`, `sudo claude`, an
# env-var-prefixed call) skipped the split entirely, with no pin decision
# to reach in the first place. Matches "claude" as a whole word anywhere in
# the command now, not just as its first token.
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
  [[ "$1" =~ '(^|[[:space:]])claude([[:space:]]|$)' ]] || return
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
  # Diagnostic: the pin/no-pin split is a silent decision with no other
  # trace of it anywhere — when "no pin" turns out to be the overwhelming
  # common case in practice, this is the only way to see the raw command
  # line that drove it instead of guessing at which flag matched.
  print -r -- "$(date '+%Y-%m-%d %H:%M:%S') [hook] cmd=[$1] pin_sid=${pin_sid:-none}" >> ~/.cache/claude-panel-launch.log
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
  # Keep a comment line directly above the final exec line attached to
  # it — splitting purely on "all but the last line" strands that
  # comment above the newly inserted block instead of above the command
  # it actually describes.
  tail_start=$gcl_lines
  second_last=$(sed -n "$((gcl_lines - 1))p" "$GCL")
  trimmed="${second_last#"${second_last%%[![:space:]]*}"}"
  case "$trimmed" in
    '#'*) tail_start=$((gcl_lines - 1)) ;;
  esac
  head -n "$((tail_start - 1))" "$GCL" > "$tmp"
  cat >> "$tmp" <<'GCL_EOF'

# Auto-open the live ccusage stats panel in a right-hand split, pinned to
# the exact session ID `claude` is about to start with (--session-id,
# injected into the launch line below) — this path execs `claude` directly
# as caffeinate's own argument, never typed at an interactive zsh prompt,
# so the zshrc preexec hook (and its pin-vs-guess decision) never sees it
# and never fires. Every session launched this way was unpinned, 100% of
# the time, forcing the panel to guess which transcript was this pane's by
# birth-time/recency — provably wrong whenever a second, already-open pane
# in the same project directory is concurrently active: confirmed live, a
# brand-new blank pane displayed a different, already-running pane's
# 47-turn/$3.99 conversation as its own "This Session" table. This window
# is always freshly created by the Finder Service (`open -na`), so there's
# no risk of double-launching — runs in the background so it doesn't delay
# Claude Code starting.
PIN_SID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
[ -x "$HOME/.local/bin/claude-panel-launch.sh" ] && "$HOME/.local/bin/claude-panel-launch.sh" "$PIN_SID" &
GCL_EOF
  while IFS= read -r tail_line; do
    case "$tail_line" in
      *'"$CLAUDE"'*)
        # Inject --session-id right after $CLAUDE so this pane's claude
        # starts with the exact ID the panel was just pinned to above.
        printf '%s\n' "${tail_line/\"\$CLAUDE\"/\"\$CLAUDE\" --session-id \"\$PIN_SID\"}" >> "$tmp"
        ;;
      *)
        printf '%s\n' "$tail_line" >> "$tmp"
        ;;
    esac
  done < <(tail -n "$((gcl_lines - tail_start + 1))" "$GCL")
  grep -qF '"$CLAUDE" --session-id "$PIN_SID"' "$tmp" ||
    echo "  (warning: couldn't find a \$CLAUDE invocation to pin --session-id onto — panel will still fall back to guessing for this launch path)" >&2
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

# This hook runs on EVERY prompt submit, and each `ccusage` invocation
# parses every transcript under ~/.claude/projects (hundreds of MB) to answer
# -- so the two uncached calls that used to live here cost a full
# double corpus scan per prompt, on the interactive path, inside a 5s
# timeout. Worse, the second was pure waste: `session --json -i <sid>`
# returns the same all-time `.totalCost` for that session that the FIRST
# call's payload already lists under `.session[] | select(.period==<sid>)`
# (verified identical across every active session). One call now answers
# both questions.
#
# What remains is cached in ccusage-panel.sh's cache directory using that
# script's exact key scheme -- sha256 of the argument string, first 16
# chars -- so this is the same cache entry the panel's own 7-day-average
# call writes. Whenever a panel is open the hook pays nothing at all; when
# none is, the hook populates it for the panel instead. Deliberately NOT
# keyed on transcript mtime like the panel's per-session cache: a prompt
# submit always follows a transcript write, so an mtime key would miss
# every single time and cache nothing.
#
# The TTL is generous because of what this value is FOR: a 7-day rolling
# average moves imperceptibly minute to minute, and it only ever gates a
# >2x escalation alert above a $5 floor. Staleness here cannot change an
# alert decision that a fresh read would not also have made.
CCUSAGE_CACHE_DIR="$HOME/.cache/ccusage-panel-cache"
HOOK_CACHE_TTL=120
mkdir -p "$CCUSAGE_CACHE_DIR" 2>/dev/null

since7=$(date -v-7d +%Y%m%d 2>/dev/null || date -d '7 days ago' +%Y%m%d)

# Scoped to Claude Code, like the panel's own queries. Unscoped, `ccusage
# session` covers every detected agent CLI, so the 7-day average this hook
# alerts against was diluted by OpenCode and anything else installed -- and
# an alert threshold computed from the wrong denominator fires at the wrong
# time, in a hook whose per-session throttle then eats the real crossing.
cache_args="claude session --json --since $since7 --offline"
cache_key=$(printf '%s' "$cache_args" | shasum -a 256 | cut -c1-16)
cache_file="$CCUSAGE_CACHE_DIR/$cache_key.json"

sessions_json=""
if [ -f "$cache_file" ]; then
  cache_mtime=$(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)
  if (( $(date +%s) - cache_mtime < HOOK_CACHE_TTL )); then
    sessions_json=$(cat "$cache_file" 2>/dev/null)
  fi
fi
if [ -z "$sessions_json" ]; then
  # `claude session` nests under `.sessions`; normalised to the `.session`
  # this file and the panel both read. Same adapter, same reason, as
  # ccusage-panel.sh's all_sessions().
  sessions_json=$(ccusage claude session --json --since "$since7" --offline 2>/dev/null \
    | jq -c '{session: (.sessions // .session // [])}' 2>/dev/null)
  # Only a parseable payload is cached -- writing an empty or truncated
  # result would poison the panel's cache too, since they share this file.
  if [ -n "$sessions_json" ] && jq -e '.session' >/dev/null 2>&1 <<<"$sessions_json"; then
    printf '%s' "$sessions_json" > "$cache_file.$$.tmp" 2>/dev/null &&
      mv "$cache_file.$$.tmp" "$cache_file" 2>/dev/null
  fi
fi

avg_session_cost=$(jq -r '
  [.session[].totalCost] | map(select(. > 0.05)) |
  if length >= 3 then (add/length) else 0 end
' <<<"$sessions_json" 2>/dev/null)
[ -z "$avg_session_cost" ] && avg_session_cost="0"

# A session with no billable activity yet is simply absent from the list;
# 0 is the same answer the old `-i` call gave for it, and is below
# MIN_SESSION_ALERT regardless.
session_cost=$(jq -r --arg s "$session_id" \
  '[.session[] | select(.period == $s) | .totalCost][0] // 0' <<<"$sessions_json" 2>/dev/null)
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
