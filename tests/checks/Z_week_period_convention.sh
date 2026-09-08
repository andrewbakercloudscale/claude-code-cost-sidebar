# Check Z -- the week line reads the tool's week, not ours.
#
# `ccusage claude weekly` keys each row by the week's START, and that day is
# a SUNDAY. The panel used to compute the Monday and ask for that key
# exactly, so from Monday to Saturday it asked for a key no row carried; the
# `// 0` fallback caught the miss and the line rendered `week: $0` on a week
# with several days of spend in it, directly above a `3d:` line listing that
# spend. Nothing errored and nothing was logged.
#
# The suite agreed with the bug, which is the part worth guarding: the only
# weekly fixture it had (check Q's) was keyed to a Monday. A fixture written
# in a shape the real tool never emits is not a test, it is a second copy of
# the bug -- the same lesson check Q records about `.period`.
#
# So these fixtures are Sunday-keyed, matching live `ccusage claude weekly
# --json` output, and the check also pins a Monday-keyed report to prove the
# lookup no longer depends on either convention being the right one.
check_Z_week_period_convention() {
  sandbox_new Z

  # Sunday-keyed, as the real tool emits. 2026-09-06 is a Sunday; the clock
  # is pinned to Tuesday the 8th, mid-week, where the old code failed.
  cat > "$CCUSAGE_FIXTURE_DIR/weekly.json" <<'JSON'
{"weekly":[{"week":"2026-08-30","totalCost":47.25,"totalTokens":900},
           {"week":"2026-09-06","totalCost":31.50,"totalTokens":700}]}
JSON
  load_panel 10 12 ""
  seed_recent
  local r; r=$(recent_sections)

  export PANEL_FAKE_NOW=$(( $(local_midnight "2026-09-08") + 45000 ))
  assert_eq "mid-week, the CURRENT week's row is selected" \
    "31.50" "$(num "$(current_week_cost "$r")")"
  assert_ne "and not the \$0 the exact-Monday lookup produced" \
    "0.00" "$(num "$(current_week_cost "$r")")"
  assert_ne "and not the previous week either" \
    "47.25" "$(num "$(current_week_cost "$r")")"

  # The boundary in both directions: on the week-start day itself, and on the
  # last day of that week, the same row must still be the one selected.
  export PANEL_FAKE_NOW=$(( $(local_midnight "2026-09-06") + 45000 ))
  assert_eq "on the week-start day, that week's row" \
    "31.50" "$(num "$(current_week_cost "$r")")"
  export PANEL_FAKE_NOW=$(( $(local_midnight "2026-09-12") + 45000 ))
  assert_eq "on the last day of that week, still that week's row" \
    "31.50" "$(num "$(current_week_cost "$r")")"

  # One day later is a new week with no row. That must read 0 -- NOT the
  # previous week, which is what taking the last row would have done and the
  # reason the original code looked up an exact key at all.
  export PANEL_FAKE_NOW=$(( $(local_midnight "2026-09-13") + 45000 ))
  assert_eq "a new week with no usage reads 0, not last week's total" \
    "0.00" "$(num "$(current_week_cost "$r")")"

  # Convention-independence: the same lookup against a Monday-keyed report.
  # If ccusage ever moves its week start, this line keeps working.
  sandbox_new Z2
  cat > "$CCUSAGE_FIXTURE_DIR/weekly.json" <<'JSON'
{"weekly":[{"week":"2026-08-31","totalCost":47.25,"totalTokens":900},
           {"week":"2026-09-07","totalCost":31.50,"totalTokens":700}]}
JSON
  load_panel 10 12 ""
  seed_recent
  r=$(recent_sections)
  export PANEL_FAKE_NOW=$(( $(local_midnight "2026-09-08") + 45000 ))
  assert_eq "a Monday-keyed report resolves the same way" \
    "31.50" "$(num "$(current_week_cost "$r")")"

  # An empty report is a real state (a fresh install, an offline corpus) and
  # must not error out of the jq pipeline into an empty string.
  sandbox_new Z3
  load_panel 10 12 ""
  seed_recent
  assert_eq "an empty weekly report reads 0" \
    "0.00" "$(num "$(current_week_cost "$(recent_sections)")")"

  unset PANEL_FAKE_NOW
}
