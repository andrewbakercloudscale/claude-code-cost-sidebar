# Check X -- the Proxy State line must distinguish "which slot would be used"
# from "is the proxy in the traffic path at all".
#
# Those two came apart on this machine and the panel could not tell: it read
# the provider out of claude-burst's config.json and printed a green
# "PRIMARY (oauth)" for hours while nothing had ever been enabled and every
# request went straight to Anthropic. Nothing on the line was false; it just
# answered a question nobody was asking. The line now leads with NOT IN USE,
# and this check exists because that regression is invisible -- a green
# PRIMARY looks exactly like a correct green PRIMARY.
#
# The mode matters as much as the verdict: base-url and transparent are in
# the path for completely different reasons (settings.json vs. /etc/hosts +
# CA trust), and transparent's evidence is precisely that settings.json is
# UNSET. A single shared check would report each mode's healthy state as the
# other's failure.
check_X_proxy_state() {
  sandbox_new X
  load_panel 10 12 ""

  local bin="$SBX/bin"
  mkdir -p "$bin" "$HOME/.config/claude-burst" "$HOME/.claude/certs"
  printf '#!/bin/sh\nexit 0\n' > "$bin/claude-burst"
  chmod +x "$bin/claude-burst"
  local saved_path="$PATH"
  PATH="$bin:$PATH"

  local cfg="$HOME/.config/claude-burst/config.json"
  local settings="$HOME/.claude/settings.json"
  local bundle="$HOME/.claude/certs/node-extra-ca-certs.pem"
  local hosts="$SBX/hosts"
  export CLAUDE_BURST_HOSTS_FILE="$hosts"

  write_cfg() { # $1 = mode
    cat > "$cfg" <<CFG
{"listen":"127.0.0.1:7777",
 "primary":{"provider":"oauth-passthrough"},
 "secondary":{"provider":"openai-compatible"},
 "intercept":{"mode":"$1","host":"api.anthropic.com","ca_bundle":"$bundle"}}
CFG
  }

  # ---- base-url ---------------------------------------------------------
  write_cfg base-url
  printf '{}\n' > "$settings"
  assert_contains "base-url with no ANTHROPIC_BASE_URL is NOT IN USE" \
    "NOT IN USE" "$(proxy_state_line)"
  assert_contains "and says which piece is missing" \
    "ANTHROPIC_BASE_URL unset" "$(proxy_state_line)"

  # Pointing somewhere else is not the same as unset, and must not be
  # reported as in-use just because the key exists.
  printf '{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:9999"}}\n' > "$settings"
  assert_contains "a base URL naming another gateway is NOT IN USE" \
    "NOT IN USE" "$(proxy_state_line)"

  printf '{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:7777"}}\n' > "$settings"
  assert_not_contains "base-url pointing at this gateway is in use" \
    "NOT IN USE" "$(proxy_state_line)"
  assert_contains "and reports the routing slot" "PRIMARY" "$(proxy_state_line)"

  # ---- transparent ------------------------------------------------------
  # Transparent mode's whole point is that ANTHROPIC_BASE_URL stays unset
  # (that is what preserves Remote Control), so the base-url evidence must
  # not be applied to it -- doing so would report every correctly installed
  # transparent setup as broken.
  write_cfg transparent
  printf '{}\n' > "$settings"
  : > "$hosts"
  : > "$bundle"
  assert_contains "transparent with no redirect is NOT IN USE" \
    "NOT IN USE" "$(proxy_state_line)"
  assert_contains "and names the missing redirect" \
    "no /etc/hosts redirect" "$(proxy_state_line)"

  # A commented-out entry is the common shape of "used to be installed".
  # Matching the marker or the hostname anywhere in the file would call this
  # installed while the name resolves to the real Anthropic IP.
  printf '# 127.0.0.1 api.anthropic.com\n' > "$hosts"
  assert_contains "a commented-out redirect does not count as installed" \
    "NOT IN USE" "$(proxy_state_line)"

  # Redirect without CA trust is worse than no redirect: traffic arrives
  # here and then fails TLS. It must never read as in-use.
  printf '127.0.0.1 api.anthropic.com\n' > "$hosts"
  assert_contains "redirect without CA trust is NOT IN USE" \
    "NOT IN USE" "$(proxy_state_line)"
  assert_contains "and says TLS is what will fail" \
    "CA untrusted" "$(proxy_state_line)"

  printf '# BEGIN claude-burst CA\nx\n# END claude-burst CA\n' > "$bundle"
  assert_not_contains "redirect plus trusted CA is in use" \
    "NOT IN USE" "$(proxy_state_line)"
  assert_contains "and reports the routing slot" "PRIMARY" "$(proxy_state_line)"

  # The overflow window still shows through once in-path, so this check
  # cannot pass by having flattened the line to one state.
  printf '{"overflow_until":%d}\n' "$(( $(panel_now) + 600 ))" \
    > "$HOME/.config/claude-burst/state.json"
  assert_contains "an active overflow window still reports SECONDARY" \
    "SECONDARY" "$(proxy_state_line)"

  # ---- not installed at all --------------------------------------------
  # Claude Burst is a personal, opt-in proxy; a machine without it must get
  # no row, not a red one. PATH is emptied rather than merely restored --
  # this machine has the real binary in ~/.local/bin, so restoring the
  # normal PATH would find it and the check would silently measure nothing.
  # Nothing else runs before that lookup, so an empty PATH is enough.
  mkdir -p "$SBX/empty"
  PATH="$SBX/empty"
  assert_eq "no claude-burst binary means no row at all" "" "$(proxy_state_line)"
  PATH="$saved_path"

  unset CLAUDE_BURST_HOSTS_FILE
  unset -f write_cfg
}
