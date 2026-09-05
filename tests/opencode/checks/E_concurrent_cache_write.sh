# Check E -- two panels exporting the same session do not fight over a temp
# file. The sibling of check U in the Claude panel's suite, and here for the
# same reason: the bug was found there, and this file had the same code.
#
# Both writers use `> "$f.tmp" && mv "$f.tmp" "$f"`, which is atomic for the
# READER but was not safe for the second WRITER. oc_export_cached() has no
# lock around it -- deliberately, since it is keyed on the session's own
# `updated` stamp rather than on a shared TTL -- so two panels open on one
# session both wrote `<file>.tmp`, whichever renamed first won, and the
# loser's `mv` failed on a path that no longer existed.
#
# Check D already runs three concurrent panels and did not catch this: it
# exercises oc_cached, which IS lock-protected, and never touches the export
# path. Concurrency coverage is per code path, not per suite.
check_E_concurrent_cache_write() {
  sandbox_new E

  # Structural, so a future edit that reinstates a shared temp name fails
  # here rather than on someone's screen with two panes open.
  ( load_panel 5 12
    declare -f oc_export_cached > "$SBX/export-body"
    declare -f opencode_cached  > "$SBX/cached-body" )
  assert_contains "the export cache writes a per-process temp" \
    '$cache_file.$$.tmp' "$(cat "$SBX/export-body")"
  assert_contains "and so does the query cache" \
    '$cache_file.$$.tmp' "$(cat "$SBX/cached-body")"

  # Behavioural: two writers, concurrently, on one session's export. Each
  # must be a separate PROCESS -- a subshell inherits $$ from its parent, so
  # `( ... )` alone would reuse one temp name and prove nothing.
  local i
  for i in 1 2; do
    ( load_panel 5 12
      oc_export_cached "ses_shared" "1700000000000" >/dev/null 2>"$SBX/err.$i"
      printf '%s' "$?" > "$SBX/rc.$i" ) &
  done
  wait

  assert_eq "first writer succeeded" "0" "$(cat "$SBX/rc.1")"
  assert_eq "second writer succeeded" "0" "$(cat "$SBX/rc.2")"

  # The surviving entry must be a real one, stamp on the first line. Exit
  # codes alone would still pass over an empty file.
  local cd first
  cd="$HOME/.cache/opencode-panel-cache"
  first=$(head -1 "$cd"/export-*.json 2>/dev/null | head -1)
  assert_eq "the entry carries its stamp, not a fragment" "1700000000000" "$first"

  assert_eq "no temp files left behind" "0" \
    "$(find "$cd" -maxdepth 1 -name '*.tmp' | wc -l | tr -d ' ')"
}
