# Check C -- the launcher is the only process that can pair a panel with its
# claude, and it refuses to guess.
#
# The two live in different splits with different controlling terminals and
# share nothing else, so neither can work the other out alone. This script
# runs in the claude pane's own shell and then watches a new ccusage-panel.sh
# appear, which is the single moment both facts are knowable. If it writes a
# pairing it is wrong about, a panel follows the wrong session confidently and
# silently for as long as it runs -- so the interesting behaviour here is the
# refusals, not the happy path.
check_C_pane_pairing() {
  import_fn write_pane_pairing || return 1

  local sbx; sbx="${TMPDIR:-/tmp}/launcher-pairing.$$"
  rm -rf "$sbx"; mkdir -p "$sbx"
  # shellcheck disable=SC2034  # both are read by write_pane_pairing
  PIN_PANE_DIR="$sbx/pane"
  LOG="$sbx/log"
  attempt=1
  log() { printf '%s\n' "$1" >> "$LOG"; }

  # ---- 1. one new panel, and it has a terminal: pair it ----------------
  # $$ is a real, running process with this shell's own tty, which is the
  # closest a hermetic check gets to "the panel that just started".
  CLAUDE_TTY="ttyCLAUDE"
  write_pane_pairing "$$"
  local ptty; ptty=$(ps -o tty= -p $$ 2>/dev/null | tr -d '[:space:]')
  case "$ptty" in
    ''|'??')
      # No tty (CI). Then the refusal below is what must happen, and saying
      # so is the assertion -- not silently skipping and reporting ok.
      assert_eq "with no terminal, nothing is paired" "" "$(ls "$PIN_PANE_DIR" 2>/dev/null)"
      assert_contains "and it says why" "no controlling terminal" "$(cat "$LOG")"
      ;;
    *)
      assert_eq "the pairing is filed under the PANEL's terminal" \
        "$ptty" "$(ls "$PIN_PANE_DIR" 2>/dev/null)"
      local ctty pid rest
      IFS=$'\t' read -r ctty pid rest < "$PIN_PANE_DIR/$ptty"
      assert_eq "and names the claude pane it was launched from" "ttyCLAUDE" "$ctty"
      # The pid is what makes a tty name safe to key on: terminal names are
      # recycled, and without it the next panel to hold this tty would
      # inherit a pairing written for a claude it has nothing to do with.
      assert_eq "and the process it was written for" "$$" "$pid"
      ;;
  esac

  # ---- 2. two new panels at once: refuse ------------------------------
  # Which of them is ours is a guess, and a guess here is exactly the
  # confidently-wrong outcome the pairing exists to remove. The
  # directory-keyed pin remains as the honest fallback.
  rm -rf "$PIN_PANE_DIR"; : > "$LOG"
  write_pane_pairing "$(printf '%s\n%s\n' "$$" "$$")"
  assert_eq "two candidates means no pairing at all" "" "$(ls "$PIN_PANE_DIR" 2>/dev/null)"
  assert_contains "and the log says which guess was declined" \
    "cannot tell which is ours" "$(cat "$LOG")"

  # ---- 3. no panel appeared: refuse -----------------------------------
  rm -rf "$PIN_PANE_DIR"; : > "$LOG"
  write_pane_pairing ""
  assert_eq "no candidate means no pairing" "" "$(ls "$PIN_PANE_DIR" 2>/dev/null)"

  # ---- 4. launcher with no terminal of its own: refuse -----------------
  # A launcher started from something that is not a pane cannot say which
  # pane the session is in, so it must not claim one.
  rm -rf "$PIN_PANE_DIR"; : > "$LOG"
  CLAUDE_TTY=""
  write_pane_pairing "$$"
  assert_eq "a launcher with no pane of its own pairs nothing" "" "$(ls "$PIN_PANE_DIR" 2>/dev/null)"

  # ---- 5. it is actually wired in -------------------------------------
  # A pairing writer nothing calls is the gate-that-measures-nothing shape:
  # every check above would still pass.
  local body; body=$(cat "$LAUNCH_SH")
  assert_eq "the launcher calls it once per successful path" "2" \
    "$(printf '%s\n' "$body" | grep -c 'write_pane_pairing "\$new_pids"')"
  assert_contains "and derives its own pane from the controlling terminal" \
    'CLAUDE_TTY="$(ps -o tty=' "$body"

  rm -rf "$sbx"
  unset -f log
}
