# Check BF -- CLAUDE_PANEL_CAFFEINATE and CLAUDE_PANEL_KEEP_SCREEN_ON decide
# how a session is kept awake, from the Finder launcher and typed.
#
# The launcher hard-coded `caffeinate -i`, so the dashboard's keep-awake tick
# said nothing true about a session started from Finder and nothing could
# keep the screen on: on 2026-10-06 a Mac with sessions open turned its
# screen off and locked. Runs setup's own step against a fixture, then the
# ~/.zshrc wrapper with caffeinate and claude stubbed, so neither drifts
# from what ships (check AR covers the uninstaller putting the line back).
# No real caffeinate is ever run.
check_BF_keep_awake() {
  sandbox_new BF
  case "$HOME" in "$SBX"/*) ;; *) _fail "HOME is the sandbox" "$SBX/..." "$HOME"; return ;; esac
  local setup="$HERE/../claude-panel-setup.sh" bin="$HOME/.local/bin"
  mkdir -p "$bin" "$HOME/.config/claude-panel"
  local step="$SBX/aw-step.sh"
  awk '/^GCL_AW_MARKER=/{on=1} on{print} on && /^fi$/{exit}' "$setup" > "$step"
  assert_contains "setup has the keep-awake step" 'PANEL_AWAKE' "$(cat "$step")"

  local GCL="$bin/ghostty-claude-launcher" pin='"$CLAUDE" --session-id "$PIN_SID"'
  printf '%s\n' '#!/bin/bash' 'CLAUDE=claude' 'PIN_SID=s1' '# caffeinate -i keeps the Mac awake.' \
    'caffeinate -i "$CLAUDE" --session-id "$PIN_SID"' > "$GCL"
  (GCL="$GCL" GCL_PIN_LINE="$pin" bash "$step") >/dev/null
  assert_not_contains "caffeinate is no longer hard-coded on the launch line" 'caffeinate' "$(tail -1 "$GCL")"
  (GCL="$GCL" GCL_PIN_LINE="$pin" bash "$step") >/dev/null
  assert_eq "a second run adds nothing" "1" "$(grep -c 'CLAUDE_PANEL_CAFFEINATE (claude-panel' "$GCL")"

  # Stubs that say how the session was started.
  local stub="$SBX/stub"; mkdir -p "$stub"
  printf '#!/bin/bash\nf=$1; shift\necho "caffeinate $f: $*"\n' > "$stub/caffeinate"
  printf '#!/bin/bash\necho "direct: $*"\n' > "$stub/claude"
  chmod +x "$stub/caffeinate" "$stub/claude"
  local f="$HOME/.config/claude-panel/options"
  rm -f "$f"
  assert_eq "no key keeps the launcher awake, as before" "caffeinate -i: claude --session-id s1" "$(PATH="$stub:$PATH" bash "$GCL")"
  printf 'CLAUDE_PANEL_CAFFEINATE=true\nCLAUDE_PANEL_KEEP_SCREEN_ON=true\n' > "$f"
  assert_eq "the screen option adds -d" "caffeinate -di: claude --session-id s1" "$(PATH="$stub:$PATH" bash "$GCL")"
  printf 'CLAUDE_PANEL_CAFFEINATE=false\nCLAUDE_PANEL_KEEP_SCREEN_ON=true\n' > "$f"
  assert_eq "off starts the session as it is" "direct: --session-id s1" "$(PATH="$stub:$PATH" bash "$GCL")"

  # A launcher that never ran its session under caffeinate is left alone.
  printf '%s\n' '#!/bin/bash' 'CLAUDE=claude' 'PIN_SID=s1' '"$CLAUDE" --session-id "$PIN_SID"' > "$GCL"
  (GCL="$GCL" GCL_PIN_LINE="$pin" bash "$step") >/dev/null
  assert_eq "no caffeinate before, none added" "0" "$(grep -c 'PANEL_AWAKE' "$GCL")"

  # One time, a Mac with Finder launchers has the option turned on: they
  # were keeping it awake already.
  local mig="$SBX/mig-step.sh"
  awk '/^AW_MIGRATED=/{on=1} on{print} on && /^fi$/{n++} n==2{exit}' "$setup" > "$mig"
  printf '# CLAUDE_PANEL_CAFFEINATE: keep the Mac awake (caffeinate -i) while a panel runs\nCLAUDE_PANEL_CAFFEINATE=false\nCLAUDE_PANEL_ALERTS=true\n' > "$f"
  (PANEL_OPTIONS="$f" BIN_DIR="$bin" bash "$mig") >/dev/null
  assert_contains "the option is on where launchers kept the Mac awake" 'CLAUDE_PANEL_CAFFEINATE=true' "$(cat "$f")"
  assert_contains "other options are untouched" 'CLAUDE_PANEL_ALERTS=true' "$(cat "$f")"
  assert_contains "the comment says what it now covers" 'while a session runs' "$(cat "$f")"
  printf 'CLAUDE_PANEL_CAFFEINATE=false\n' > "$f"
  (PANEL_OPTIONS="$f" BIN_DIR="$bin" bash "$mig") >/dev/null
  assert_eq "turned off afterwards, it stays off" "CLAUDE_PANEL_CAFFEINATE=false" "$(cat "$f")"

  # Typed sessions: the ~/.zshrc wrapper.
  command -v zsh >/dev/null 2>&1 || { assert_eq "zsh available" "skip" "skip"; return 0; }
  awk '/<<.ZSHRC_EOF/{on=1;next} /^ZSHRC_EOF$/{on=0} on' "$setup" > "$SBX/zblock"
  printf '#!/bin/bash\necho "caffeinate $*" >> "%s"\nexec sleep 30\n' "$SBX/awake.log" > "$stub/caffeinate"
  # The session outlasts caffeinate's start, as a real one does.
  printf '#!/bin/bash\necho "claude $*" >> "%s"\nsleep 0.5\nexit 7\n' "$SBX/awake.log" > "$stub/claude"
  typed() { # $@ = claude's arguments; prints the exit status, then what ran
    : > "$SBX/awake.log"
    ( cd "$SBX" && PATH="$stub:$PATH" zsh -f -c 'source "$1" 2>/dev/null; shift; claude "$@"; print -r -- "rc=$?"; sleep 0.3' _ "$SBX/zblock" "$@" ) 2>&1
    sed 's/ -w [0-9]*$/ -w PID/' "$SBX/awake.log" | sort | tr '\n' ';'
  }
  printf 'CLAUDE_PANEL_CAFFEINATE=true\n' > "$f"
  assert_eq "a typed session is kept awake, and its exit status kept" "rc=7caffeinate -i -w PID;claude ;" "$(typed | tr -d '\n')"
  assert_eq "nothing is left keeping the Mac awake afterwards" "0" "$(pgrep -f "$stub/caffeinate" | wc -l | tr -d ' ')"
  printf 'CLAUDE_PANEL_CAFFEINATE=true\nCLAUDE_PANEL_KEEP_SCREEN_ON=true\n' > "$f"
  assert_contains "the screen option reaches a typed session" "caffeinate -di -w PID" "$(typed)"
  assert_not_contains "a one-shot -p is not kept awake" "caffeinate" "$(typed -p hello)"
  assert_not_contains "a subcommand is not kept awake" "caffeinate" "$(typed mcp list)"
  printf 'CLAUDE_PANEL_CAFFEINATE=false\nCLAUDE_PANEL_KEEP_SCREEN_ON=true\n' > "$f"
  assert_not_contains "off, a typed session is started as it is" "caffeinate" "$(typed)"
}
