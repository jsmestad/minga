# Surfaces

The resting screen has three parts: a plain title bar, your text, and the modeline. Everything else is a buffer that appears when you ask for it, in a bottom drawer or a split, and goes away with `q` or `esc`. The same surfaces exist on macOS and in the TUI; [tui.md](tui.md) covers how the terminal draws them.

## Title bar

Traffic lights, the small `minga` wordmark, and the centred file name with its path in a secondary colour. Nothing else: no capsule, no buttons, no tabs.

## Modeline

The modeline is the spine. It is the one place state is always visible.

**Order, left to right:**

1. Mode pill (NORMAL, INSERT, VISUAL, TERM, ...). One style everywhere: inset and rounded.
2. Needs-you, only when non-zero, right next to the mode pill, shown once and without a key hint.
3. File, with a dot when unsaved.
4. Change position, only when the cursor is inside one of Minga's changes: "change 1/2".
5. Git branch and change count: "main +11".
6. Minga: the state glyph and words. "Minga here 2/3" when Minga is working in this file, otherwise "Minga editing retry.ex 2/3".
7. Diagnostics: error and warning marks with counts, the error count in red.
8. Filetype.
9. Position, always as `240:31`.

**Truncation**, dropped first to last when the window narrows: filetype, position, git, then Minga's words down to the glyph and "2/3". Never dropped: mode, needs-you, the file name, diagnostics with errors.

**Accessibility.** Each segment is an accessibility element with a label and an action, for example "1 task needs you. Press SPC a a." VoiceOver announces only when needs-you goes from zero to non-zero.

The resting modeline shows no key hints. Clicking any segment does what its key does.

## Which-key

Pause after `SPC`, or any prefix, and which-key opens as one panel anchored above the modeline.

- A breadcrumb in the panel's border: `SPC › a  Minga`.
- Groups in columns, each column as wide as its longest entry, names dim above each column, rows single-spaced, no rules. The panel is only as tall as its longest group.
- Each entry is `key  Label`, with live counts where they matter ("Tasks · 1 needs you", "Review · 3", "Attach diagnostics · 1 error"). Counts update while the panel is open.
- The ⌘ equivalent appears beside an entry when one exists, so the menu bar and the leader teach each other.
- Timing: appears after the pause (`timeoutlen`), fades in within 120 ms, no fade with Reduce Motion, and never paints a frame if you type through the sequence.

## Drawers

Lists open in a bottom drawer: the tasks list, the review, diagnostics, the switcher and the terminal. A drawer is a real split of the window, not an overlay that hides code.

- 1 pt divider with a 5 pt hit area; height remembered per kind of buffer; double-click the divider to reset to 40%.
- The header carries the title and the drawer's key hints. There is no second hint line above the modeline.
- `esc` leaves a filter first, then closes. `q` closes. ⌘W closes the focused drawer. Focus returns to the window you came from.
- When a drawer opens on its own (for example from a notification), single-letter actions are ignored for 300 ms, so a letter you were typing cannot approve something.
- Selection uses the system accent while the list is focused, grey when it is not.

## Tasks

`SPC a a` opens `*minga-tasks*`. Rows are ordered needs-you first.

- Each row: the state glyph, the task's goal as its title, state words ("Editing chrome_state.ex · step 2 of 3", "Waiting · rate limited, retry in 40 s"), and its age.
- The header counts each state.
- The row that needs you expands to show the request ("Create test/minga_agent/usage_limit_test.exs +86") and its actions as text: "`y` Approve once  `a` Always for this session  `t` This turn  `n` Deny  `=` Show diff  `↩` Open conversation".
- Every other row shows its one relevant action: `r` Retry on waiting and failed rows, `o` Output, `i` Inspect, `↩` Review on done rows.
- A task that fans out shows its subagents beneath it as a tree (`├─`, `└─`), each with its state.
- Empty state: still to be designed (see ADR-0006 open questions).

## Review

Two ways to review, for two situations.

**In the file**, while you are working. The twist marks each change. `]h` moves between changes, `vah` selects one, `SPC g k` keeps and `SPC g r` rejects at the cursor or across a selection, `.` repeats, and `:'<,'>Minga keep` works on ranges. The modeline shows "change 1/2" while the cursor is inside a change. Clicking the twist head opens Keep, Reject, Show Diff and Open Conversation. If an unreviewed change still has an error, keeping it asks for confirmation.

**In `*minga-review*`**, when Minga is done and you want to go through everything. `SPC a r` opens it beside the file:

- The task with its state and summary ("Done 3 min ago · 3 files · +40 −12").
- "Unreviewed" and "Kept" sections as a tree of files and changes, each change described in words ("@@ 231 replaced 1 line with 3").
- Keys in the header: `y` keep, `n` reject, `=` diff, `Y` keep all, `]h` next, `↩` go to, `q` close.
- `:Minga review` also fills the quickfix list with unreviewed changes, so `]q` and `:cdo` work.

## Conversation and composer

`SPC a v` opens the conversation as a split buffer. Messages are calm: a speaker label in its colour ("You" in blue, "Minga" in purple) above plain text, no bubbles. Tool steps are one sentence each with a state glyph ("Read native.ex and found where 429s are classified", "Test run failed · 1 failure"). The header shows the task's goal, its state and time, and the model.

The composer is a real buffer. It starts in Insert; `↩` is a newline in Insert; Normal-mode `↩` or ⌘↩ sends (steering while Minga works); `⌥↩` queues the next message; ⌘. stops. Its key hints appear only while it has focus. Queued messages live in `*minga-queue*`, an editable buffer where `dd` and `p` reorder them.

## Switcher

`SPC ,` (or `SPC b b`) opens a drawer with a prompt at the top: "Find file ›". You type into the prompt, so actions use control keys (see [keys](keys.md#file-switcher-spc-)).

Sections:

- **Pinned**: up to four files, numbered for `SPC 1` to `SPC 4` and ⌘1 to ⌘4.
- **Changed**: your unsaved files with a blue dot; Minga's changes grouped under their task, with its state and the small twist mark.
- **Recent**: by last visit.
- **Terminals**: each with its cwd and last state.

Files never need closing; only unsaved or unreviewed work is called out. Back and forward are ⌃⌘← and ⌃⌘→ on macOS, or a trackpad swipe.

## Diagnostics

See [marks](marks.md#diagnostics) for underlines and signs.

- Only the cursor line shows its message, as quiet italic text after the code.
- Hover the underline or press `K` for a popover: severity, message, source, and "Fix", "Ask Minga to Fix", "Copy".
- `]d` and `[d` move between diagnostics; `SPC c a` lists code actions; `SPC c d` opens the list as a buffer.
- The modeline shows counts only when there is something to report.
- If a change Minga is making produces an error, Minga fixes it as part of its work and says so in a tool step.

## Subagent peek

When a task fans out into subagents, each subagent can be inspected without leaving the parent conversation. `SPC a i`, or `↩` on a "Started ◐ Fact-Check Auditor" line, opens the subagent as a split on the right:

- **Header**: breadcrumb (parent task › subagent), its state and time ("Done · worked 3m"), and a sibling strip of glyphs ("◐ ◐ ● ◐  3 of 4"). `]t` and `[t` step through siblings in place; each glyph is clickable.
- **Brief**: what the parent asked, folded by default (`za`).
- **So far**: live activity as sentences with state glyphs.
- **Result**: what it handed back to the parent.
- **Composer**: "Message this subagent".

The parent conversation reports progress as tool-step lines ("1 of 4 reports in"). There is no permanent third column of siblings; the full list is the tasks drawer's tree, one key away.

## Notifications and background

Only needs-you escalates, and nothing steals focus.

- In the app: the needs-you segment in the modeline.
- macOS in the background: a Dock badge with the needs-you count, one informational bounce, and a time-sensitive notification with "Approve once" and "Deny" for low-risk requests. Clicking it opens the tasks drawer on that task.
- Terminal: see [tui.md](tui.md#terminal-capabilities) for notifications from inside the terminal, the tab title and the tab progress bar.
- An approval answered in one place shows "Already answered in Minga" everywhere else.
