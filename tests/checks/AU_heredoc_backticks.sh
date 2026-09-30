# Check AU -- no backtick inside an UNQUOTED heredoc anywhere in setup.
#
# An unquoted heredoc (<<WORD, not <<'WORD') is expanded by bash, so a
# backtick pair in it is a live command substitution. The launcher's
# AppleScript heredoc had three, all in "--" comments written with markdown
# code formatting: every launch printed "first: command not found",
# "keystroke: command not found" and "tell: command not found" into the
# user's terminal. Setup's own heredocs are quoted, but the launcher it
# writes contains an unquoted one, so every line of the file is scanned.
check_AU_heredoc_backticks() {
  local setup="$HERE/../claude-panel-setup.sh" hits n
  n=$(grep -cE "<<-?[A-Za-z_]+([[:space:]]|$)" "$setup")
  assert_ne "unquoted heredocs found to scan" "0" "$n"
  hits=$(awk '
    delim == "" && match($0, /<<-?[A-Za-z_]+([ \t]|$)/) {
      d = substr($0, RSTART, RLENGTH); sub(/^<<-?/, "", d); sub(/[ \t]$/, "", d)
      delim = d; next
    }
    delim != "" && $0 == delim { delim = ""; next }
    delim != "" && index($0, "`") { print NR ": " $0 }
  ' "$setup")
  assert_eq "no backticks inside an unquoted heredoc" "" "$hits"
}
