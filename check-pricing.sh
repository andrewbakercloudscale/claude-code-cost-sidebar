#!/usr/bin/env bash
# Read-only audit: re-prices this machine's Claude Code transcripts at
# Anthropic's published per-model rates and lays the result out the way the
# claude.ai usage page does -- per model, and per UTC day -- so the panel's
# month figure can be reconciled against it line by line.
#
# The two numbers disagree for one of two reasons, and they look different:
#   - a RATE is wrong: every day of one model is off by the same ratio;
#   - DATA is missing: whole days (or one model on some days) are in the
#     usage page and absent here. The usage page counts everything billed to
#     the account -- claude.ai chat, Claude Code on the web, other machines --
#     and this machine only has transcripts for what ran on it, for as long
#     as Claude Code keeps them (cleanupPeriodDays, 30 by default).
#
# Usage:
#   bash check-pricing.sh                 # this calendar month, UTC days
#   bash check-pricing.sh 2026-09-01 2026-09-30
set -euo pipefail

main() {
  local start="${1:-$(date -u +%Y-%m-01)}" end="${2:-$(date -u +%Y-%m-%d)}"
  python3 - "$start" "$end" <<'PYEOF'
import collections, datetime as dt, glob, json, os, sys

# (input, output) $/1M tokens. Cache reads are 0.1x input unless listed in
# CACHE_READ; cache writes are 1.25x (5 minute) and 2x (1 hour) input. Fast
# mode bills 2x on every token class.
PRICES = {
    "claude-fable-5-1": (10.00, 50.00), "claude-fable-5": (10.00, 50.00),
    "claude-mythos-5-1": (10.00, 50.00), "claude-mythos-5": (10.00, 50.00),
    "claude-opus-5-5": (4.00, 20.00), "claude-opus-5": (5.00, 25.00),
    "claude-opus-4-8": (5.00, 25.00), "claude-opus-4-7": (5.00, 25.00),
    "claude-opus-4-6": (5.00, 25.00),
    "claude-sonnet-5-5": (2.00, 10.00), "claude-sonnet-5": (2.00, 10.00),
    "claude-sonnet-4-6": (3.00, 15.00),
    "claude-haiku-4-5": (1.00, 5.00), "claude-haiku-4-5-20251001": (1.00, 5.00),
}
CACHE_READ = {"claude-opus-5-5": 0.20, "claude-fable-5-1": 0.25}

start, end = (dt.date.fromisoformat(a) for a in sys.argv[1:3])
seen = set()
by_model = collections.defaultdict(float)
by_day = collections.defaultdict(lambda: collections.defaultdict(float))
unpriced = collections.Counter()
fast = 0
oldest = None
for path in glob.glob(os.path.expanduser("~/.claude/projects/**/*.jsonl"), recursive=True):
    try:
        f = open(path, errors="ignore")
    except OSError:
        continue
    with f:
        for line in f:
            if '"assistant"' not in line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            msg = d.get("message") or {}
            usage, model = msg.get("usage"), msg.get("model")
            if d.get("type") != "assistant" or not usage or model == "<synthetic>":
                continue
            key = (msg.get("id"), d.get("requestId"))  # ccusage's dedup key
            if key in seen:
                continue
            seen.add(key)
            try:
                day = dt.datetime.fromisoformat(d["timestamp"].replace("Z", "+00:00")).astimezone(dt.timezone.utc).date()
            except (KeyError, ValueError):
                continue
            oldest = day if oldest is None or day < oldest else oldest
            if not start <= day <= end:
                continue
            if model not in PRICES:
                unpriced[model] += 1
                continue
            cc = usage.get("cache_creation") or {}
            cw1h = cc.get("ephemeral_1h_input_tokens", 0) if cc else 0
            cw5m = cc.get("ephemeral_5m_input_tokens", 0) if cc else usage.get("cache_creation_input_tokens", 0)
            pin, pout = PRICES[model]
            cost = (usage.get("input_tokens", 0) * pin
                    + usage.get("output_tokens", 0) * pout
                    + usage.get("cache_read_input_tokens", 0) * CACHE_READ.get(model, pin * 0.1)
                    + cw1h * pin * 2.0 + cw5m * pin * 1.25) / 1e6
            if usage.get("speed") == "fast":
                fast += 1
                cost *= 2
            by_model[model] += cost
            by_day[day][model] += cost

short = lambda m: m.removeprefix("claude-")
print(f"Transcript re-pricing, {start} to {end} (UTC days, published rates)\n")
print("By model:")
for m, c in sorted(by_model.items(), key=lambda kv: -kv[1]):
    print(f"  {short(m):22} ${c:10.2f}")
print(f"  {'TOTAL':22} ${sum(by_model.values()):10.2f}\n")
print("By UTC day (compare with the usage page's daily bars):")
day = start
while day <= end:
    row = by_day.get(day, {})
    parts = "  ".join(f"{short(m)} ${c:.2f}" for m, c in sorted(row.items(), key=lambda kv: -kv[1]))
    print(f"  {day}  ${sum(row.values()):8.2f}  {parts}")
    day += dt.timedelta(days=1)
print()
print(f"Oldest transcript on disk: {oldest} (Claude Code deletes transcripts after cleanupPeriodDays, default 30)")
if oldest and oldest > start:
    print(f"  WARNING: days before {oldest} have no transcripts left, so they cannot be counted here.")
if fast:
    print(f"Fast-mode requests: {fast} (priced at 2x above; the panel's own pricing does not apply the fast premium)")
for m, n in unpriced.items():
    print(f"  UNPRICED model {m}: {n} request(s) not counted")
PYEOF
  if command -v ccusage >/dev/null 2>&1; then
    echo
    echo "ccusage monthly (local-time months, what the panel's month figure starts from):"
    ccusage claude monthly --json --offline 2>/dev/null \
      | jq -r '.monthly[-1] | "  \(.month): $\(.totalCost * 100 | round / 100)", (.modelBreakdowns[] | "    \(.modelName | ltrimstr("claude-")): $\(.cost * 100 | round / 100)")' \
      || echo "  (ccusage monthly failed)"
  fi
}

main "$@"
