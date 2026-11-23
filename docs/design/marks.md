# Marks

Two marks make Minga look like Minga. Both come from the band in the app icon. Fonts and themes belong to the user, so identity lives in these shapes, in the colour roles below, and in the voice, not in a typeface.

- **The twist** says where Minga's work is in your text.
- **The orbit** says what Minga is doing.

Use the exact shapes in [`marks/`](marks/). Do not redraw them by hand; drift starts there.

## Colour roles

Each colour means one thing. Themes may remap the values, never the meanings.

| Role | Default | Means |
|---|---|---|
| You | `#4f9fe0` strands, `#6cb8f5` text | Your edits, your cursor, your messages |
| Minga | `#a463e6` light, `#6b3fa3` shade, `#b98cf0` text | Minga, its cursor, its changes |
| Needs you | `#f2b544` | Only "Minga needs you" |
| Failure | `#e5707a` | Only errors and failed states |
| Done | `#7fbf7a` | Only completed states |
| Warning | `#d8c08a` | Only diagnostic warnings |
| Selection | system accent | The focused list's selected row |

Amber is never a warning colour and never decorative. If something is amber, Minga is waiting for you.

## The twist

A ribbon of two strands in the gutter's authorship column, 10 pt wide, between the sign column and the text.

**Where.** The strands cross once, on the first line of a change. That crossing is the change's handle: click it for Keep, Reject, Show Diff and Open Conversation. The crossing is always on the first line, never centred, because the change grows while Minga writes and a handle must not move.

**Who.** Strand colours carry authorship. Minga's change is purple over purple shade. When you edit inside Minga's change, the shade strand on your lines turns blue: shared authorship.

**Settled or not.**

| State | Drawing | File |
|---|---|---|
| Unreviewed, first line | two strands crossing | [`twist-head.svg`](marks/twist-head.svg) |
| Unreviewed, other lines | two parallel strands | [`twist-body.svg`](marks/twist-body.svg) |
| Unreviewed, last line | two strands with rounded ends | [`twist-last.svg`](marks/twist-last.svg) |
| Shared authorship | shade strand turns blue on your lines | [`twist-shared-body.svg`](marks/twist-shared-body.svg) |
| Kept | one thin muted strand until the next commit | [`twist-kept.svg`](marks/twist-kept.svg) |
| Rejected | gone with the text | |
| Current change while reviewing | head gets a soft purple halo (circle r=7, `rgba(164,99,230,0.18)`) | |

Each line draws its own segment, so the ribbon stays aligned at any line height. The files use a 26 pt line; scale the height to the real line height and keep the crossing in the top 18 pt. The crossing gap is drawn in the code background colour (`#1e1f24` in the default theme). A single-line change uses the head shape with both strands ending at 21 pt.

**Sticky twist.** When part of a long change is visible but its first line has scrolled above the viewport, the twist head pins to the top of the gutter column with a hairline shadow, like a sticky section header. It stays clickable and lets go when the change scrolls away.

**Small mark.** Lists, the switcher and menus use the head shape scaled to 10 × 14 pt, with the gap drawn in the surrounding background colour.

## The orbit

The orbit appears only while Minga is moving. When Minga stops, the orbit goes and the satellite remains, shaped by why it stopped. The five shapes differ without colour, so they work for colour-blind users and in 16-colour terminals. A state is always followed by its word.

| State | Shape | Word | File | TUI |
|---|---|---|---|---|
| Working | satellite running its orbit, trailing an arc; animated, static under Reduce Motion | "Working", or what it is doing | [`state-working.svg`](marks/state-working.svg) | `◐`, cycling `◐ ◓ ◑ ◒` |
| Needs you | amber dot with a soft halo | "Needs you" | [`state-needs-you.svg`](marks/state-needs-you.svg) | `◉` |
| Waiting | hollow grey dot | "Waiting", with the reason and time, e.g. "rate limited, retry in 40 s" | [`state-waiting.svg`](marks/state-waiting.svg) | `○` |
| Failed | red diamond | "Failed", with the reason | [`state-failed.svg`](marks/state-failed.svg) | `◆` |
| Done | solid green dot | "Done" ("Passt." once, at completion) | [`state-done.svg`](marks/state-done.svg) | `●` |

## The gutter

One layout everywhere, left to right: line number, sign column (8 pt, diagnostics only), authorship column (10 pt). The authorship column replaces a separate git gutter and answers one question: who wrote this line, and is it settled?

- Your uncommitted lines: one thin blue strand (1.5 pt, centred). Deleted lines: a small blue notch between lines.
- Minga's unreviewed lines: the twist ribbon.
- Kept Minga lines: one thin muted purple strand until commit.

## Diagnostics

Red means failure, so only errors are red.

| Severity | Underline | Sign column | TUI sign |
|---|---|---|---|
| Error | curly, red | solid red bar, 3 × 12 pt, radius 1.5 | `E` in red |
| Warning | dotted, `#d8c08a` at 70% | hollow bar, 1.5 pt outline | `W` in the warning colour |
| Info, hint | faint dotted, secondary text colour | none | none |

The message for the line under the cursor appears as quiet italic text after the code, prefixed by its source ("elixir:", "credo:"). Other lines stay clean. See [surfaces](surfaces.md#diagnostics) for the list, hover and Minga's part.

## The twist in the terminal

The TUI draws the twist in one cell per line, with the two strands as foreground and background colour:

- Changed lines: `▐`, light purple `#a463e6` over shade `#4a2c75`.
- First line of a change: `▚`, so the strands swap sides from the top half to the bottom half and visibly cross.
- Your lines: a thin blue `│`. Kept lines: a dim `│`.
- 16 colours: magenta over dark magenta.

Block characters fill the whole cell in a real terminal, so the strands join from line to line. On terminals with a graphics protocol (Kitty, Ghostty, WezTerm, iTerm2) the gutter may draw the exact SVG twist instead. See [tui.md](tui.md).
