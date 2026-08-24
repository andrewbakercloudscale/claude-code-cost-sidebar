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
# itself works in any terminal), Node.js (for `ccusage`), jq, and
# Accessibility permission granted to Ghostty/Terminal for the System
# Events automation (macOS will prompt the first time if not yet granted).
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
TURN_ROWS="${2:-20}"

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
C_CYAN=$'\033[36m'; C_YELLOW=$'\033[33m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'

fmt_num() {
  awk -v n="$1" 'BEGIN{
    n=n+0; neg=(n<0); if(neg) n=-n;
    n=int(n+0.5); s=sprintf("%d",n); out=""; l=length(s);
    for(i=1;i<=l;i++){ out=out substr(s,i,1); if((l-i)%3==0 && i!=l) out=out "," }
    print (neg?"-":"") out;
  }'
}
fmt_money() { printf '$%.2f' "${1:-0}"; }
fmt_hm() { local m=${1:-0}; m=${m%.*}; printf '%dh %02dm' $((m/60)) $((m%60)); }

# ---- traffic-light thresholds, shared by every colored figure in the panel ----
TIER_YELLOW_MULT=1.5
TIER_RED_MULT=2.0
BURN_YELLOW=3
BURN_RED=6
CTX_YELLOW=50
CTX_RED=80
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
# A short colored title, not a full-width divider bar — a bar that's drawn
# at $cols but rendered later in a narrower/resized pane just wraps into a
# confusing second row of "=" or "-", which is worse than no rule at all.
header() { local title="$1"; printf '%s%s%s\n' "$C_BOLD$C_CYAN" "$title" "$C_RESET"; }
# Erases to end of line after every printed row before the newline, so a
# frame whose lines are shorter than the previous frame's (e.g. right after
# a pane resize, or just because the numbers got shorter) never leaves
# trailing characters from the old frame ghosting through the new one.
clear_eol() { awk '{ printf "%s\033[K\n", $0 }'; }

while true; do
  printf '\033[H'
  cols=$(tput cols 2>/dev/null || echo 60)
  (( cols < 40 )) && cols=40
  rows=$(tput lines 2>/dev/null || echo 24)
  (( rows < 10 )) && rows=10

  # ---- active 5h block: fetched once here (not down in the ACTIVE BLOCK
  # section) so the summary line above can show the same burn-rate-derived
  # color as the detailed section — one source of truth, one API call.
  block_json=$(ccusage blocks --active --json --offline 2>/dev/null)
  has_block=$(jq -r '.blocks | length // 0' <<<"$block_json" 2>/dev/null)
  if [ "${has_block:-0}" = "1" ]; then
    IFS=$'\t' read -r blk_start blk_end blk_cost blk_tokens blk_cph blk_tpm blk_rem blk_projCost blk_projTokens blk_models <<<"$(jq -r '
      .blocks[0] |
      [
        (.startTime[0:19]+"Z" | fromdateiso8601 | strftime("%H:%M")),
        (.endTime[0:19]+"Z"   | fromdateiso8601 | strftime("%H:%M")),
        .costUSD, .totalTokens, .burnRate.costPerHour, .burnRate.tokensPerMinute,
        .projection.remainingMinutes, .projection.totalCost, .projection.totalTokens,
        (.models | join(", "))
      ] | @tsv
    ' <<<"$block_json")"
    burn_color=$(threshold_color "$blk_cph" "$BURN_YELLOW" "$BURN_RED")
    burn_label="Normal"
    [ "$burn_color" = "$C_YELLOW" ] && burn_label="Elevated"
    [ "$burn_color" = "$C_RED" ] && burn_label="High"
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

  # ---- live status line (current session) ----
  # Needs the REAL session_id and model.id — a placeholder session_id
  # ("live") matches no recorded session (session cost silently comes back
  # $-0.00), and an unset model.id makes ccusage assume an old 200k context
  # window instead of Sonnet 5's actual 1M, so context% reads >100%.
  latest=$(ls -t ~/.claude/projects/*/*.jsonl 2>/dev/null | head -1)
  if [ -n "$latest" ]; then
    IFS=$'\t' read -r sess_id model_id model_label folder_name < <(python3 - "$latest" <<'PYEOF'
import json, os, sys

path = sys.argv[1]
sid = os.path.basename(path).removesuffix(".jsonl")
model = "unknown"
folder = ""
try:
    with open(path) as f:
        for line in f:
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not folder and d.get("cwd"):
                folder = os.path.basename(d["cwd"])
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
print(f"{sid}\t{model}\t{label}\t{folder}")
PYEOF
    )
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
      if [ "$i" -eq 1 ]; then
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
        if [[ "$sess_part" =~ \$(-?[0-9.]+) ]]; then
          sess_amt="${BASH_REMATCH[1]}"
          sc=$(tier_color "$sess_amt" "$avg_session_cost" "$TIER_YELLOW_MULT" "$TIER_RED_MULT" "$MIN_SESSION_ALERT")
          sess_part="${sess_part/\$$sess_amt/${sc}\$${sess_amt}${C_RESET}}"
        fi
        printf '  %s\n' "$sess_part"

        today_part="${cost_parts[1]:-}"
        if [[ "$today_part" =~ \$(-?[0-9.]+) ]]; then
          today_amt="${BASH_REMATCH[1]}"
          tc=$(tier_color "$today_amt" "$avg_daily_30" "$TIER_YELLOW_MULT" "$TIER_RED_MULT" "$MIN_DAILY_ALERT")
          today_part="${today_part/\$$today_amt/${tc}\$${today_amt}${C_RESET}}"
        fi
        printf '  📅 %s\n' "$today_part"

        if [ "${has_block:-0}" = "1" ]; then
          printf '  ⏳ %s%s block (%s left)%s\n' "$burn_color" "$(fmt_money "$blk_cost")" "$(fmt_hm "$blk_rem")" "$C_RESET"
          printf '  🔥 %s%s/hr (%s)%s\n' "$burn_color" "$(fmt_money "$blk_cph")" "$burn_label" "$C_RESET"
        else
          printf '  ⏳ No active block\n'
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
        ctx_color=$(threshold_color "$ctx_pct" "$CTX_YELLOW" "$CTX_RED")
        forced_note=""
        if [ "$win_size" = "200000" ] && [[ "$model_id" == "claude-sonnet-5" || "$model_id" == "claude-fable-5" ]]; then
          forced_note=" [forced 200k]"
        fi
        printf '  🧠 Context: %s / %s tokens (%s%s%%%s)%s\n' \
          "$(fmt_num "$ctx_tokens")" "$(fmt_num "$win_size")" "$ctx_color" "$ctx_pct" "$C_RESET" "$forced_note"
      elif [ "$i" -ne 2 ] || [ "$n_segs" -lt 4 ]; then
        # Skip ccusage's own middle "burn rate" segment when present (i==2
        # of 4) — already printed above from the JSON fetch; anything else
        # (model name, etc.) prints as-is.
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
    printf '  📁 Folder: %s\n' "$folder_disp"
    # Both trend lines below are colored against the SAME window one period
    # earlier (this week's avg vs last week's, this month's spend vs last
    # month's) — a baseline has no natural threshold of its own, but a
    # widening gap vs its own past is exactly the "am I burning through
    # tokens faster than before" signal worth a color for.
    if awk -v a="$avg_session_cost" 'BEGIN{exit !(a>0)}'; then
      avgc=$(tier_color "$avg_session_cost" "$prev7_avg" "$TIER_YELLOW_MULT" "$TIER_RED_MULT" "$MIN_TREND_ALERT")
      printf '  📊 7-day avg session: %s%s%s\n' "$avgc" "$(fmt_money "$avg_session_cost")" "$C_RESET"
    fi
    spendc=$(tier_color "$spend30" "$prev_spend30" "$TIER_YELLOW_MULT" "$TIER_RED_MULT" "$MIN_TREND_ALERT")
    printf '  💵 30-day spend: %s%s%s\n' "$spendc" "$(fmt_money "$spend30")" "$C_RESET"
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
  header "THIS SESSION — PER TURN"
  if [ -n "$latest" ]; then
    python3 - "$latest" "$TURN_ROWS" <<'PYEOF'
import json, sys

path, max_rows = sys.argv[1], int(sys.argv[2])

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

    turns.append((model_label(model), total_ctx, cc_tok, cache_pct, cost))

total_n = len(turns)
shown = turns[-max_rows:]
if not shown:
    print("  (no assistant turns yet)")
else:
    if total_n > len(shown):
        print(f"  (showing last {len(shown)} of {total_n} turns)")
    print(f"  {'Turn':<6}{'Model':<12}{'Input':>8}{'Δ Context':>11}{'Cache':>8}{'Cost':>9}")
    start_idx = total_n - len(shown) + 1
    for i, (label, total_ctx, delta, cache_pct, cost) in enumerate(shown):
        turn_no = start_idx + i
        print(f"  {turn_no:<6}{label:<12}{fmt_k(total_ctx):>8}{'+' + fmt_k(delta):>11}{cache_pct:>7.0f}%{'$' + format(cost, '.2f'):>9}")
    session_cost = sum(t[4] for t in turns)
    print(f"  est. session total: ${session_cost:.2f} (all {total_n} turns in this file)")
PYEOF
  else
    echo "  (no active Claude Code session found)"
  fi
  } )
  printf '%s\n' "$guaranteed" | clear_eol
  used_lines=$(printf '%s\n' "$guaranteed" | wc -l | tr -d ' ')
  remaining=$(( rows - 1 - used_lines ))

  if (( remaining > 0 )); then
  {
  echo

  # ---- active 5h block: burn rate + projection ----
  # block_json/blk_*/burn_color/burn_label were already fetched once, up
  # top before the summary line, so this section and the summary agree.
  header "ACTIVE BLOCK"
  if [ "${has_block:-0}" = "1" ]; then
    printf '  window   %s – %s  (%s left)\n' "$blk_start" "$blk_end" "$(fmt_hm "$blk_rem")"
    printf '  spent    %s   %s tok\n' "$(fmt_money "$blk_cost")" "$(fmt_num "$blk_tokens")"
    printf '  burn     %s%s/hr (%s)%s   %s tok/min\n' "$burn_color" "$(fmt_money "$blk_cph")" "$burn_label" "$C_RESET" "$(fmt_num "$blk_tpm")"
    printf '  proj.    %s total   %s tok\n' "$(fmt_money "$blk_projCost")" "$(fmt_num "$blk_projTokens")"
    printf '  models   %s\n' "$blk_models"
  else
    echo "  (no active block)"
  fi
  echo

  # ---- today: totals + per-model breakdown ----
  header "TODAY"
  daily_json=$(ccusage daily --json --last 1 --offline 2>/dev/null)
  if [ -n "$daily_json" ] && [ "$(jq -r '.daily | length' <<<"$daily_json" 2>/dev/null)" != "0" ]; then
    IFS=$'\t' read -r tCost tTok tIn tOut tCacheC tCacheR <<<"$(jq -r '
      .totals | [.totalCost, .totalTokens, .inputTokens, .outputTokens, .cacheCreationTokens, .cacheReadTokens] | @tsv
    ' <<<"$daily_json")"
    printf '  total    %s   %s tok\n' "$(fmt_money "$tCost")" "$(fmt_num "$tTok")"
    printf '  in/out   %s / %s   cache new/read %s / %s\n' \
      "$(fmt_num "$tIn")" "$(fmt_num "$tOut")" "$(fmt_num "$tCacheC")" "$(fmt_num "$tCacheR")"
    while IFS=$'\t' read -r mname mcost mtok; do
      [ -z "$mname" ] && continue
      printf '    %-24s %8s  %s tok\n' "$mname" "$(fmt_money "$mcost")" "$(fmt_num "$mtok")"
    done < <(jq -r '.daily[0].modelBreakdowns[]? | [.modelName, .cost, (.inputTokens+.outputTokens+.cacheCreationTokens+.cacheReadTokens)] | @tsv' <<<"$daily_json")
  else
    echo "  (no usage yet today)"
  fi
  echo

  # ---- 3-day trend ----
  header "LAST 3 DAYS"
  since3=$(date -v-2d +%Y%m%d 2>/dev/null || date -d '2 days ago' +%Y%m%d)
  trend_json=$(ccusage daily --json --since "$since3" --offline 2>/dev/null)
  if [ -n "$trend_json" ]; then
    barw=$((cols - 22)); (( barw < 10 )) && barw=10
    maxcost=$(jq -r '[.daily[].totalCost] | max // 1' <<<"$trend_json")
    awk -v m="$maxcost" 'BEGIN{if(m<=0) print 1; else print m}' >/dev/null
    while IFS=$'\t' read -r day dcost dtok; do
      [ -z "$day" ] && continue
      n=$(awk -v c="$dcost" -v m="$maxcost" -v w="$barw" 'BEGIN{ if(m<=0) m=1; n=int((c/m)*w+0.5); if(n<0)n=0; print n }')
      bar=$(printf '%*s' "$n" '' | tr ' ' '#')
      printf '  %-5s %-*s %s\n' "${day:5}" "$barw" "$bar" "$(fmt_money "$dcost")"
    done < <(jq -r '.daily[] | [.period, .totalCost, .totalTokens] | @tsv' <<<"$trend_json")
  fi
  echo

  # ---- week / month totals ----
  header "WEEK / MONTH"
  week_cost=$(ccusage weekly --json --last 1 --offline 2>/dev/null | jq -r '.totals.totalCost // 0')
  month_cost=$(ccusage monthly --json --last 1 --offline 2>/dev/null | jq -r '.totals.totalCost // 0')
  printf '  this week   %s\n' "$(fmt_money "$week_cost")"
  printf '  this month  %s\n' "$(fmt_money "$month_cost")"
  echo

  # ---- top sessions today ----
  header "TOP SESSIONS TODAY"
  session_json=$(ccusage session --json --since "$(date +%Y%m%d)" --offline 2>/dev/null)
  if [ -n "$session_json" ] && [ "$(jq -r '.session | length' <<<"$session_json" 2>/dev/null)" != "0" ]; then
    while IFS=$'\t' read -r sid scost stok slast; do
      [ -z "$sid" ] && continue
      lasthm=$(jq -rn --arg t "$slast" '($t[0:19]+"Z") | fromdateiso8601 | strftime("%H:%M")' 2>/dev/null)
      printf '  %-10s %8s  %s tok  last %s\n' "${sid:0:10}" "$(fmt_money "$scost")" "$(fmt_num "$stok")" "$lasthm"
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
  # resize math, and every keystroke — happens inside ONE osascript call.
  # Splitting this across two calls previously let frontmost change out
  # from under the second one, and both halves would separately exit 0.
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
    keystroke "~/.local/bin/ccusage-panel.sh"
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
# returns focus to the left pane. Doesn't touch any existing `claude`
# alias/function — hooks in via preexec instead.
_ccusage_panel_autolaunch() {
  case "$1" in
    claude*) ;;
    *) return ;;
  esac
  [ -n "${CCUSAGE_PANEL_LAUNCHED:-}" ] && return
  export CCUSAGE_PANEL_LAUNCHED=1
  ~/.local/bin/claude-panel-launch.sh &
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

latest=$(ls -t ~/.claude/projects/*/*.jsonl 2>/dev/null | head -1)
[ -z "$latest" ] && exit 0
session_id=$(basename "$latest" .jsonl)
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
