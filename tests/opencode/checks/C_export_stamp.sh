# Check C -- export is keyed on THIS session's own updated timestamp, not a
# TTL and not the whole-database gate. Tighter and cheaper than either: it
# cannot go stale except when the session it actually names has moved, and
# it costs nothing extra to check since session_updated already comes free
# out of the session-list fetch every tick already makes.
check_C_export_stamp() {
  sandbox_new C
  load_panel 5 12

  oc_export_cached "sess-1" "1000" >/dev/null
  assert_eq "first fetch for this stamp"  "1" "$(calls_for export)"
  oc_export_cached "sess-1" "1000" >/dev/null
  assert_eq "same session, same stamp: no refetch" "1" "$(calls_for export)"

  oc_export_cached "sess-1" "2000" >/dev/null
  assert_eq "the session moved: exactly one refetch" "2" "$(calls_for export)"

  # A second session's cache is independent -- one file per session id, not
  # one growing per (session, stamp) pair.
  oc_export_cached "sess-2" "1000" >/dev/null
  assert_eq "a different session is its own entry" "3" "$(calls_for export)"
  oc_export_cached "sess-1" "2000" >/dev/null
  assert_eq "and sess-1 at its current stamp is still cached" "3" "$(calls_for export)"
}
