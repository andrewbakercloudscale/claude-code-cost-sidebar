# Check AQ -- "Async Compaction Finished" sits at the swap, not the
# summary, and "Pending" at the summary's end, when it was ready.
#
# A session compacted twice keeps sending its first summary (compacted
# messages = the first count) until the second one swaps in at a plain
# prompt. The marker was drawn at the first request carrying ANY summary
# after the summary call, which on 2026-09-30 put it minutes before the real
# swap: the row where context fell 945k to 66k had no marker, and the marker
# sat below the visible turns. The swap is the first request whose
# compacted count changed.
check_AQ_compaction_marker_at_swap() {
  sandbox_new AQ
  local m="$SBX/metrics.jsonl"
  cat > "$m" <<'JSON'
{"time":"2026-09-30T08:49:28+02:00","session_id":"S","input_tokens":2,"compacted_messages":994}
{"time":"2026-09-30T08:49:30+02:00","session_id":"S","note":"compaction summary","api_equivalent_usd":0.21}
{"time":"2026-09-30T08:49:37+02:00","session_id":"S","input_tokens":2,"compacted_messages":994}
{"time":"2026-09-30T08:50:06+02:00","session_id":"S","input_tokens":2}
{"time":"2026-09-30T08:55:26+02:00","session_id":"S","input_tokens":2,"compacted_messages":1741}
{"time":"2026-09-30T08:56:00+02:00","session_id":"S","input_tokens":2,"compacted_messages":1741}
JSON
  local fn got
  fn=$(awk '/^def load_compaction_markers\(\):/{on=1} on&&/^COMPACTION_MARKERS =/{exit} on' "$PANEL_SH")
  assert_eq "the marker function is in the panel" "1" "$(printf '%s' "$fn" | grep -c '^def load_compaction_markers')"
  got=$(BURST_METRICS="$m" FN="$fn" python3 -c '
import json, os
from datetime import datetime
def parse_iso(s): return datetime.fromisoformat(s).timestamp()
BURST_METRICS, SESSION_ID = os.environ["BURST_METRICS"], "S"
exec(os.environ["FN"])
for ts, kind, usd in load_compaction_markers():
    print(int(ts) % 3600, kind, usd)
')
  # 08:49:30 is 2970s into the hour; 08:55:26 is 3326s.
  assert_eq "started at the summary, pending when ready, finished at the swap" "2970 started None
2970 pending None
3326 finished 0.21" "$got"

  # A failed summary never swaps in, so it is never pending.
  cat > "$m" <<'JSON'
{"time":"2026-09-30T08:49:30+02:00","session_id":"S","note":"compaction summary","http_status":529}
{"time":"2026-09-30T08:55:26+02:00","session_id":"S","input_tokens":2,"compacted_messages":1741}
JSON
  got=$(BURST_METRICS="$m" FN="$fn" python3 -c '
import json, os
from datetime import datetime
def parse_iso(s): return datetime.fromisoformat(s).timestamp()
BURST_METRICS, SESSION_ID = os.environ["BURST_METRICS"], "S"
exec(os.environ["FN"])
for ts, kind, usd in load_compaction_markers():
    print(int(ts) % 3600, kind, usd)
')
  assert_eq "a failed summary is started, never pending or finished" "2970 started None" "$got"
}
