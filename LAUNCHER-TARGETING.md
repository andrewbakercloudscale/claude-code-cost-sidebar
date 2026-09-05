# claude-panel-launch.sh: which window gets the panel

Written 2026-09-05, after a launcher change of mine put six cost panels into
a window the user was working in. This is the record of what the launcher
actually does, what broke, what is deployed now, and the answer to the question
that would make all of it unnecessary.

## State as of 2026-09-05, 16:30

| | |
|---|---|
| Deployed launcher | `fa3dd2f` — positive-identification guard, fails safe |
| Symptom before | new windows opened with no panel, whenever a second Ghostty was alive |
| Symptom now | should be fixed; **not yet confirmed by the user in normal use** |
| Known remaining risk | a genuinely ambiguous focus state still skips, so a window can still come up without a panel — by design, see "Why skipping is right" |
| Answered and shipped 2026-09-05 | keystrokes are now addressed to our process by pid, so focus is irrelevant. The focus-dependent path remains as the fallback where pyobjc is absent. |

Commits, in order: `75374c1` (my bad fix) → `af1e67e` (revert) → `fa3dd2f`
(the guard that shipped). `75374c1` is in history and **must not be
reapplied**; the revert explains why and so does this file.

## The thing to understand first

**The panel is not bound to the terminal process. Nothing binds it.**

This is the question the user asked — "surely they are bound to the
process?" — and the answer is no, in a way that explains every bug below.

The launcher has no IPC with Ghostty. It drives the GUI: it presses `cmd+d`
to split the window, *types* the panel command as literal keystrokes, presses
Return, then sends `ctrl+shift+h`/`ctrl+shift+l` to resize the split. That is
the whole mechanism.

And `System Events`' `keystroke` goes to **whatever window currently holds
keyboard focus, system-wide**. Wrapping it in `tell <application process>`
does not redirect it — the enclosing `tell` names a process for the
*attribute* reads (window size, window count), not for the keystrokes. The
launcher's own comment has said this the whole time:

> System Events delivers `keystroke` to whatever application is frontmost,
> not to the process an enclosing `tell` names, so targeting the right
> instance and typing into the right window are one and the same
> requirement.

So "which window gets the panel" is decided entirely by which window has
focus at the instant the keystrokes are sent. Every check in this script
exists to answer one question — *is the focused window ours?* — and to
refuse to type when it cannot say yes.

There is a second path, and it is the one that has none of these problems:
inside tmux the launcher uses `tmux split-window`, a real API, no focus, no
keystrokes. The Ghostty path is the way it is because Ghostty offers no
equivalent through its CLI — though it turns out there is another way in, see
"The open question, answered".

## Why there are several Ghostty processes at all

Not incidental — it is the root of the whole class. Each Finder-Service /
`ghostty-claude-launcher` launch runs `Ghostty.app/Contents/MacOS/ghostty`
directly, which starts a **new app instance**, not a new window in the
existing one. So several processes named `ghostty` coexist routinely, one per
launched window, plus any whose window was closed while a child shell kept
the process alive.

The launcher finds its own by walking process ancestry (`ghostty → login →
shell → here`), which is reliable. Deciding which one is *focused* is not.

## The bug: `first ... whose frontmost is true` picks the wrong instance

Two log lines a second apart, asking the identical question, disagreeing:

```
attempt 1: frontmost confirmed (pid 37092) after 1 poll(s)
attempt 1: osascript exit=0 result=skip: frontmost is ghostty pid 87107,
           not our ghostty instance 37092
```

`first application process whose frontmost is true` returns whichever match
comes first in System Events' own process order. With one Ghostty that is
unambiguous. With several it can hand back an **older** instance rather than
the focused one — 87107 here was 46 minutes older than 37092.

Result: every new window opened while a second Ghostty was alive got skipped,
three attempts out of three, and came up with no panel. It looked
intermittent because with a single Ghostty running there is no older instance
to be confused with.

## The regression I shipped, and what it cost

`75374c1` "fixed" this by replacing the check with: force our instance
frontmost, then read back the flag we just set. That flag is nearly always
true immediately after setting it, so **the guard stopped guarding**.

The keystrokes then went where they always go — the genuinely focused window,
which was the user's. And because the typed text lands in a shell that runs
the `~/.zshrc` autolaunch hook, it recursed:

```
15:47:04 ... PWD=/Users/…/<project-a>
15:47:09 attempt 1: VERIFIED — new panel process(es): 44768 45371 45442 45443 45475 45485
15:47:11 start: … PWD=/Users/…/<project-b> PIN_SID=none
15:47:16 attempt 1: VERIFIED — new panel process(es): 45887
```

Six panels from one launch, then a second launcher run seven seconds later,
all in the wrong window. Reverted in `af1e67e`.

**The lesson is not "be careful".** It is that the guard's failure modes are
wildly asymmetric, and I traded the cheap one for the expensive one while
quoting, in my own commit message, the comment that says exactly why not.

## Why skipping is right

- **Skip is a missing panel.** Annoying, visible, trivially recoverable — run
  `~/.local/bin/ccusage-panel.sh` in a split by hand.
- **Proceed-on-a-bad-guess types a shell command into whatever the user is
  doing.** In a live Claude Code pane that is text in their prompt; in a
  shell it executes; and here it re-triggered the launcher and multiplied.

So the guard must be biased hard toward skipping, and any future change to it
has to be evaluated on *that* asymmetry, not on how often it produces a
panel.

## What is deployed now (`fa3dd2f`)

Ask each Ghostty directly instead of asking the list who is first. Proceed
only when **exactly one** claims frontmost **and it is ours**. Anything else
skips — and logs the full per-instance picture, because "which of these cases
is it" was precisely what the old one-line message could not answer:

```
skip: focused ghostty is pid 97891, not our instance 87107 --
      87107(front=false,win=1) 97891(front=true,win=1) 29470(front=false,win=1)
```

This is strictly **tighter** than the original check, never looser. It cannot
type into a window it has not positively identified.

Verified both directions against three live instances:

- **Not ours** → skips with the diagnostic above and types nothing. Checked
  by substituting a marker string for the panel command and confirming the
  marker appeared in no window.
- **Ours** → proceeds, and the new panel process's own ancestry confirms it
  landed in the *targeted* window (97891) rather than in the focused one by
  luck.

Not verified: normal day-to-day use. The user had not yet opened fresh
windows in anger when the session ended. **First thing to check next
session.**

## The open question, answered: yes

**Tested 2026-09-05. Keystrokes can be delivered to a specific, non-focused
window, and the full launcher operation works that way.**

| Route | Verdict |
|---|---|
| `System Events` `keystroke` | **No.** Focus-based by design, no targeting. This is what the whole guard exists to work around. |
| Ghostty CLI | **No.** 1.3.1 has `+new-window` but no `+new-split` — checked `+list-actions`. |
| `CGEventPostToPid` | **Yes.** Verified end to end. |

`CGEventPostToPid` posts an event to a specific **process**. Each Ghostty
window here is its own process, and the launcher already resolves that pid by
ancestry, so it maps exactly onto what is needed.

Driven through Hammerspoon (`hs.eventtap`, which wraps that API) because it
is already installed here and reachable via `osascript -e 'tell application
"Hammerspoon" to execute lua code "..."'` — no config change, no `hs.ipc`, no
new dependency needed for the test itself.

### What was measured

A throwaway Ghostty instance, focus deliberately held on an unrelated window
throughout, verified before and after each step:

1. **Plain text.** `hs.eventtap.keyStrokes(text, app)` typed a command into
   the unfocused probe. It ran. Focus never moved.
2. **The `cmd+d` chord.** Sent alone, to the unfocused probe. Focus never
   moved; the probe gained a second shell child, so the split happened.
3. **The whole sequence** — split, type the panel command, Return. A panel
   process appeared, and its own process ancestry places it in the **probe's**
   Ghostty, not in the focused one. Focus stayed on the unrelated window
   before and after.

An earlier attempt at this via pyobjc returned empty for both the focused and
the background case and is recorded above as *untested* rather than negative.
It was a broken harness: the probe window was launched with `-e "bash -c 'cat
> file'"` and exited immediately, so the events were posted to a dead pid.
The fix was a probe running an ordinary interactive shell, which persists.
**The control case has to pass before the background case means anything** —
the first three attempts here all failed that way.

### Why this matters more than "one fewer skip"

It removes the failure class rather than managing it. Events addressed to a
pid cannot land in the wrong window **no matter what focus is doing**, so:

- The whole positive-identification guard becomes unnecessary rather than
  merely careful.
- The six-panels-in-the-wrong-window incident becomes structurally
  impossible, not just guarded against.
- Windows stop being skipped, because there is nothing left to be ambiguous
  about.

It is the same property the tmux path already has, which is why that path has
never produced a bug of this kind.

### Shipped: targeted first, focus-dependent as the fallback

`claude-panel-keysend` (installed alongside the launcher) posts the whole
sequence — split, type, Return, resize — to one pid via `CGEventPostToPid`.
The launcher tries it first and keeps the AppleScript path underneath.

The fallback is not hedging. pyobjc's Quartz bindings are **not** on stock
macOS — `/usr/bin/python3` does not have them, a Homebrew python usually does
— and this repo is public, so a hard dependency would simply stop the panel
working for anyone without them. Where the bindings exist this is strictly an
upgrade; where they do not, nothing changes.

| | targeted path | fallback path |
|---|---|---|
| Requires | a python3 with pyobjc | nothing new |
| Addresses | our process, by pid | whatever holds focus |
| Can type into the wrong window | **no, structurally** | only if the guard is wrong |
| Needs the frontmost guard | no | yes |
| Needs the keyboard guard | no — events are addressed, not broadcast | yes |
| Steals focus | no | yes, it raises our window |

Window geometry still comes from System Events on both paths: reading a
window's size does not require it to be focused, only typing into it does.

**Verified end to end, in the shape that used to fail** — a new window while
another Ghostty held focus:

```
attempt 1: targeted send to pid 81119 (width=1255 presses=5) via /opt/homebrew/bin/python3
attempt 1: VERIFIED — new panel process(es): 82089
done: succeeded on attempt 1/3
```

Focus was on an unrelated window before and after, and panel 82089's own
process ancestry places it in ghostty 81119 — the target. The fallback was
then exercised deliberately (`PANEL_KEYSEND_PYTHON=/usr/bin/python3`, an
interpreter with no pyobjc) and logged `no python3 with pyobjc's Quartz
bindings — using the focus-dependent AppleScript path`, then succeeded on
attempt 1/3 the old way.

### Why `PANEL_KEYSEND_PYTHON` is authoritative

If it were merely first in the search order it could not turn the targeted
path **off** — the search would find Homebrew's python anyway. The fallback
would then be unreachable on every machine that has pyobjc, which is every
machine this was developed on, and it would rot without anyone finding out.
Set it and the search stops there, so the fallback stays exercisable.

### Tests

`tests/launcher/run-tests.sh` — 2 checks, 16 assertions, deliberately narrow.
Driving Ghostty through the Accessibility API is not something a hermetic
check can do, so what is covered is the decision about **which path runs**
plus the helper's exit-code contract with the launcher (2 = no pyobjc, fall
through; 64 = the launcher called it wrong, which must not be confused with
the first). Whether keystrokes actually arrive was verified by hand, above,
because faking a window would only assert the fake.

Writing it turned up a bug in its own runner: `source "$HERE"/checks/*.sh`
sources only the FIRST match and passes the rest as positional arguments, so
one of two checks silently did not run while the header announced two. All
three runners now compare check *files* against loaded check *functions* and
refuse to run if they disagree.

## Debugging notes for next time

- The log is `~/.cache/claude-panel-launch.log`, one line per step, prefixed
  with a shared run id so concurrent window opens do not interleave.
  `tail -50` it first; it answers most questions without any guessing.
- The launcher already verifies success by ground truth (a new panel
  *process* appeared), not by AppleScript's exit code, which is 0 even when
  an internal `return` meant nothing happened. Trust that line, not `ok:`.
- To test the AppleScript alone, without the shell-side raise pulling your
  own window forward, extract the heredoc and run it with `TARGET_PID`
  substituted. **Substitute a marker string for the panel command** — then a
  guard that wrongly proceeds is visible as text somewhere instead of as a
  new panel you have to hunt down.
- Ancestry (`ghostty → login → shell`) is the reliable way to know which
  instance is ours. Focus is not. Do not conflate them.
