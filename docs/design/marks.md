# Marks

Two marks make Minga look like Minga. Both come from the band in the app icon. Fonts and themes belong to the user, so identity lives in these shapes, in the colour roles below, and in the voice, not in a typeface.

- **The twist** says where Minga's work is in your text.
- **The orbit** says what Minga is doing.

Use the exact shapes in [`marks/`](https://github.com/jsmestad/minga/tree/main/docs/design/marks). Do not redraw them by hand; drift starts there.

## Colour roles

Each colour is a theme role, and each role means one thing. Themes choose the values; they never change the meanings. The full list of roles, where each lives in `MingaEditor.UI.Theme`, and how the reference themes fill them is in [themes.md](themes.md). The hex values below are examples from the default theme, Catppuccin Frappé. The SVGs in [`marks/`](https://github.com/jsmestad/minga/tree/main/docs/design/marks) carry the design canvas's placeholder colours; a frontend takes the shapes from them and the colours from the theme.

| Role | Means | catppuccin_frappe (default) |
|---|---|---|
| you | Your edits, your cursor, your messages | `#8CAAEE` |
| minga | Minga, its cursor, its changes, the light twist strand | `#CA9EE6` |
| minga_shade | The twist's shade strand (derived: minga mixed over the background) | derived |
| you_shade | Your opposite strand inside Minga's twist | derived |
| minga_kept | The dim strand of a kept Minga change | derived |
| needs_you | Only "Minga needs you" | `#EF9F76` |
| failure | Only errors and failed states | `#E78284` |
| done | Only completed states | `#A6D189` |
| warning | Only diagnostic warnings | `#E5C890` |
| selection | The focused list's selected row | system accent on macOS, `editor.selection_bg` in the TUI |

The needs-you colour is never a warning colour and never decorative. If something is in the needs-you colour, Minga is waiting for you.

## The twist

A ribbon of two strands in the gutter's authorship column, 10 pt wide, between the sign column and the text.

**Where.** The strands cross once, on the first line of a change. That crossing is the change's handle: click it for Keep, Reject, Show Diff and Open Conversation. The crossing is always on the first line, never centred, because the change grows while Minga writes and a handle must not move.

**Who.** Strand colours carry authorship. Minga's change pairs `minga` with `minga_shade`. When you edit inside it, the opposite strand takes `you_shade`. A strand outside Minga's change uses the full `you` role. The shaded strands contrast with the main strand, while kept ink contrasts with the code surface.

**Settled or not.**

| State | Drawing | File |
|---|---|---|
| Unreviewed, first line | two strands crossing | [`twist-head.svg`](marks/twist-head.svg) |
| Unreviewed, other lines | two parallel strands | [`twist-body.svg`](marks/twist-body.svg) |
| Unreviewed, last line | two strands with rounded ends | [`twist-last.svg`](marks/twist-last.svg) |
| Shared authorship | the opposite strand uses `you_shade` on your lines | [`twist-shared-body.svg`](marks/twist-shared-body.svg) |
| Kept | one thin strand in `minga_kept` until the next commit | [`twist-kept.svg`](marks/twist-kept.svg) |
| Rejected | gone with the text | |
| Current change while reviewing | head gets a soft halo in the minga role at about 18% (circle r=7) | |

Each line draws its own segment, so the ribbon stays aligned at any line height. The files use a 26 pt line; scale the height to the real line height and keep the crossing in the top 18 pt. The crossing gap is drawn in the code background colour (`#1e1f24` in the default theme). A single-line change uses the head shape with both strands ending at 21 pt.

**Only in the code gutter.** The twist marks a place in your text, so it appears only in the code gutter, on the first line of one of Minga's changes. Lists, menus, popovers and headers never carry a twist: in a list where every row is Minga's change, the same mark on every row says nothing, and the header already names the source.

**Authorship strand in mixed lists.** A list that mixes sources, such as the switcher's Changed section (your edits and Minga's) or a quickfix list that combines search hits with Minga's changes, shows a thin authorship strand at each row's left edge: 2 pt on macOS, a one-cell bar in the TUI. The strand uses the minga role for Minga's rows and the you role for yours; rows from neither get nothing. A list whose rows all share one source carries no mark.

**Sticky twist.** When part of a long change is visible but its first line has scrolled above the viewport, the twist head pins to the top of the gutter column with a hairline shadow, like a sticky section header. It stays clickable and lets go when the change scrolls away.

**Small mark.** Lists, the switcher and menus use the head shape scaled to 10 × 14 pt, with the gap drawn in the surrounding background colour.

## The orbit

The orbit appears only while Minga is moving. When Minga stops, the orbit goes and the satellite remains, shaped by why it stopped. There are six state words and five shapes. The shapes differ without colour, so they work for colour-blind users and in 16-colour terminals. A state is always followed by its word, and the word is what tells Waiting and Stopped apart: they share the hollow dot. Which state an Agent status speaks as (thinking and running a tool are Working, a pending approval Needs you, an error Failed) is one table in `docs/design_tokens.toml`, generated for Elixir, Swift and Go, so every surface names a status with the same word.

| State | Shape | Word | File | TUI |
|---|---|---|---|---|
| Working | satellite running its orbit, trailing an arc; animated, static under Reduce Motion | "Working", or what it is doing | [`state-working.svg`](marks/state-working.svg) | `◐`, cycling `◐ ◓ ◑ ◒` |
| Needs you | dot with a soft halo, needs_you role | "Needs you" | [`state-needs-you.svg`](marks/state-needs-you.svg) | `◉` |
| Waiting | hollow dot, waiting role | "Waiting", with the reason and time, e.g. "rate limited, retry in 40 s" | [`state-waiting.svg`](marks/state-waiting.svg) | `○` |
| Stopped | hollow dot, the same shape as Waiting, waiting role | "Stopped". You stopped it; it waits for you to continue, not for anything outside | [`state-waiting.svg`](marks/state-waiting.svg) | `○` |
| Failed | diamond, failure role | "Failed", with the reason | [`state-failed.svg`](marks/state-failed.svg) | `◆` |
| Done | solid dot, done role | "Done" ("Passt." once, at completion) | [`state-done.svg`](marks/state-done.svg) | `●` |

## The gutter

One layout everywhere, left to right: line number, sign column (8 pt, diagnostics only), authorship column (10 pt). The authorship column replaces a separate git gutter and answers one question: who wrote this line, and is it settled?

- Your uncommitted lines: one thin strand in the you role (1.5 pt, centred). Deleted lines: a small notch in the same role between lines.
- Minga's unreviewed lines: the twist ribbon.
- Kept Minga lines: one thin strand in the `minga_kept` role until commit.

## Diagnostics

The failure role means failure, so only errors use it.

| Severity | Underline | Sign column | TUI sign |
|---|---|---|---|
| Error | curly, failure role | solid bar in the failure role, 3 × 12 pt, radius 1.5 | `E` in the failure role |
| Warning | dotted, warning role at 70% | hollow bar, 1.5 pt outline | `W` in the warning role |
| Info, hint | faint dotted, secondary text colour | none | none |

The message for the line under the cursor appears as quiet italic text after the code, prefixed by its source ("elixir:", "credo:"). Other lines stay clean. See [surfaces](surfaces.md#diagnostics) for the list, hover and Minga's part.

## The twist in the terminal

The TUI draws the twist in one cell per line, with the two strands as foreground and background colour:

- Changed lines: `▐`, the minga role as foreground over minga_shade as background.
- First line of a change: `▚`, so the strands swap sides from the top half to the bottom half and visibly cross.
- Your lines: a thin `│` in `you`. Kept lines: a dim `│` in `minga_kept` on the editor background.
- 16 colours: the theme's 16-colour mapping of minga over its shade, magenta over dark magenta by default.

Block characters fill the whole cell in a real terminal, so the strands join from line to line. On terminals with a graphics protocol (Kitty, Ghostty, WezTerm, iTerm2) the gutter may draw the exact SVG twist instead. See [tui.md](tui.md).
