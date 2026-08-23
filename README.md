# AI Agent Cost & Usage Panel

Live, always-visible cost and token tracking for **Claude Code** and **OpenCode**, running in a right-hand [Ghostty](https://ghostty.org/) split next to your terminal session — so you can watch what a coding agent is actually costing you, turn by turn, instead of finding out at the end of the month.

This came out of a simple problem: AI coding agents burn tokens and money per turn, per session, per day — and none of that is visible while you're working. You only find out later, from a dashboard or an invoice, by which point the expensive session is long over and you've learned nothing you can act on. This repo is the fix: a live panel that sits next to your terminal and updates every few seconds.

Full write-up and motivation: **[AI coding costs are guesswork without this: instrumenting OpenCode and Claude Code](https://andrewbaker.ninja/2026/08/22/ai-coding-costs-are-guesswork-without-this-instrumenting-opencode-and-claude-code/)**

## What you get

Two independent installers, one per agent. Run either or both.

### `claude-panel-setup.sh`

Installs a live panel for [Claude Code](https://claude.com/claude-code), built on top of [`ccusage`](https://github.com/ryoppippi/ccusage):

- **Per-turn breakdown of the current session** — turn number, model, context size, context growth (Δ) since the last turn, cache hit %, and estimated cost per turn, read straight out of the session transcript and priced against Anthropic's published per-model rates (including cache read/write multipliers).
- **Live status line** — current session cost, today's spend, active-block burn rate, 7-day average session cost, 30-day spend, and the current project folder.
- **Active block** — start/end time, spend so far, burn rate ($/hr and tokens/min, color-coded green/yellow/red), and a projected total for the block.
- **Today** — total cost/tokens, input/output split, cache new/read split, and a per-model breakdown.
- **Last 3 days** — a simple cost bar chart.
- **Week / month totals.**
- **Top 5 sessions today** by cost.

Everything through the per-turn table is always shown in full; sections below it fill whatever pane height is left, so a short split never truncates the part you actually care about.

Also installs a **cost-alert hook** (`claude-cost-alert-check.sh`, wired into Claude Code's `UserPromptSubmit` hook) that posts a warning *into the chat itself* — so it works over Remote Control too, not just locally — when the current session's cost crosses 2x (red) or 3x (purple) your 7-day average session cost, or when the panel failed to auto-launch for this window.

### `opencode-panel-setup.sh`

Same idea for [OpenCode](https://opencode.ai/):

- **Per-turn breakdown** — turn, provider/model, context size, Δ cache write, cache hit %, cost — parsed from `opencode export <session>`.
- **7-day average session cost** baseline, from `opencode session list --format json`.
- **Today / last 7 days**, shown via OpenCode's own `opencode stats` output (deliberately *not* reparsed as JSON — see the note in the script header about why `opencode stats --json`'s shape isn't stable enough to trust yet).

### Shared behaviour (both installers)

- **Auto-launch on first use per window.** A `preexec` hook in `~/.zshrc` watches for the first `claude...` / `opencode...` command typed in a terminal window and opens the panel automatically in a right-hand Ghostty split — you never have to remember to start it.
- **Auto-resize** to roughly 1/3 of the window width via Ghostty keybinds (`ctrl+shift+h` / `ctrl+shift+l`, added to `~/.config/ghostty/config` if missing), then focus returns to your original pane.
- **Verified, not assumed.** The launcher drives Ghostty via `osascript`/System Events, retries up to 3 times, and confirms success by checking that a new panel *process* actually exists — not just that AppleScript returned exit code 0, which it will happily do even when nothing happened.
- **Logged.** Every launch attempt is logged with a shared run ID (`~/.cache/claude-panel-launch.log` / `~/.cache/opencode-panel-launch.log`) so a failed auto-launch is diagnosable instead of just silently missing.
- **Idempotent.** Safe to re-run any time — it overwrites the two generated scripts with the latest version and skips any `.zshrc`/config block that's already present.
- **Finder Service aware.** If you launch Claude Code via a Finder Service / Automator workflow (`ghostty-claude-launcher`) rather than an interactive shell, the Claude installer patches that script too, since the `preexec` hook never fires for it.

## How it works

Both installers follow the same shape: a **panel script** (the thing that renders live stats in a loop) and a **launcher script** (the thing that opens a Ghostty split and starts the panel in it), plus a small `~/.zshrc` hook that fires the launcher automatically. A few decisions in there aren't obvious from the code alone:

- **Per-turn cost isn't available from either agent's own tooling, so both panels compute it themselves.** `ccusage` and `opencode stats` only expose session/day/block-level totals, not a per-message figure. Both panels instead read the raw session transcript directly (Claude Code's `~/.claude/projects/*/*.jsonl`, or `opencode export <session>`) and price every assistant turn from its token usage: input, output, cache read, and cache write tokens, each at Anthropic's published per-model rate (cache read at 0.1x the input rate, cache write at 1.25x/2x for 5-minute/1-hour cache). That's what makes the "per turn" table possible — it doesn't exist anywhere else.
- **The context-window math is fragile in a specific way, and the code works around it.** The Claude panel needs the *real* session ID and model ID from the transcript — a placeholder ID silently returns a `$0.00` session cost instead of erroring, and an unset model ID makes `ccusage` assume an old 200k context window instead of Sonnet 5's actual 1M, which makes context usage read as `>100%`. Both failure modes are silent, which is exactly the kind of thing this project exists to prevent, so the panel derives both IDs from the transcript itself rather than trusting a default.
- **Rendering never trusts the pane's current size to stay put.** The panel is meant to sit in a resizable split, so every frame is measured against the *current* terminal width/height (`tput cols`/`tput lines`) rather than a fixed layout, and every printed line is padded with `\033[K` (clear-to-end-of-line) so a shorter new frame can't leave stale characters from a wider previous one ghosting through. The Claude panel goes further: the per-turn table is rendered as a "guaranteed" block that's never truncated, and only the sections below it (active block, today, trends, top sessions) compete for whatever pane height is left — so asking for the last 20 turns always means 20 turns, never "20 turns if there's room."
- **The AppleScript automation verifies itself instead of trusting its own exit code.** Both launcher scripts drive Ghostty via `osascript`/System Events to open a split, type the panel command, and resize the pane. AppleScript will report success (exit 0, no stderr) even when a stale frontmost check or an internal early `return` meant nothing actually happened — so the launcher doesn't believe it. It snapshots running panel processes before the attempt, snapshots them again after, and only calls it a success if a *new* process actually appeared. It retries up to 3 times and logs every attempt (with a shared run ID, so concurrent window opens don't interleave into an unreadable log) to `~/.cache/{claude,opencode}-panel-launch.log`.
- **The cost-alert hook is a second, independent instrumentation path.** `claude-cost-alert-check.sh` hooks into Claude Code's own `UserPromptSubmit` event and posts straight into the chat transcript via `systemMessage` — which is what makes it work over Remote Control, where a local desktop notification wouldn't reach you. It's throttled per session (state kept in `~/.cache/claude-cost-alert-state/<session_id>.json`) so it fires once per tier escalation rather than on every prompt, and it also surfaces launcher failures, so a broken panel doesn't fail silently either.
- **Everything is idempotent by construction.** Each installer checks for its own marker (a comment string in `~/.zshrc`, a `jq` query against `~/.claude/settings.json`, a grep against `~/.config/ghostty/config`) before appending anything, so re-running an installer after a script update never double-installs a hook or duplicates a keybind.

## Requirements

- macOS + [Ghostty](https://ghostty.org/) (for the auto-split part — the panel scripts themselves work in any terminal if you just run them manually)
- `jq`
- Accessibility permission granted to Ghostty (macOS will prompt the first time the launcher tries to drive it via System Events)
- For the Claude Code panel: Node.js (for [`ccusage`](https://github.com/ryoppippi/ccusage)) and Python 3
- For the OpenCode panel: the `opencode` CLI on your `PATH`

## Install

```bash
# Claude Code panel
bash claude-panel-setup.sh

# OpenCode panel
bash opencode-panel-setup.sh
```

Then open a **new** terminal window/tab (or `source ~/.zshrc`) and type a `claude...` or `opencode...` command — the panel opens automatically in a right-hand split.

You can also run either panel manually at any time, in any terminal:

```bash
~/.local/bin/ccusage-panel.sh [refresh_seconds] [turn_rows]
~/.local/bin/opencode-panel.sh [refresh_seconds] [turn_rows]
```

## Troubleshooting

- **Panel never opens automatically** — check `~/.cache/claude-panel-launch.log` or `~/.cache/opencode-panel-launch.log`. The most common cause is Ghostty missing Accessibility permission (System Settings → Privacy & Security → Accessibility).
- **Split opens but stays 50/50** — make sure `~/.config/ghostty/config` has the `resize_split` keybinds the installer adds (`ctrl+shift+h` / `ctrl+shift+l`); if that file didn't exist when you installed, create it and re-run the installer.
- **Context % looks wrong / costs look off** — the Claude panel infers the model ID from the live transcript to price each turn and size the context window correctly; if pricing changes on Anthropic's side, update the `PRICES` table inside `ccusage-panel.sh`.

## License

MIT
