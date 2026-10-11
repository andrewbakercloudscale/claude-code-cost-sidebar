# Check BH -- "Async Full Compaction" is a row of the turn table.
#
# Burst's /compact-async-full runs as Claude Code's own /compact, and Claude
# Code echoes it as "/compact" (2026-10-11: nothing in the session or the
# sidebar said a full compaction had been made). The transcript tells the two
# apart: the summary after the compact boundary says Burst wrote it. Claude
# Code's own compaction, whose summary does not, is no such row.
check_BH_full_compaction_marker() {
  sandbox_new BH
  local t="$SBX/t.jsonl"
  cat > "$t" <<'JSON'
{"type":"system","subtype":"compact_boundary","timestamp":"2026-10-07T12:00:00Z"}
{"type":"user","message":{"role":"user","content":"This session is being continued from a previous conversation."}}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-10-10T14:39:29Z"}
{"type":"user","message":{"role":"user","content":"<system-reminder>\nThe earlier part of this conversation was compacted by claude-burst to save context."}}
{"type":"user","message":{"role":"user","content":"a prompt that quotes \"compact_boundary\""}}
JSON
  local fn got
  fn=$(awk '/^def full_compaction_markers\(lines\):/{on=1} on&&/^COMPACTION_MARKERS =/{exit} on' "$PANEL_SH")
  assert_eq "the marker function is in the panel" "1" "$(printf '%s' "$fn" | grep -c '^def full_compaction_markers')"
  got=$(T="$t" FN="$fn" python3 -c '
import json, os
from datetime import datetime
def parse_iso(s): return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() if s else None
exec(os.environ["FN"])
for ts, kind, usd in full_compaction_markers(open(os.environ["T"]).readlines()):
    print(datetime.utcfromtimestamp(ts).strftime("%d %H:%M:%S"), kind, usd)
' 2>/dev/null)
  assert_eq "only the compaction made with Burst's summary" "10 14:39:29 full None" "$got"
  assert_eq "the row is drawn" "1" "$(grep -c 'Async Full Compaction \*\*\*' "$PANEL_SH")"
}
