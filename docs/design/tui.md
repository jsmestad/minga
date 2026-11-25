# The terminal UI

The Go TUI is not a fallback that gets a simplified design. It draws the same screens as macOS, with the same marks and keys, using Bubble Tea v2, Bubbles v2, Lip Gloss v2 and Ultraviolet (see [`docs/CHARM_TUI.md`](../CHARM_TUI.md)). Separation comes from borders, surface tints and padding, not from extra lines of text. Every gap, inset and corner comes from the chrome token scale shared with macOS (see [Charm TUI chrome tokens](../CHARM_TUI.md#chrome-tokens) and [anatomy.md](anatomy.md)), never from a hand-counted run of spaces.

## Visual rules

- **One border style.** Every pane that meets another uses Lip Gloss's rounded border. Only the focused pane's border takes the focus colour; the others use the quiet border colour.
- **Titles and help live in borders.** A pane's title and counts sit in its top border; its key hints sit in its bottom border, and only while it has focus. Nothing stacks extra hint lines above the modeline.
- **Surface tints.** Drawers, which-key and menus sit on the theme's surface colour, one step away from the editor background. A one-cell padding inside every panel.
- **Overlays float.** Which-key, the tasks drawer, the switcher and menus are layers over the editor (`lipgloss.NewLayer` and the canvas compositor, already used in `go/tui`), with a soft drop shadow of dim half-blocks on the right and bottom. The code stays visible underneath; while a drawer has focus, the editor dims slightly.
- **Selection.** A full-width background bar on the selected row, plus a `▌` in the row's state colour.
- **Modeline.** Segments are coloured blocks with one-cell gaps, no powerline arrows. The mode pill is the only fully saturated block.
- **Diff.** Removed lines on a faint tint of `git.deleted_fg`, added lines on a faint tint of `git.added_fg` (the derived diff tints in [themes.md](themes.md)).
- **Trees.** The review buffer, the tasks drawer's subagents and the file tree use `lipgloss/tree` connectors (`├─`, `└─`, `│`) instead of hand-drawn arrows.
- **Working.** The working state animates with a Bubbles spinner using the frames `◐ ◓ ◑ ◒`, static when reduced motion is requested.

The glyphs for states, the twist and diagnostics are in [marks.md](marks.md).

## Colour profiles

Colours come from theme roles ([themes.md](themes.md)), never literals, and each role is a light and dark pair (`lipgloss.LightDark`) chosen from the detected terminal background. Lip Gloss's colour profile maps truecolor down to 256 and 16 colours. Because every state is a shape plus a word, nothing depends on hue surviving the downgrade.

## Terminal capabilities

Some features need a modern terminal. Each one is detected at startup and degrades quietly; none is required.

| Feature | Mechanism | Without it |
|---|---|---|
| 24-bit colour | truecolor | 256 or 16 colours via the colour profile |
| Curly and dotted underlines | SGR 4:3 and 4:4 | plain underline |
| Underline colour | SGR 58 | underline in the text colour |
| Clickable `file:line` | OSC 8 hyperlinks | plain text; `gf` still opens it |
| Every key as pressed | Kitty keyboard protocol: ⌘ passes through, Tab differs from ⌃I, Enter from ⌃M, no Esc delay | keys map to their `SPC` equivalents; ⌘ shortcuts unavailable |
| "Needs you" outside the window | OSC 9 or OSC 777 desktop notification | bell and title change only |
| Tab title | OSC 2, e.g. "● Minga needs you" | none |
| Progress in the tab | OSC 9;4 while Minga works | progress in the modeline only |
| Exact twist in the gutter | Kitty graphics protocol | two-tone `▚` / `▐` cells |
| Flicker-free frames | synchronized output (mode 2026) | frames may tear on fast scroll |
| Focus awareness | focus reporting (mode 1004) | no unfocused dimming |
| Clipboard | OSC 52 | system clipboard tool |

The terminal's answers arrive after startup, or never. Each feature is pending until the terminal answers or two seconds have passed; after that it is detected, or it uses its fallback, or it is missing when nothing replaces it. The frontend keeps one value for this and tells the BEAM the same value (`terminal_report` in [`docs/PROTOCOL.md`](../PROTOCOL.md)), so the report cannot differ from what is drawn.

Styled underlines and the underline colour have no query that every terminal answers. They are known from the terminals that document them (Kitty, Ghostty, WezTerm, iTerm, foot, Alacritty, VTE from 0.52), or from the terminal's own terminfo answer (`Smulx`, `Setulc`). Inside tmux or screen the variables describe the outer terminal and the multiplexer decides what passes, so only the answer counts there. Until one of these says yes, diagnostics use the plain underline.

Focus reporting does two jobs: when the terminal window loses focus, the borders that mark the focused pane take their quiet colour and the terminal draws its cursor hollow, and "needs you" escalates to a notification because you are not looking.

`:checkhealth terminal` opens a buffer listing each feature, whether this terminal supports it, and what Minga uses instead when it does not. Users should never have to guess why two terminals behave differently.

## Open question

Rendering Minga's replies as markdown in Go (Glamour) would mean the frontend parses content, which risks duplicating semantics the BEAM owns. The likely answer is that the BEAM sends styled spans and the TUI draws them with Lip Gloss, as macOS draws them natively. See [ADR-0006](../adr/0006-the-spine.md#open-questions).
