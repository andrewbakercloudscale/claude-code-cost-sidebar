# Check D -- the "wait to type" notice appears, says "ready", and always goes.
#
# While the launcher opens the panel split, focus is on the new split and the
# keyboard guard swallows input, so typing goes nowhere. The notice tells the
# user so. Its failure modes are both bad: a notice that stays up lies about
# a keyboard that works, and one that never closes is a window stuck over the
# terminal. So the interesting parts are the ways it ends, and the option
# that turns it off.
check_D_loading_overlay() {
  import_fn overlay_enabled || return 1
  import_fn show_overlay || return 1
  import_fn overlay_ready || return 1
  import_fn overlay_close || return 1
  import_fn release_keyboard_guard || return 1

  local real_home="$HOME" sbx
  sbx="${TMPDIR:-/tmp}/launcher-overlay.$$"
  rm -rf "$sbx"; mkdir -p "$sbx/.local/bin" "$sbx/.config/claude-panel"
  HOME="$sbx"
  LOG="$sbx/log"; : > "$LOG"
  attempt=1
  log() { printf '%s\n' "$1" >> "$LOG"; }
  local opts="$sbx/.config/claude-panel/options"

  # ---- 1. the option: default ON, explicit off only --------------------
  unset CLAUDE_PANEL_LOADING_OVERLAY
  assert_eq "no options file means on" "0" "$(overlay_enabled; echo $?)"
  printf 'CLAUDE_PANEL_CAFFEINATE=true\n' > "$opts"
  assert_eq "a file without the key means on" "0" "$(overlay_enabled; echo $?)"
  local v
  for v in false FALSE '"false"' "'off'" 0 no; do
    printf 'CLAUDE_PANEL_LOADING_OVERLAY=%s\n' "$v" > "$opts"
    assert_eq "$v turns it off" "1" "$(overlay_enabled; echo $?)"
  done
  printf 'CLAUDE_PANEL_LOADING_OVERLAY=false\n' > "$opts"
  assert_eq "the environment overrides the file" "0" \
    "$(CLAUDE_PANEL_LOADING_OVERLAY=true overlay_enabled; echo $?)"
  printf 'CLAUDE_PANEL_LOADING_OVERLAY=true\n' > "$opts"

  # ---- 2. lifecycle against a stub that records what it was told -------
  # The stub records its arguments and every signal, so "shown", "told it is
  # ready" and "closed" are observed rather than assumed. Traps go first and
  # "args" last, so once "args" is in the file a signal is guaranteed to be
  # recorded. waitrec polls for it: the first exec of a freshly written
  # script is held ~0.5s by macOS's policy scan, and a fixed sleep shorter
  # than that signalled a stub that had not started yet.
  local rec="$sbx/rec"
  cat > "$sbx/.local/bin/claude-panel-overlay" <<STUB
#!/usr/bin/env bash
trap 'printf "USR1\n" >> "$rec"; exit 0' USR1
trap 'printf "TERM\n" >> "$rec"; exit 0' TERM
printf 'args %s\n' "\$*" >> "$rec"
for _ in \$(seq 1 50); do sleep 0.1; done
printf 'timeout\n' >> "$rec"
STUB
  chmod +x "$sbx/.local/bin/claude-panel-overlay"
  waitrec() { # $1 = text to wait for in the record
    local i
    for i in $(seq 1 50); do grep -q "$1" "$rec" 2>/dev/null && return 0; sleep 0.1; done
    return 1
  }

  ghostty_pid=4242
  OVERLAY_PID=""
  show_overlay
  local first="$OVERLAY_PID"
  assert_contains "shown with the Ghostty pid and a 10s cap" "4242 10" \
    "$(waitrec args; cat "$rec")"
  show_overlay
  assert_eq "a second call while it is up starts no second notice" "$first" "$OVERLAY_PID"
  overlay_ready
  assert_contains "ready sends SIGUSR1 (the 'start typing' state)" "USR1" "$(waitrec USR1; cat "$rec")"
  assert_eq "and forgets it, so the EXIT trap does not cut the ready notice short" "" "$OVERLAY_PID"

  : > "$rec"
  show_overlay; waitrec args
  overlay_close
  assert_contains "close sends SIGTERM" "TERM" "$(waitrec TERM; cat "$rec")"

  # Off means not started at all, not started and hidden.
  : > "$rec"
  printf 'CLAUDE_PANEL_LOADING_OVERLAY=false\n' > "$opts"
  show_overlay; sleep 0.3
  assert_eq "switched off, nothing is started" "" "$OVERLAY_PID$(cat "$rec")"

  # ---- 3. the guard is released once the sequence is sent --------------
  sleep 30 &
  KEYBLOCK_PID=$!
  local guard=$KEYBLOCK_PID
  release_keyboard_guard
  sleep 0.1
  assert_eq "the guard process is gone" "gone" \
    "$(kill -0 "$guard" 2>/dev/null && echo alive || echo gone)"
  assert_contains "and the log says so" "keyboard guard released" "$(cat "$LOG")"

  HOME="$real_home"

  # ---- 4. it is wired in -----------------------------------------------
  # Helpers nothing calls would pass every check above.
  local body; body=$(cat "$LAUNCH_SH")
  assert_contains "the EXIT trap closes the notice on every other way out" \
    "trap overlay_close EXIT" "$body"
  assert_eq "shown at each attempt and before the AppleScript path" "2" \
    "$(printf '%s\n' "$body" | grep -c '^ *show_overlay$')"
  assert_eq "ready after the targeted send and after an ok AppleScript send" "2" \
    "$(printf '%s\n' "$body" | grep -cE '(^ *overlay_ready$|\) overlay_ready ;;)')"
  assert_eq "the guard is released on all three paths that sent keys" "3" \
    "$(printf '%s\n' "$body" | grep -c '^ *release_keyboard_guard$')"

  # ---- 5. the real helper, if this machine built one -------------------
  # Needs a GUI session to put a window up; it exits on its own regardless,
  # so these bound how long it can stay, which is the property that matters.
  local bin="${OVERLAY_BIN:-$(dirname "$LAUNCH_SH")/claude-panel-overlay}"
  if [ -x "$bin" ] && [ "$(uname)" = Darwin ]; then
    local t0 pid
    t0=$(date +%s); "$bin" 0 1 >/dev/null 2>&1
    assert_eq "the real helper closes itself at its timeout" "yes" \
      "$([ $(( $(date +%s) - t0 )) -le 3 ] && echo yes || echo "no, $(( $(date +%s) - t0 ))s")"
    t0=$(date +%s); "$bin" 0 99 >/dev/null 2>&1 & pid=$!
    sleep 0.5; kill -USR1 "$pid" 2>/dev/null; wait "$pid"
    assert_eq "and within about a second of being told it is ready" "yes" \
      "$([ $(( $(date +%s) - t0 )) -le 3 ] && echo yes || echo no)"
    bash -c '"$1" 0 10 >/dev/null 2>&1 & echo $! > "$2"; sleep 0.5' _ "$bin" "$sbx/opid"
    sleep 0.5
    assert_eq "and when the launcher dies before saying ready" "gone" \
      "$(kill -0 "$(cat "$sbx/opid")" 2>/dev/null && echo alive || echo gone)"
    kill "$(cat "$sbx/opid")" 2>/dev/null
  fi

  rm -rf "$sbx"
}
