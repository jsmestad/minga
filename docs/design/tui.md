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
| Every key as pressed | Kitty keyboard protocol: ⌘ passes through, Tab differs from ⌃I, Enter from ⌃M, no Esc delay | keys map to their `SPC` equivalents; ⌘ shortcuts unavailable; Esc alone waits 50 ms (see [Keys](#keys)) |
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

Apple's Terminal is not asked (it prints the query into the screen), and neither is any terminal over SSH, where the terminal at the other end may be one that does the same. A table goes stale, and a terminal's refusal never reaches Minga, so you can force a feature yourself. `set :terminal_features, %{styled_underlines: :on}` in your config turns one on, and `:off` turns one off; `true_color`, `styled_underlines` and `underline_color` can be forced, because those are the ones Minga decides how to draw. The Kitty keyboard protocol, synchronized output and focus reporting cannot: the terminal turns them on and answers for them reliably, so forcing them would only make `:checkhealth terminal` disagree with what happens. What you force wins over everything Minga works out, and `:checkhealth terminal` shows it as set in your config.

The choice reaches the terminal frontend when it starts, as the `MINGA_TERMINAL_FEATURES` variable (`styled_underlines=on,underline_color=off`), because some features are set up once at startup. So a changed option applies the next time Minga starts, and `:checkhealth terminal` says "set in your config, not applied" until then. Where something else starts the frontend (the development supervisor), Minga cannot set the variable; set it yourself. An entry the frontend cannot use is ignored with one line in the log.

Focus reporting does two jobs: when the terminal window loses focus, the borders that mark the focused pane take their quiet colour and the terminal draws its cursor hollow, and "needs you" escalates to a notification because you are not looking.

`:checkhealth terminal` opens a page listing each feature: whether this terminal has it, how Minga found out (the terminal answered, it is a terminal known to have it, the terminal did not answer, or you set it in your config), and what Minga uses instead when it does not. Users should never have to guess why two terminals behave differently. A feature Minga does not use in a terminal yet reads "not used yet", never "missing". In the macOS app the page says in one sentence that this is not a terminal. `:checkhealth` on its own lists the pages that exist.

The page is the shared Help buffer: it is read-only and scrolls with the usual motions and the wheel. Today you leave it as you leave any buffer, with `SPC b p` or `SPC b b` back to your file; closing it with `q` or a click, as the scenario is designed, is not built yet. It binds no key of its own.

### Keys

A terminal with the Kitty keyboard protocol (Kitty, Ghostty, WezTerm, iTerm, foot and Alacritty have it) reports each key as pressed: Esc is its own sequence with no delay, Tab is not `⌃I`, Enter is not `⌃M`, and `⌘` arrives as a modifier. Minga asks for it at startup and puts the terminal back as it was on exit. Minga also asks for xterm's modifyOtherKeys, which reports modified keys such as `⌥↩` as their own sequences but still sends Esc as a lone `ESC`, so the rule below applies there too.

Without the Kitty keyboard protocol, the Esc key and the Alt modifier are the same byte: Esc is `ESC`, and `⌥↩` is `ESC` followed by Enter. Minga tells them apart by how the bytes arrive, because a terminal writes the bytes of one key together:

- `ESC` and a key in one read are Alt and that key. `⌥↩` queues.
- A read that is only the `ESC` byte is the Esc key, and what the next read brings is a separate key. So Esc then Enter typed by a person in a local terminal sends, however fast, and the same holds for Esc then Space or Esc then `j`. The Esc key is delivered the moment the next key arrives.
- An Esc with nothing after it is delivered after 50 ms, the same default as Neovim's `ttimeoutlen`. That wait is what lets an arrow key still be one key when a slow link splits its sequence after the first byte, so it cannot be shorter without breaking those.

The rule (`KeyInput` in `go/tui/internal/terminal/key_input.go`) cannot see two cases, and the Kitty keyboard protocol removes both:

- `ESC` and Enter that reach Minga in a single read are `⌥↩`. That is what a script that writes both bytes produces, what a remote link that merges two key presses produces, what a multiplexer produces inside its own escape time, and what happens when Minga is too busy to read between the two keys, so the terminal hands it both at once. In tmux that is the `escape-time` option: 10 ms by default since tmux 3.5 and 500 ms before it, so on an older tmux set `set -sg escape-time 10`.
- Esc followed within 50 ms by one of `[ O P ] _ ^ X \` reads as it always did, because those bytes continue an escape sequence.

Which `⌘` keys a terminal gets: `⌘.` (stop the agent) and `⌘↩` (send from the composer) in every profile, and `⌘S`, `⌘Z` and the other desktop shortcuts in the CUA profile, when the terminal reports `⌘` and does not keep the key for itself. In the Vim profile `⌘S` and `⌘Z` do nothing in a terminal: the macOS app runs them from its menu, not from the keymap. A terminal emulator keeps `⌘W`, `⌘Q` and `⌘1` to `⌘4` for its own windows and tabs.

## Open question

Rendering Minga's replies as markdown in Go (Glamour) would mean the frontend parses content, which risks duplicating semantics the BEAM owns. The likely answer is that the BEAM sends styled spans and the TUI draws them with Lip Gloss, as macOS draws them natively. See [ADR-0006](../adr/0006-the-spine.md#open-questions).
