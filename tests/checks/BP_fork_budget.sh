# Check BP -- how many processes the panels start, counted, not guessed.
#
# v1.21.7 counted the external commands a tick ran (about 6) and missed the
# forks: every $(...), pipeline, ( ) and <(...) is a process start to the
# kernel too, and System Sentinel still saw about 290 a ten-second tick from
# ten panels. This check counts what the kernel counts: a small library,
# loaded into every bash the panels run (DYLD_INSERT_LIBRARIES), logs each
# fork and posix_spawn. Two headless panels, one on screen and one not, and
# the collector they start, run at a 2 second tick; once settled, five ticks
# are counted:
#   - the panel on screen starts one process a tick, the python that writes
#     its mod/<id>.json (allowed two, for a tick landing at the window edge);
#   - the panel out of view starts none;
#   - the collector, with no gateway and no block here, next to none.
# Needs clang (the installer builds its helpers with it) and a bash that is
# not SIP-protected, as Homebrew's is; the check proves the counter counts
# before it believes a zero.
bp_wait() { # $1 = condition; up to 30s
  local i
  for (( i = 0; i < 150; i++ )); do
    eval "$1" && return 0
    sleep 0.2
  done
  return 1
}
check_BP_fork_budget() {
  sandbox_new BP
  load_panel 2 12 ""
  local lib="$SBX/forkcount.dylib" log="$SBX/forks.log" bash_bin a b pa pb sids line n
  # Paths of its own, so the check also runs (and fails) against a panel
  # from before the collector.
  local cdir="$HOME/.cache/ccusage-panel-cache/collector"
  bash_bin=$(command -v bash)
  cat > "$SBX/forkcount.c" <<'BP_C'
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <spawn.h>
#define INTERPOSE(r, f) __attribute__((used)) static struct { const void *a; const void *b; } \
  _i_##f __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&r, (const void *)(unsigned long)&f };
static void logit(const char *k) {
  const char *p = getenv("FORKCOUNT_LOG"); if (!p) return;
  int fd = open(p, O_WRONLY | O_APPEND | O_CREAT, 0600); if (fd < 0) return;
  char b[64]; int n = snprintf(b, sizeof b, "%s %d\n", k, getpid());
  if (n > 0) write(fd, b, n); close(fd);
}
pid_t my_fork(void) { pid_t r = fork(); if (r > 0) logit("fork"); return r; }
int my_spawn(pid_t *p, const char *f, const posix_spawn_file_actions_t *a, const posix_spawnattr_t *t, char *const v[], char *const e[]) { logit("spawn"); return posix_spawn(p, f, a, t, v, e); }
int my_spawnp(pid_t *p, const char *f, const posix_spawn_file_actions_t *a, const posix_spawnattr_t *t, char *const v[], char *const e[]) { logit("spawn"); return posix_spawnp(p, f, a, t, v, e); }
INTERPOSE(my_fork, fork)
INTERPOSE(my_spawn, posix_spawn)
INTERPOSE(my_spawnp, posix_spawnp)
BP_C
  if ! clang -dynamiclib -o "$lib" "$SBX/forkcount.c" 2>"$SBX/clang.err"; then
    _fail "the fork counter builds (clang)" "built" "$(head -3 "$SBX/clang.err")"
    return 0
  fi
  : > "$log"
  FORKCOUNT_LOG=$log DYLD_INSERT_LIBRARIES=$lib "$bash_bin" -c '( : ); x=$(echo y)' >/dev/null 2>&1
  assert_eq "the counter counts (a subshell and a \$(...) are two forks)" 2 "$(grep -c '^fork ' "$log")"

  a="0bfbfb00-0000-4000-8000-00000000000a" b="0bfbfb00-0000-4000-8000-00000000000b"
  mkdir -p "$HOME/.claude/projects/-bp" "$MOD_DIR"
  for sids in "$a" "$b"; do
    printf '%s\n' '{"type":"assistant","timestamp":"2026-11-17T10:00:00.000Z","cwd":"/bp","entrypoint":"cli","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}}}' \
      > "$HOME/.claude/projects/-bp/$sids.jsonl"
    touch "$MOD_DIR/$sids.alive"
  done
  mkdir -p "$HOME/.local/state/ghostty-dock"
  local vis="$HOME/.local/state/ghostty-dock/visible"
  printf '%s\n' "$a" > "$vis"
  : > "$log"
  bp_start() { # $1 = session id
    ( cd /tmp && PANEL_HEADLESS=1 CLAUDE_PANEL_GHOSTTY_PID=0 SLOW_REFRESH=600 \
        PANEL_BG_WRITE_SECS=600 PANEL_BG_SLOW_SECS=600 DOCK_VISIBLE_FILE="$vis" \
        FORKCOUNT_LOG=$log DYLD_INSERT_LIBRARIES=$lib \
        exec "$bash_bin" "$PANEL_SH" 2 12 "$1" </dev/null >/dev/null 2>"$SBX/panel-$1.err" ) &
  }
  bp_start "$a"; pa=$!
  bp_start "$b"; pb=$!
  bp_keep() { touch "$MOD_DIR/$a.alive" "$MOD_DIR/$b.alive" "$vis"; }
  bp_wait 'bp_keep; [ -s "$MOD_DIR/$a.json" ] && [ -s "$MOD_DIR/$b.json" ] && [ -s "$cdir/state.sh" ]' \
    && _pass || _fail "both panels and the collector are up" "mod json x2 and state.sh" "$(ls "$MOD_DIR" "$cdir" 2>&1 | tr '\n' ' ')"
  # Settled: the first slow tick and the collector's first slow job behind.
  local i
  for (( i = 0; i < 15; i++ )); do bp_keep; sleep 0.4; done
  n=$(wc -l < "$log" | tr -d ' ')
  for (( i = 0; i < 25; i++ )); do bp_keep; sleep 0.4; done
  local by_a=0 by_b=0 by_rest=0 who
  while read -r line who; do
    case "$who" in
      "$pa") by_a=$(( by_a + 1 )) ;;
      "$pb") by_b=$(( by_b + 1 )) ;;
      *) by_rest=$(( by_rest + 1 )) ;;
    esac
  done < <(tail -n +"$(( n + 1 ))" "$log")
  kill "$pa" "$pb" 2>/dev/null; wait "$pa" "$pb" 2>/dev/null
  local cpid=""
  { IFS= read -r cpid < "$cdir/lock/pid"; } 2>/dev/null
  [ -n "$cpid" ] && kill "$cpid" 2>/dev/null
  printf '    (10s at a 2s tick: on screen %d, out of view %d, collector and the rest %d)\n' "$by_a" "$by_b" "$by_rest" >&2
  (( by_a >= 3 && by_a <= 10 )) && _pass || _fail "the panel on screen: its python a tick, no more" "3 to 10 in five ticks" "$by_a"
  (( by_b <= 1 )) && _pass || _fail "the panel out of view starts nothing" "at most 1" "$by_b"
  (( by_rest <= 5 )) && _pass || _fail "the collector, with nothing to fetch, next to nothing" "at most 5" "$by_rest"
  assert_eq "the panel on screen wrote nothing to stderr" "" "$(cat "$SBX/panel-$a.err")"
  assert_eq "nor the one out of view" "" "$(cat "$SBX/panel-$b.err")"
  return 0
}
