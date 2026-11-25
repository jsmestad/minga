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

Styled underlines and the underline colour have no query that every terminal answers: iTerm and the VTE terminals draw them and answer no terminfo query. So each of the two is settled in one of three ways, and the frontend remembers which:

- **Answered by the terminal.** The terminal answers the terminfo query for `Smulx` (styled underlines) or `Setulc` (underline colour). An answer with a value turns the feature on, also for a terminal the table does not list, and an answer always wins over the table below. A terminal that lacks the capability usually sends the standard refusal, which the input library drops, so in practice a stale table entry is corrected by the override planned below, not by the terminal.
- **Known terminal.** The terminal is in this table, which mirrors `KnownTerminals` in `go/tui/internal/terminal/known_terminals.go`. The table is never used inside tmux or screen: there the variables describe the outer terminal and the multiplexer decides what passes.
- **Fallback.** Neither said yes within two seconds, so diagnostics use the plain underline.

| Terminal | Recognised by | Since | Rests on |
|---|---|---|---|
| Kitty | `TERM=xterm-kitty` or `KITTY_WINDOW_ID` | | Kitty defined the styled and coloured underline sequences |
| Ghostty | `TERM_PROGRAM=ghostty` or `TERM=xterm-ghostty` | | implements Kitty's underline sequences |
| WezTerm | `TERM_PROGRAM=WezTerm` or `TERM=wezterm` | | implements Kitty's underline sequences |
| iTerm | `TERM_PROGRAM=iTerm.app` | | draws the sequences and answers no terminfo query |
| foot | `TERM=foot` or `foot-extra` | | implements Kitty's underline sequences |
| Alacritty | `TERM=alacritty` | | implements Kitty's underline sequences |
| VTE terminals (GNOME Terminal and others) | `VTE_VERSION` of 5200 or more | VTE 0.52 | the sequences arrived in VTE 0.52 |

Apple's Terminal is not asked (it prints the query into the screen), and neither is any terminal over SSH, where the terminal at the other end may be one that does the same. A table goes stale, so a config option to force a feature on or off comes with `:checkhealth terminal`, which will also show how each feature was settled.

Focus reporting does two jobs: when the terminal window loses focus, the borders that mark the focused pane take their quiet colour and the terminal draws its cursor hollow, and "needs you" escalates to a notification because you are not looking.

`:checkhealth terminal` opens a buffer listing each feature, whether this terminal supports it, and what Minga uses instead when it does not. Users should never have to guess why two terminals behave differently.

## Open question

Rendering Minga's replies as markdown in Go (Glamour) would mean the frontend parses content, which risks duplicating semantics the BEAM owns. The likely answer is that the BEAM sends styled spans and the TUI draws them with Lip Gloss, as macOS draws them natively. See [ADR-0006](../adr/0006-the-spine.md#open-questions).
