# The built-in terminal

This page and issue #4061 govern `*minga-shell*`, command blocks, approvals and the failed-block menu. [runs.md](runs.md) and [ADR-0010](../adr/0010-runs.md) (Proposed) propose moving Minga's commands into a run buffer. Until ADR-0010 is accepted, do not build from runs.md where it disagrees with this page.

A terminal is a buffer. It uses the same modes, marks, drawers and yes/no grammar as everything else, and it is where Minga runs its commands, so you can watch them. This is the interaction contract for #19 and #122. The emulator engine is libghostty-vt in a helper process, with the BEAM owning the terminal buffer; see [ADR-0008](../adr/0008-terminal-engine.md).

## Opening and closing

- `SPC o t` toggles the terminal drawer at the bottom, about 30% of the window. It reuses the last terminal and never spawns a second one.
- `SPC o T` opens a new terminal in the current window.
- Terminals are named `*terminal 1*`, `*terminal 2*`, and listed in the switcher under "Terminals" with their cwd and last state.
- Typing `exit` in the drawer closes the drawer and its buffer: it is deliberate. The "Shell exited" state (scrollback kept, `↩` restart, `q` close) is for `SPC o T` windows and for shells that end on their own. `:q` asks "Kill zsh (pid 4182)? y/n" only if a foreground job is running.

## Two modes

- **TERMINAL** (pill "TERM"): every key goes to the shell, including Esc and ⌃C.
- **Normal**: Vim motions over the scrollback, `/` search, visual selection, yank. The view holds still while you read; new output shows "↓ 12 new lines" at the bottom edge instead of scrolling away.
- `⌃\ ⌃N` leaves TERMINAL, as in Neovim. `i`, `a`, or `↩` on the live prompt line go back. Clicking in the terminal enters TERMINAL.

## Command blocks

With shell integration (OSC 133 for prompts and commands, OSC 7 for the cwd), each prompt, command and its output form one block.

- The gutter has a state column instead of line numbers (terminals have no meaningful line numbers), then the authorship column.
- The command line of each block carries a state glyph: working while it runs, done for exit 0, failed with the exit code ("exit 2"). The duration sits at the right. A dim rule separates blocks; a failed block gets a faint red tint.
- `]]` and `[[` jump between commands. `ic` is a command's output and `ac` the whole block, so `yic` copies output.
- Without shell integration it is a plain terminal: no blocks, no glyphs, and a one-time hint in `*Messages*`.

## Who ran it

- The authorship column uses the same strands as code: your commands get your thin blue strand, Minga's commands get the purple ribbon.
- Minga's commands run in one shared, visible `*minga-shell*` buffer. `SPC a w` shows it in a split.
- `*minga-shell*` is read-only to keystrokes. It opens in Normal and has no TERMINAL mode, so you cannot type into Minga's shell by accident. You can scroll, search, yank, and interrupt the running command with ⌃C, ⌘. or `SPC a s`.
- A command that needs approval appears as a pending block with the needs-you glyph. `↩` on it, or a click, asks in the minibuffer: "Run mix ecto.reset? y once · a always · t this turn · n deny". Asking in the minibuffer keeps `y` as yank in the scrollback. `esc` defers: the prompt closes, the request stays pending and needs-you stays lit, so a request is never denied by accident. `n` is the deliberate deny.

## Failed blocks

`↩` in Normal on a failed block, or a click on its glyph, opens a menu:

- `f` Ask Minga to fix, with the command and output attached as context.
- `yic` Copy output.
- `r` Rerun.
- `q` Send to quickfix: parses `file:line`, then `]q` and `:cdo` work.

## Modeline

Mode pill (TERM or NORMAL), needs-you when non-zero, buffer name, cwd, the running command with the working glyph or the last exit status ("exit 0", "exit 2"), and the shell and pid at the right. Truncation follows the [modeline rules](surfaces.md#modeline).

## Mouse and rendering

Click focuses and enters TERMINAL, the wheel scrolls back, a drag selects and copies, and ⌘-click on `file:line` opens the file. macOS renders terminals with the editor's font and theme, ligatures off, in true colour. The TUI passes true colour through when the host terminal supports it and falls back to 256 colours.
