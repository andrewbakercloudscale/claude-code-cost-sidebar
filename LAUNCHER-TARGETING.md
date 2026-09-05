# claude-panel-launch.sh: which window gets the panel

Written 2026-09-05, after a launcher change of mine put six cost panels into
a window the user was working in. This is the record of what the launcher
actually does, what broke, what is deployed now, and the one open question.

## State as of 2026-09-05, 16:05

| | |
|---|---|
| Deployed launcher | `fa3dd2f` — positive-identification guard, fails safe |
| Symptom before | new windows opened with no panel, whenever a second Ghostty was alive |
| Symptom now | should be fixed; **not yet confirmed by the user in normal use** |
| Known remaining risk | a genuinely ambiguous focus state still skips, so a window can still come up without a panel — by design, see "Why skipping is right" |
| Open question | can keystrokes be delivered to a **non-focused** window (`CGEventPostToPid`)? **Untested** — see "The open question" |

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
equivalent (see "The open question").

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
15:47:04 ... PWD=/Users/…/hamadi-labs-audit
15:47:09 attempt 1: VERIFIED — new panel process(es): 44768 45371 45442 45443 45475 45485
15:47:11 start: … PWD=/Users/…/wordpress-seo-ai-optimizer PIN_SID=none
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

## The open question: keystrokes to a non-focused window

If keystrokes could be delivered to a specific window regardless of focus,
this entire class disappears — no guard, no skip, no possibility of typing
into the wrong place.

What is established:

| Route | Verdict |
|---|---|
| `System Events` `keystroke` | **No.** Focus-based by design, no targeting. |
| Ghostty CLI | **No.** 1.3.1 has `+new-window` but no `+new-split` — checked `+list-actions`. |
| `CGEventPostToPid` | **Unknown — worth testing.** |

`CGEventPostToPid` posts an event to a specific **process**. Because each
Ghostty window here is its own process, and the launcher already resolves
that pid by ancestry, it maps exactly onto what is needed. pyobjc is present
(`/opt/homebrew/bin/python3 -c "import Quartz"`), so it is reachable without
new dependencies.

**It has not been tested.** I tried; the throwaway probe window kept exiting
before the control case ran, so both the focused and the background test
returned empty. That is a broken harness, not a result — do not read it as
"it does not work". The control case has to pass before the background case
means anything.

The real caveat to settle: many macOS apps ignore synthesised key events
while not the active app. Ghostty may be one of them.

**Fastest way to get a yes/no:** Hammerspoon is installed and running on this
machine, and `hs.eventtap.keyStroke(mods, key, delay, app)` wraps this same
API. Try that before writing any python.

If it works, `fa3dd2f`'s guard becomes unnecessary rather than merely
careful, and the launcher stops depending on focus at all — the same property
the tmux path already has.

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
