# Surface anatomy

The boards in `design/boards/` fix structure: which parts a surface has, their order, and what they say. They are not pixel specs, and nobody should measure them. This file fixes polish: how far apart the parts sit, how tall a row is, where the leading edge falls, and which text step each part uses, on macOS and in the TUI. When a board and this file disagree about a measurement, this file wins. When they disagree about structure, the board wins and this file is updated in the same pull request.

Every measurement here is a token. macOS draws it from `ChromeTokens.swift` (see [macOS chrome tokens](../../macos/AGENTS.md#chrome-tokens)); the TUI draws the same token, by the same name, from `go/tui/internal/ui/chrome_tokens.go` (see [Charm TUI chrome tokens](../CHARM_TUI.md#chrome-tokens)). A part that needs a value no token has gets a new token with an intent, never a literal. The automatic layout audit in the storyboard factory checks real renders against this file, and real renders, not boards, become the baselines once they pass.

## The scale on both frontends

A terminal cell is about 8 pt wide and 18 pt tall at Minga's default font. The TUI converts each spacing step with one rule per axis, so it is never airier than macOS:

- **Columns:** `floor(points / 8)`, with a minimum of 1 for any step of 4 pt or more. A gap between two pieces of content never vanishes.
- **Rows:** `floor(points / 18)`. A row is the smallest vertical unit, so padding inside a row does not exist in the terminal.

| Token | macOS | TUI columns | TUI rows | Intent |
|---|---|---|---|---|
| `pixel` | 1 pt | 0 | 0 | Optical separation. The TUI draws a glyph or a tint instead. |
| `hairline` | 2 pt | 0 | 0 | Badge internals, tight vertical rhythm. |
| `xs` | 4 pt | 1 | 0 | Tight inline groups: a key and its label, a glyph and its word. |
| `sm` | 6 pt | 1 | 0 | Compact row gaps, chip padding. |
| `md` | 8 pt | 1 | 0 | Default gaps and insets. |
| `lg` | 12 pt | 1 | 0 | Panel insets, label to meta. |
| `xl` | 16 pt | 2 | 0 | Between groups on one line: hints, chips. |
| `xxl` | 20 pt | 2 | 1 | Between blocks of a panel. |
| `panel` | 24 pt | 3 | 1 | Empty-state and dialog insets, which-key column gap. |
| `section` | 32 pt | 4 | 1 | Major section breaks. |

**What collapses in the TUI.** Horizontally, `xs`, `sm`, `md` and `lg` are all one column, and `xl` and `xxl` are both two. Vertically, everything up to `xl` is zero rows, and `xxl`, `panel` and `section` are all one blank row. The collapse is the point: the TUI keeps the same order of gaps (a key sits closer to its label than one hint sits to the next) without inventing half cells.

**Radius.** The terminal has no corners except border glyphs. `accent`, `sm` and `md` collapse to square: rows, chips and pills are tinted blocks without a border. `lg` and `xl` become Lip Gloss's rounded border, the one border style in [tui.md](tui.md).

| Token | macOS | TUI |
|---|---|---|
| `accent` | 1 pt | square |
| `sm` | 4 pt | square |
| `md` | 6 pt | square |
| `lg` | 8 pt | rounded border |
| `xl` | 12 pt | rounded border |

**Text.** The terminal has one size, so the typography steps collapse to a one-cell glyph or one of three text treatments: faint, normal and bold. Hierarchy comes from weight and colour role, never from size.

| Steps | macOS | TUI treatment |
|---|---|---|
| `tiny`, `symbol`, `micro` | 7 to 9 pt glyphs | one-cell glyph |
| `caption` | 10 pt | faint (`text.faint` role) |
| `small`, `body` | 11 and 12 pt | normal |
| `emphasis`, `title`, `toolbar`, `heading` | 13 to 16 pt | bold |
| `illustration`, `action` | 20 and 24 pt | one-cell glyph |

**Row pitch.** On macOS every clickable row is 24 pt from the top of one row to the top of the next, which keeps every hit target at least 24 pt tall. Rows are frame metrics owned by their view, not spacing steps. In the TUI every single-line row is one row.

## Rules every surface follows

These are what the layout audit measures.

1. **One leading edge per panel.** The header text, section labels, the glyph column of rows and the first line of an empty state start at the same x position (macOS) or column (TUI). Indented content aligns with the text it belongs to, not with the glyph before it.
2. **Fixed key columns.** Wherever keys sit in a column (which-key, menus, action lists, hints in a list), the column is as wide as the widest key in that panel plus `md`, so every label starts at the same edge.
3. **One baseline per row.** Text in a row shares a baseline; glyphs are centred on the line.
4. **Right-hand meta is right-aligned** with the panel's trailing inset, and keeps at least `xl` from the label before it. When space runs out, the label truncates with `…` before the meta drops.
5. **Nothing clips.** Text either fits, truncates with `…` at a word boundary, or wraps where the part allows wrapping. A clipped glyph or half a key is a failure.
6. **The same part measures the same everywhere.** A list row in the tasks drawer and a list row in the diagnostics drawer have identical insets, gaps and pitch.

## Drawer

A real split along the bottom of the window. Structure: divider, header, body.

| Part | Token | macOS | TUI |
|---|---|---|---|
| Divider | `pixel` | 1 pt line, 5 pt hit area | the drawer's top border row |
| Header height | row pitch | 24 pt | in the top border |
| Header leading and trailing inset | `lg` | 12 pt | 1 column |
| Title to counts | `md` | 8 pt | 1 column |
| Key to its hint label | `xs` | 4 pt | 1 column |
| Hint to next hint | `xl` | 16 pt | 2 columns |
| Body leading and trailing inset | `lg` | 12 pt | 1 column |
| Body top inset | `sm` | 6 pt | 0 rows |

The title uses `emphasis` semibold; counts and hints use `small` in the secondary colour, keys in the accent colour. In the TUI the title and counts sit in the top border and the hints in the bottom border, only while the drawer has focus. There is no second hint line on either frontend.

## List row

One row of a list buffer: tasks, review, diagnostics, the switcher, quickfix.

| Part | Token | macOS | TUI |
|---|---|---|---|
| Pitch | row pitch | 24 pt | 1 row |
| Selection edge | `accent` | 3 pt bar in the row's role colour at the leading edge | `▌` in the row's role colour, column 0 |
| Glyph to title | `sm` | 6 pt | 1 column |
| Title to meta | `xl` minimum | 16 pt | 2 columns |
| Trailing inset | `lg` | 12 pt | 1 column |
| Selection background | `Radius.sm` | rounded, inset `xs` from the panel edges | full-width bar |
| Expanded sub-lines | aligned to the title | the title's x position | the title's column |

The title uses `body`; state words and age use `small` in the secondary colour. A needs-you row that expands shows its request and its actions on sub-lines aligned with the title, with the actions laid out like drawer hints (`xs` inside a hint, `xl` between hints).

## Section label with rule

Groups inside a menu, a hover or a long list.

| Part | Token | macOS | TUI |
|---|---|---|---|
| Label | `caption` semibold, Title Case | 10 pt, secondary colour | faint |
| Label to rule | `md` | 8 pt | 1 column |
| Rule | `pixel` | 1 pt line in the quiet border colour, to the trailing inset | `─` in the quiet border colour, to the border |
| Space above the label | `xl` | 16 pt | 0 rows |
| Space below the label | `xs` | 4 pt | 0 rows |

## Decision bar

The top of the act menu and every surface where Minga asks a yes or no question. Two equal halves.

| Part | Token | macOS | TUI |
|---|---|---|---|
| Inset from the panel edge | `md` | 8 pt | 1 column |
| Gap between halves | `xs` | 4 pt | 1 column |
| Half corner | `Radius.md` | 6 pt | square |
| Half vertical padding | `sm` | 6 pt | 0 rows |
| Key to label | `sm` | 6 pt | 1 column |
| Label to consequence | `hairline` | 2 pt | next row |
| Height | content | label plus consequence, at least 44 pt | 2 rows |

The label uses `emphasis` semibold, centred; the consequence uses `caption` in the secondary colour, centred below. The selected half fills with the target's role colour (TUI: reverse video in that role). The no half is never preselected.

## Popover and menu

The act menu, the twist-head menu's successor, and any compact panel at a target.

| Part | Token | macOS | TUI |
|---|---|---|---|
| Corner | `Radius.lg` | 8 pt | rounded border |
| Edge colour | role | target's role colour on the leading edge | the border in the target's role colour |
| Header | row pitch | 24 pt: glyph, `xs`, target words; "› filter" right-aligned | in the top border |
| Header to first block | `md` | 8 pt | 0 rows |
| Row pitch | row pitch | 24 pt | 1 row |
| Row leading and trailing inset | `md` | 8 pt | 1 column |
| Menu key column | fixed | widest key plus `md` | widest key plus 1 column |
| Label to direct key | `xl` minimum | 16 pt, direct key right-aligned | 2 columns, right-aligned |
| Width | content | 280 to 420 pt | 36 to 64 columns |
| Panel vertical padding | `xs` | 4 pt | 0 rows |

Labels use `body`; menu keys and direct keys use `Typography.monospacedSmall`, direct keys in the secondary colour. Help sits in the bottom border in the TUI and is absent on macOS. The panel is exactly as tall as its content.

## Which-key panel

One panel anchored above the modeline.

| Part | Token | macOS | TUI |
|---|---|---|---|
| Corner | `Radius.lg` | 8 pt | rounded border |
| Margin from the window edges | `md` | 8 pt | 0 columns, full width |
| Inset | `lg` horizontal, `md` vertical | 12 pt, 8 pt | 1 column, 0 rows |
| Breadcrumb | row pitch | 24 pt header row | in the top border |
| Column gap | `panel` | 24 pt | 3 columns |
| Group name to first entry | `xs` | 4 pt | 0 rows |
| Entry pitch | row pitch | 24 pt | 1 row |
| Key to label | `md` | 8 pt, in a fixed key column | 1 column, in a fixed key column |
| Label to ⌘ equivalent or count | `md` | 8 pt | 1 column |

Keys use `Typography.monospacedSmall` in the accent colour; leaves use `body`; groups use `body` in the group role with a trailing `›`; group names above columns use `caption` in the secondary colour; counts use `caption`. Each column is as wide as its longest entry, and the panel is as tall as its longest group plus the breadcrumb.

## Modeline segments

| Part | Token | macOS | TUI |
|---|---|---|---|
| Leading and trailing inset | `sm` | 6 pt | 1 column |
| Gap between segments | `md` | 8 pt | 1 column |
| Glyph to words | `xs` | 4 pt | 1 column |
| Mode pill padding | `sm` horizontal, `hairline` vertical | 6 pt, 2 pt | 1 column each side, 0 rows |
| Mode pill corner | `Radius.sm` | 4 pt | square, reverse video |
| Hit area | row pitch | the modeline's full height, at least 24 pt | the segment's cells |

The modeline height is a frame metric owned by the status bar. Text uses `small`; the mode pill uses `small` semibold. The left cluster starts at the leading inset and the right cluster (filetype, position) is right-aligned at the trailing inset. Truncation follows [surfaces.md](surfaces.md#modeline) and never changes the gaps.

## Prompt and minibuffer

The command line, confirmations, and the query row of a picker.

| Part | Token | macOS | TUI |
|---|---|---|---|
| Leading inset | `sm` | 6 pt, same as the modeline | 1 column |
| Prompt label to query | `md` | 8 pt | 1 column |
| Chip padding | `sm` horizontal, `hairline` vertical | 6 pt, 2 pt | 0 columns; the key is a reverse-video cell |
| Chip corner | `Radius.sm` | 4 pt | square |
| Key to label inside a chip | `xs` | 4 pt | 1 column |
| Chip to chip | `xl` | 16 pt | 2 columns |
| Query row to results | `xs` | 4 pt | 0 rows |

The prompt label uses `body` semibold; the query uses `body`. Picker results are list rows.

## Empty state

Every empty state and every notice with actions, as listed in [surfaces.md](surfaces.md#empty-states-and-notices-with-actions).

| Part | Token | macOS | TUI |
|---|---|---|---|
| Inset from the panel | `panel` | 24 pt | 3 columns, 1 row |
| Glyph to title | `sm` | 6 pt | 1 column |
| Title to why line | `xs` | 4 pt | 0 rows |
| Why line to action list | `xxl` | 20 pt | 1 row |
| Action pitch | row pitch | 24 pt | 1 row |
| Action key column | fixed | widest key plus `lg` | widest key plus 1 column |

The title uses `emphasis` semibold; the why line uses `body` in the secondary colour; action keys use `Typography.monospacedSmall` in the accent colour; labels use `body`. The first action is preselected with a list-row selection.

## Notice

Notices live in the echo line, not in floating toasts, on both frontends. A notice that lasts becomes a persistent modeline segment (see [surfaces.md](surfaces.md#errors-and-notices)).

| Part | Token | macOS | TUI |
|---|---|---|---|
| Leading inset | `sm` | 6 pt, same as the modeline | 1 column |
| Message to first action | `md` around a `·` | 8 pt each side | 1 column each side |
| Action to action | `md` around a `·` | 8 pt each side | 1 column each side |
| Key to its action word | `xs` | 4 pt | 1 column |

The message uses `body`; keys use `Typography.monospacedSmall` in the accent colour; action words use `body` in the secondary colour.

## Hover popover

`K` and the pointer resting on a target.

| Part | Token | macOS | TUI |
|---|---|---|---|
| Corner | `Radius.lg` | 8 pt | rounded border |
| Inset | `lg` horizontal, `md` vertical | 12 pt, 8 pt | 1 column, 0 rows |
| Offset from the target line | `xs` | 4 pt, never over the cursor line | the next free row, never over the cursor line |
| Between sections | `pixel` rule with `md` above and below | 1 pt rule, 8 pt each side | a `─` row |
| Maximum size | frame | 480 by 320 pt, then scrolling | 72 columns by 12 rows, then scrolling |
| Footer | `caption` | "`g.` actions", right-aligned | in the bottom border |

The section order is diagnostic, signature, docs, attribution, as in [surfaces.md](surfaces.md#hover). Headings use `body` semibold, prose `body`, code `Typography.monospacedSmall`, attribution `caption` in the secondary colour. Pointer tooltips in the TUI go to the echo line instead of a popover.

## Changing a measurement

1. Change the token or the part here first, with the intent.
2. Change `ChromeTokens.swift` and `chrome_tokens.go` in the same pull request when a scale changes; both guards fail on a literal, so there is no other way in.
3. Let the storyboard factory re-render the affected scenarios. The layout audit must pass, and the new renders replace the baselines once reviewed.
