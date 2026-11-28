# ADR-0009: One modeline follows focus, and windows are labelled only when there are several

**Status:** Accepted (2026-11-27). Clarifies [ADR-0006](0006-the-spine.md) decisions 1 and 2. The one-modeline half describes what both frontends do today; the window label is not implemented.

## Decision

1. **There is one modeline.** It sits at the bottom of the window, under any drawer, and carries the state of the focused window: mode, needs-you, file, change position, git, Minga, diagnostics, filetype and position. When focus moves to another window, the modeline changes to that window's state. No window has a modeline of its own.
2. **The title bar follows focus too.** It names the focused window's buffer, as it does today.
3. **A window is labelled only when there is more than one.** While two or more buffer windows are visible, each one shows a one-row label at its top edge with its buffer's name: the file name followed by its project-relative directory in the secondary colour, and the unsaved dot when it applies. With a single buffer window there is no label, so the resting screen is unchanged.
4. **The label is a name, not a second modeline.** It carries no mode, no position, no diagnostics and no key hints. The focused window's label uses the primary text role and the others use the secondary role. Clicking a label focuses its window.
5. **A drawer that shows a buffer is a window.** When labels are showing, it is labelled like any other window. A drawer that shows a list keeps its header and has no label.

## Context

ADR-0006 says "The resting screen is your code, a plain title bar, and one modeline", and principle 1 repeats it. `docs/design/anatomy.md` calls the modeline height "a frame metric owned by the status bar". The code agrees: `MingaEditor.Layout.GUI` lays out every window without a modeline, and the frontends draw one status bar under everything.

One sentence in `docs/design/surfaces.md` said the opposite: "with two splits each modeline shows its own file while the title follows the one you are in". The design for the run drawer exposed the conflict, because its reviewers could not agree on where the modeline sits when a drawer opens under a split. Each reading followed from a written rule.

That sentence was covering a real gap. With one modeline and no tab strip, nothing on screen names the buffer in a window you are not in. Two files side by side are told apart only by their contents.

## Options compared

**A modeline per window (Vim's default, Emacs).** Every window shows its own state. It answers "what is in that window", but it repeats the mode pill, git, Minga's state and diagnostics once per split, and the segments that matter most (needs-you, Minga) either appear several times or have to pick one window. It contradicts ADR-0006 decision 1 and costs one row per window all the time.

**One modeline and nothing else (today).** It keeps the resting screen quiet and matches the ADR. It leaves unfocused windows unnamed.

**One modeline plus a label only when there are several windows (Neovim's global statusline with a winbar).** State is said once, in one place. The label appears only when it carries information you need, which is the test principle 1 sets for anything that stays on screen. It costs one row per window, and only while there are splits.

## Why this one

It keeps the Spine's rule that state is said once, and it closes the gap with the smallest thing that names a window. A label that appears and disappears with the split count is context, not a toggle (principle 4): nobody turns it on.

## Consequences

- `docs/design/surfaces.md` changes: the sentence about each split's modeline is replaced, and the label is described next to the title bar.
- `docs/design/anatomy.md` gains the label's metrics when it is built: one row at the row pitch, the leading inset of the text.
- The BEAM owns the label as part of the window's semantic model, so both frontends show the same name. The frontend that owns row fit reports one row fewer for a labelled window (ADR-0001).
- Opening the first split moves text down by one row in the window that was already there, and closing the last split moves it back. The change happens on a key you pressed.
- Designs that put a segment "in the modeline" need no change: there is one, and it follows focus. The run drawer design relies on this.
- A buffer drawer under a split is labelled like the windows above it, so the drawer's minimum height grows by one row while labels are showing.
