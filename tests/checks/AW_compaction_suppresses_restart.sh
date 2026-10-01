# Check AW -- no restart warning once a pauseless compaction has a summary
# ready. On 2026-10-01 the banner kept flashing at 433k with "Pending" and
# "Finished" both on screen: the context figure was the last turn before the
# swap, and restarting then would only have thrown the summary away.
check_AW_compaction_suppresses_restart() {
  sandbox_new AW
  local fn got
  fn=$(awk '/^def compaction_supersedes\(/{on=1} on&&/^$/{exit} on' "$PANEL_SH")
  got=$(FN="$fn" python3 -c '
import os
exec(os.environ["FN"])
for m, t in [
    ([], 100),
    ([(50, "started", None)], 100),
    ([(50, "started", None), (150, "pending", None)], 100),
    ([(50, "started", None), (90, "pending", None)], 100),
    ([(90, "pending", None), (150, "finished", 0.1)], 100),
    ([(90, "pending", None), (150, "finished", 0.1)], 200),
]:
    print(int(compaction_supersedes(m, t)), end="")
')
  assert_eq "none, started, pending x2, finished in flight, finished landed" "001110" "$got"
  assert_eq "the panel gates the banner on it" "1" \
    "$(grep -c '\[ "\$SESS_COMPACTING" = 1 \] || restart_banner' "$PANEL_SH")"
}
