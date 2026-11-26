# Surfaces

The resting screen has three parts: a plain title bar, your text, and the modeline. Everything else is a buffer that appears when you ask for it, in a bottom drawer or a split, and goes away with `q` or `esc`. The same surfaces exist on macOS and in the TUI; [tui.md](tui.md) covers how the terminal draws them. This file says what each surface contains and how it behaves; [anatomy.md](anatomy.md) gives every part's measurements in tokens on both frontends.

## Title bar

Traffic lights, the small `minga` wordmark, and the centred file name followed by its project-relative directory in a secondary colour: `retry.ex  lib/minga_agent`. Never the full path after the name, which repeats it. Nothing else: no capsule, no buttons, no tabs.

The title names the focused window, which is what macOS shows in the Window menu, Mission Control and ``⌘` `` switching. The modeline's file segment names the buffer of each split, so with two splits each modeline shows its own file while the title follows the one you are in. Terminal windows show the buffer and its working directory: `*terminal 2*  ~/code/minga`. The TUI has no title bar; the terminal tab title (OSC 2) carries `retry.ex · minga`.

## Modeline

The modeline is the spine. It is the one place state is always visible.

**Order, left to right:**

1. Mode pill (NORMAL, INSERT, VISUAL, TERM, ...). One style everywhere: inset and rounded.
2. Needs-you, only when non-zero, right next to the mode pill, shown once and without a key hint.
3. File, with a dot when unsaved.
4. Change position, only when the cursor is inside one of Minga's changes: "change 1/2".
5. Git branch and change count: "main +11".
6. Minga: the state glyph and words, in regular weight in the state's colour role. "Minga here 2/3" when Minga is working in this file, "Minga editing retry.ex 2/3" when it is working in another, and the state's word when it is not editing a file ("Minga working", "Minga stopped"). When Minga needs you, this segment shows only the needs-you glyph and "Minga" (with "2/3" if there is a plan), because segment 2 already says it; its tooltip says "Minga is waiting for you".
7. Diagnostics: error and warning marks with counts, the error count in the failure role. While a checker is broken, a persistent problem segment takes this slot instead ("elixir-ls failed", "config: defaults"), so a clean count is never shown when nothing is checking.
8. Filetype.
9. Position, always as `240:31`.

**Truncation**, dropped first to last when the window narrows: filetype, position, git, then Minga's words down to the glyph and "2/3". Never dropped: mode, needs-you, the file name, diagnostics with errors, and persistent problem segments.

**Narrow windows.** Narrowing changes presentation only; every key keeps its meaning. Starting breakpoints, tuned during the build: on macOS about 1360, 1180 and 1000 pt; in the TUI 140, 120, 100 and 80 columns. Drawers truncate task goals before they drop states.

**Accessibility.** Each segment is an accessibility element with a label and an action, for example "1 task needs you. Press SPC a a." VoiceOver announces only when needs-you goes from zero to non-zero.

The resting modeline shows no key hints. Clicking any segment does what its key does.

## Which-key

Pause after `SPC`, or any prefix, and which-key opens as one panel anchored above the modeline.

- A breadcrumb in the panel's border: `SPC › a  Minga`.
- Groups in columns, each column as wide as its longest entry, names dim above each column, rows single-spaced, no rules. The panel is only as tall as its longest group.
- Each entry is `key  Label`, with live counts where they matter ("Tasks · 1 needs you", "Review · 3", "Attach diagnostics · 1 error"). Counts update while the panel is open.
- The ⌘ equivalent appears beside an entry when one exists, so the menu bar and the leader teach each other.
- `⌫` goes back up one group and keeps the panel open (`SPC a` to `SPC`); at `SPC` it closes the panel, like `esc`.
- Timing: appears after the pause (`timeoutlen`), fades in within 120 ms, no fade with Reduce Motion, and never paints a frame if you type through the sequence.
- **Groups read like leaves.** A group is written in Title Case like an action ("Session", "Queue"), drawn in the group colour role with a trailing `›`, and may show a dim count of what is inside ("Session › 7"). Leaves are plain text. Colour plus the chevron, never colour alone, so groups still read in 16 colours. Group labels never start with `+`; the which-key builder adds the chevron. The macOS menu bar's submenus use the same `›`.

## Closing things

One rule everywhere, so nothing traps you:

- **`q` closes Minga's special buffers and splits** and returns focus to the window you came from: the conversation (in Normal mode, outside the composer), the queue, the subagent peek, the review buffer, the tasks drawer, the checklist, draft attachments, retained history and the observatory. This is the Emacs `special-mode` convention (`q` runs `quit-window` in help, Dired, `*Messages*` and Magit) and what Doom does for popups. In a file, `q` stays Vim's macro key.
- **`esc` closes anything transient**: prompts and confirmations cancel, pickers and menus close, overlays such as the protocol error dismiss (its Reload action stays available in the notice it leaves). In a terminal in TERM mode, `esc` goes to the shell; use `⌃\ ⌃N` first.

## Drawers

Lists open in a bottom drawer: the tasks list, the review, diagnostics, the switcher and the terminal. A drawer is a real split of the window, not an overlay that hides code.

- 1 pt divider with a 5 pt hit area; height remembered per kind of buffer; double-click the divider to reset to 40%.
- The header carries the title and the drawer's key hints. There is no second hint line above the modeline.
- `esc` leaves a filter first, then closes. `q` closes, except in the switcher, where letters type into the prompt. ⌘W closes the focused drawer. Focus returns to the window you came from.
- One drawer at a time. Opening another drawer replaces the current one, and closing it returns to the drawer it replaced, the way Doom's popups behave. To see two things at once, use a split.
- When a drawer opens on its own (for example from a notification), single-letter actions are ignored for 300 ms, so a letter you were typing cannot approve something.
- Selection uses the system accent while the list is focused, the muted selection when it is not.

## Live prompts

While a prompt has focus (find file, project search, new task, rename, the command line), typing always edits the query. Actions are reached by moving into the list: `⌃J` / `⌃K` or the arrows to move, `↩` to run, or a click. Prompts never use chords that collide with text editing (`⌃A`, `⌃E`, `⌃H`, `⌃W`, `⌃U`, `⌃K` beyond list movement).

- **No results become next steps.** When project search finds nothing, the result list shows rows such as "Search ignored files too  `-- -u`", "Search hidden files too  `--hidden`", "Search all files  `-- -uu`". The first is preselected. Each row shows the ripgrep flag it adds, so the menu teaches the Doom/consult syntax (`query -- -uu`), which also works typed directly.
- **Only widen what was skipped.** A search that included ignored files offers to include hidden files, not to repeat the same scan under another name. If both were included, the result offers to edit the search. The `grep` fallback includes both and requires `rg` for queries with options.
- **Search and Create use the open directory workspace.** A file-only session does not authorize a recursive search. Create accepts paths relative to the workspace and refuses paths that would leave it, including through a symlink.
- **No match in the switcher** offers "Create the file" and "Search the project for it" as rows.

## Hover

One surface answers "what is this?" for everything: code, diagnostics, Minga's lines, blame lines, state glyphs and modeline segments.

- **Opening:** `K` from the keyboard, or resting the pointer on something for about 400 ms. A grace area lets the pointer travel into the popover.
- **Two levels:** the first `K` shows a compact peek; `K` again moves focus into it, where `j` / `k` and `⌃D` / `⌃U` scroll, `↩` follows a link, `y` copies, and `q` or `esc` return. This is the Neovim `K K` model.
- **Order:** the most urgent first: the diagnostic, then the signature, then the docs, then attribution ("Minga · 4 min ago · task · change 1 of 2 · unreviewed").
- **Calm:** fixed position with no jitter, never covers the cursor line, a maximum size and then scrolling, no animation under Reduce Motion.
- **It teaches keys:** hovering a modeline segment or a glyph shows its meaning and its key ("1 task needs you · SPC a a"). In the terminal the text goes to the echo area instead of a floating tooltip, and only when the terminal reports pointer motion.
- **One source of actions:** the footer reads "`g.` actions" instead of carrying buttons. Content arrives as BEAM-styled spans, so markdown renders identically in both frontends.

## Act menu

One menu answers "what can I do with this?" for whatever is under the cursor or the pointer: a Minga change, a diagnostic, a file row, a task row, a terminal command block, a quickfix item, a symbol, a link or a selection. It replaces the separate twist-head menu, the failed-block menu, the hover action row and the picker's old `C-o` menu.

- **Entry:** `g.` in Normal mode and special buffers, `⌃.` wherever you type (Insert, the composer, the terminal, pickers), and right-click. The precedent is Embark's `embark-act`.
- **The BEAM decides what is on offer;** frontends only draw it. Target-specific actions come first, generic ones after ("Copy file:line link", "Ask Minga about this").
- **It leads with the decision.** When the target asks a yes or no question (Minga's change, an approval, a pending shell command), the top of the menu is a decision bar split into two equal halves: `y` Keep and `n` Reject, or the decision's own words, each with its consequence underneath ("accept 4 lines" / "removes 4 lines, restores 1"). Keep is preselected; the no half never is. A target without a decision puts its single most likely action there instead (`f` Fix on a diagnostic, `↩` Open on a file). Everything else follows as a quieter list grouped by what it acts on ("This change", "This file", "Anywhere"). The yes/no grammar is Minga's signature, so the same bar appears wherever Minga asks you something.
- **The header names the target in words with its state glyph** ("○ Minga's change 1 of 2 · 4 lines · unreviewed"), never with a twist. The filter lives in the header as a dim "› filter" and becomes an input only once you type.
- **The edge carries the target's role colour:** minga for Minga's change, failure for a diagnostic, neutral for a file. The selection tint follows the same role.
- **The most likely action is preselected,** so `↩` does the obvious thing. Typing filters.
- **Two keys per row:** the letter that runs it inside the menu on the left, and on the right the key that runs it without the menu, so the menu teaches you to skip it. The native macOS right-click menu shows only the right-hand key.
- **Consequences are written out** for actions that change things ("Reject · removes 4 lines, restores 1"). Destructive actions sit last and are never preselected. They are not drawn in red, because red means failure; the consequence text carries the warning.
- **Selections and many items:** on a visual selection the actions apply to everything in it, with the count ("Keep 2 changes"). In a picker, the menu offers "Open all 12 matches" (act on all) and "Export 12 to a buffer", where Vim selection picks a subset and `g.` acts on it.
- **Pickers do not mark.** `Tab` only completes; there is no Helm-style marking mode.

On macOS the menu is a compact panel at the target with the decision bar on top, grouped rows below, keys in a fixed monospace column and the direct key dimmed at the right. In the TUI it is a Lip Gloss rounded panel whose border takes the target's role colour: the header and "› filter" sit in the top border and the help in the bottom border; the decision bar is two equal halves of two rows each, the label centred and the consequence dim below, with the selected half in reverse video in the target's role; section headers are dim labels with a thin rule to the border; the panel covers the gutter beside it, the editor behind it dims, and the panel is exactly as tall as its content. The reference boards are `ActMenu_DirectionA` and `ActMenu_Compare` on the design canvas; the lighter strand-anchored alternative (direction B) was not chosen because its branding only exists on Minga's own changes.

## Mouse

Every screen can be reached and left by mouse, and every click teaches its key. The design was done keyboard first, then each scenario got a mouse path from one of seven patterns. Watch them playing on the design canvas: `Mouse_Video_ModePill`, `Mouse_Video_Modeline_MenuBar`, `Mouse_Video_ActMenu_Chips` and `Mouse_Video_TUI`.

1. **The mode pill is the front door.** Clicking the mode pill opens the top-level which-key; every group, row and breadcrumb in it is clickable, so anything under `SPC` is two or three clicks away. This one pattern covers most leader-only screens.
2. **The macOS menu bar mirrors the `SPC` groups.** The Minga menu and its siblings list the same groups and actions as which-key, with the key sequence dimmed in each item title (a native menu cannot draw a key sequence as a shortcut). Both come from the same scope tries, so they cannot drift. The terminal has no menu bar; the mode pill is its path.
3. **Every modeline segment is clickable.** Needs-you opens the tasks drawer, the file name opens the switcher, `change 1/2` jumps to the change, Minga opens the conversation, diagnostics open the list, git opens status. On macOS a hover shows what the segment means and its key ("1 task needs you · SPC a a"); in the terminal the echo line says it instead.
4. **Right-click opens the act menu,** the same menu as `g.` and `⌃.`, on whatever is under the pointer. There is no separate context menu.
5. **Prompts show clickable chips.** Confirmations and minibuffer prompts draw their answers as chips (`y Reject`, `n Keep it`, `esc Cancel`, `s` / `d` on quit). Prompts are transient, so showing keys there keeps principle 10.
6. **Drawer header hints are buttons,** and lists get `‹ ›` arrows for next and previous (quickfix, search matches, command blocks). Clicking outside a transient closes it.
7. **Quitting by mouse:** the window close button, ⌘Q or Minga › Quit on macOS; the `q Quit` row in which-key in the terminal.

**Keyboard only, by design:** composed Vim grammar is not a place you go, so it has no click: operators with motions, counts and `.` repeat, text objects (`ih`, `ah`, `ic`, `ac`), ex ranges and commands (`:'<,'>Minga keep`, `:cdo`) and macros and registers. What they do is still reachable by mouse: select, then right-click and pick the action.

**Terminal caveats.** Hover needs the terminal to stream pointer motion, so the terminal UI asks for motion events only while a panel that uses hover is open. There are no floating tooltips in the terminal; the echo line names the action instead. Minga never takes the terminal's own modifier for native text selection, so selecting text to copy always works.

## Mockup and storyboard metrics

Mockups and storyboards draw at the app's real default metrics, so they never promise more air than the editor has: code at about 1.3 times the font size on macOS (13 px text on 17 to 18 px lines; the app uses the font's ascent plus descent with `line_spacing` 1.0), and terminal rows at about 1.25 times. `line_spacing` stays a user preference. The storyboard factory removes this problem by construction, since its frames come from the real renderers.

## Tasks

`SPC a a` opens `*minga-tasks*`. Rows are ordered needs-you first.

- Each row: the state glyph, the task's goal as its title, state words ("Editing chrome_state.ex · step 2 of 3", "Waiting · rate limited, retry in 40 s"), and its age.
- The header counts each state.
- The row that needs you expands to show the request ("Create test/minga_agent/usage_limit_test.exs +86") and its actions as text: "`y` Approve once  `a` Always for this session  `t` This turn  `n` Deny  `=` Show diff  `↩` Open conversation".
- Every other row shows its one relevant action: `r` Retry on waiting and failed rows, `r` Continue on stopped rows, `o` Output, `i` Inspect, `↩` Review on done rows. After needs-you, rows follow the state order: working, waiting, stopped, failed, done.
- A task that fans out shows its subagents beneath it as a tree (`├─`, `└─`), each with its state.
- Empty state: "No one's at the table yet." with one primary next action, preselected: `c` New task; a second step where the board shows one, `SPC a S h` Resume an earlier session. `q` or `esc` returns focus to the window you came from.
- New task: `c` in the drawer (or `SPC a n`) opens a "New task ›" minibuffer prompt (`n` is Deny on a needs-you row). The goal you type becomes the task's title; the selection is attached as context, `@` adds more, `↩` starts it, `esc` cancels.

## Review

Two ways to review, for two situations.

**In the file**, while you are working. The twist marks each change. `]h` moves between changes, `vah` selects one, `SPC a y` keeps and `SPC a d` rejects at the cursor or across a selection, `.` repeats, and `:'<,'>Minga keep` works on ranges. The modeline shows "change 1/2" while the cursor is inside a change. Clicking the twist head, `g.`, or a right-click opens the act menu: Keep, Reject, Show Diff, Open Conversation. If an unreviewed change still has an error, keeping it asks for confirmation.

**In `*minga-review*`**, when Minga is done and you want to go through everything. `SPC a r` opens it beside the file:

- The task with its state and summary ("Done 3 min ago · 3 files · +40 −12").
- "Unreviewed" and "Kept" sections as a tree of files and changes, each change described in words ("@@ 231 replaced 1 line with 3").
- Keys in the header: `y` keep, `n` reject, `=` diff, `Y` keep all, `]h` next, `↩` go to, `q` close.
- `:Minga review` also fills the quickfix list with unreviewed changes, so `]q` and `:cdo` work.

## Conversation and composer

`SPC a v` opens the conversation as a split buffer, and `SPC a v` again or `q` in Normal mode outside the composer closes it. Messages are calm: a speaker label in its role colour ("You" in the you role, "Minga" in the minga role, see [themes](themes.md)) above plain text, no bubbles. Tool steps are one sentence each with a state glyph ("Read native.ex and found where 429s are classified", "Test run failed · 1 failure"). The header shows the task's goal, its state and time, and the model.

The composer is a real buffer. It starts in Insert; `↩` is a newline in Insert; Normal-mode `↩` or ⌘↩ sends (steering while Minga works); `⌥↩` queues the next message; ⌘. stops. Its key hints appear only while it has focus.

`*minga-queue*` sits between the transcript and the composer. It appears when there is a message waiting or removed, or when `SPC a q q` focuses it. Each row is a whole message with its attachments. `dd` removes it, `p` or `P` puts it back after or before another row in the same queue, and `↩` moves it into the local composer for editing. In a remote conversation, `↩` opens a separate editor and keeps the message queued. `q` returns focus to the composer or transcript. The list scrolls within its block rather than pushing the composer off screen.

The queue labels removals "Removed, not sent." They can go back into the queue, but Minga keeps only the newest eight, subject to a combined size limit. On the ninth removal, or when that size limit removes earlier entries, Minga says which count is gone for good. Removed entries live only in memory and do not survive closing Minga.

Minga's replies are markdown, but the frontends never parse it. The BEAM sends styled spans (headings, emphasis, code, links) as part of the semantic model, and each frontend draws them: native text on macOS, Lip Gloss in the TUI. Glamour is not used, because parsing markdown in Go would duplicate meaning on the frontend.

## Switcher

`SPC ,` (or `SPC b b`) opens a drawer with a prompt at the top: "Find file ›". You type into the prompt, so actions are rows you move to, or the few established picker keys (see [keys](keys.md#file-switcher)).

Sections:

- **Pinned**: up to four files, numbered for `SPC 1` to `SPC 4` and ⌘1 to ⌘4.
- **Changed**: your unsaved files with a dot in the you role; Minga's changes grouped under their task, with its state. Because this section mixes your edits and Minga's, each row carries a thin authorship strand at its left edge (you role or minga role); see [marks](marks.md#the-twist).
- **Recent**: by last visit.
- **Terminals**: each with its cwd and last state.

Files never need closing; only unsaved or unreviewed work is called out. Back and forward are Vim's jump list, `⌃O` and `⌃I` (⌘[ and ⌘] on macOS, or a trackpad swipe).

## Opening a directory

`minga .` means "I want to work on this project".

- **The directory becomes the project root.** From a subdirectory (`minga lib/minga_agent`) the root is the nearest project marker above it (`.git`, `mix.exs` and the other markers), and the switcher opens filtered to that subdirectory; backspace widens it to the whole project. A directory with no markers still opens, with itself as the root.
- **If you worked here before, Minga picks up where you left off.** Files, splits, cursors and scroll come back, and the echo area says "Restored 3 files from last time". `SPC q n` starts fresh instead: it closes the restored files and opens the project home, and never discards unsaved edits or Minga's unreviewed changes.
- **The first time, the project home opens.** `*home*` is a quiet resting view, not a splash screen and not a special buffer, so `q` does nothing there. It shows the project name and path, the branch and change count, "Recent in this project" numbered `1` to `9`, this project's Minga tasks with their state glyphs, and the next actions as an action list. Opening a file replaces it; `SPC p h` brings it back from anywhere.
- **Minga's tasks are not part of the window session.** They keep running across windows and restarts, and show on the home buffer and in the modeline. The session restores only what the window held: open files, cursors, scroll and the active buffer.
- **`minga` with no arguments** behaves like `minga .` inside a project. Outside any project, the home lists recent projects, numbered.
- **macOS routes** (dragging a folder onto the Dock icon, File › Open Folder) take the same path. The TUI and macOS draw the same picture.

## Empty states and notices with actions

Every empty state, and every notice that offers actions, has the same anatomy so a call to action never reads like a description:

1. **What happened:** a title line in primary text weight, with the state glyph if there is one.
2. **Why, or what it means:** one muted line.
3. **What you can do:** after a clear gap, an action list. One row per action, a fixed-width key column in the accent colour and the label in normal text ("`l`   Show log"). The first, most likely action is preselected with a selection bar: `↩` runs it, `j` and `k` move, every row can be clicked. On macOS rows behave like native list rows with a hover highlight; in the TUI the selected row's key is a reverse-video chip on a full-width selection bar.

The block is left-aligned inside its panel. Close controls are not repeated in the body: `q close` lives in the drawer header and the bottom border.

## Blame

`SPC g B` adds a narrow column on the left of the code, not a new buffer.

- **One continuous column** with its own surface tint, from the first visible line to the last.
- **Grouped by commit.** Consecutive lines from the same commit form a group; the author and relative age show on the group's first line only, with a hairline above each group. Every line belongs to a commit, blank lines included.
- **Minga as an author.** Lines Minga wrote form their own group in the minga role, labelled "Minga" with its age; `K` shows the task and review state, and `↩` opens that task's conversation. Uncommitted lines of yours read "You · now" in the you role.
- `SPC g B` again or `q` closes the column.

## Diagnostics

See [marks](marks.md#diagnostics) for underlines and signs.

- Only the cursor line shows its message, as quiet italic text after the code.
- Hover the underline or press `K` for a popover: severity, message, source, and "Fix", "Ask Minga to Fix", "Copy".
- `]e` and `[e` move between diagnostics (Doom's next-error); `g.` opens the act menu, which includes code actions; `SPC c x` opens the list as a buffer.
- The modeline shows counts only when there is something to report.
- **Empty answers stay in the echo area.** When there are no code actions or no references, the echo area says so and names the next step ("No code actions at 3:7 · SPC a ? ask Minga", "No references to parse · SPC c d go to definition"; without a language server, "No references to parse (no server) · SPC s p search the project", which carries the word). An empty list never opens an empty drawer.
- If a change Minga is making produces an error, Minga fixes it as part of its work and says so in a tool step.

## Subagent peek

When a task fans out into subagents, each subagent can be inspected without leaving the parent conversation. `SPC a i`, or `↩` on a "Started ◐ Fact-Check Auditor" line, opens the subagent as a split on the right:

- **Header**: breadcrumb (parent task › subagent), its state and time ("Done · worked 3m"), and a sibling strip of glyphs ("◐ ◐ ● ◐  3 of 4"). `]]` and `[[` step through siblings in place; each glyph is clickable.
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

## Errors and notices

- **Every error names its next step.** A notice says what happened and what you can do, for example "elixir-ls failed to start · SPC c l r restart · SPC c l i log".
- **Notices act through leader keys only.** A notice in the echo area never takes bare keys, because you may be typing in a file and bare letters stay Vim there. Actions are existing bindings (`SPC c l r` restart, `SPC c l i` log, `SPC c l I` manage tools, `SPC f p` open config, `SPC h r` reload, `SPC b m` messages). `esc` dismisses a notice in Normal mode only.
- **Problems that last stay in the modeline.** A failed language server or a config that did not load shows a persistent segment until it is fixed, and that segment is never dropped when the modeline truncates.
- **Crash notices name what restarted.** After a supervised restart the frontend reconnects with your work still on screen, then says what restarted: "Minga's session restarted after a crash; your files and tasks are intact.", or the editor core. The BEAM reports which supervised part restarted.

## Quitting

`SPC q q` or ⌘Q quits at once when nothing is at stake. Otherwise a minibuffer prompt lists what is at stake ("2 unsaved files · Minga is editing chrome_state.ex") and offers `s` save all and quit, `d` discard and quit, `esc` cancel: explicit keys, no y/n ambiguity. Quitting never discards Minga's unreviewed changes: `d` drops only your unsaved edits, and Minga's work waits for review next time. The farewell is one line, "Ciao.", shown in the modeline as the macOS window fades and printed after the TUI restores the terminal so it stays in scrollback.

## Colour roles still to fix

Two existing theme fields break "one colour, one meaning" and change when the new roles land: `agent.assistant_label` uses the minga role (purple, not green), and `agent.status_thinking` uses the working role (not yellow). The same theme change raises the light-theme values that miss 3:1 against the editor background: Catppuccin Latte's needs-you, warning and waiting colours, and AstroDark's waiting colour. See [themes.md](themes.md) on main.
