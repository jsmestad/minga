# Visual review rubric

A pull request that changes how a scenario looks is checked twice. The hard gates decide whether it merges: the semantic checks of the storyboard factory, the conformance transcripts, the snapshots, the render baselines and the layout audit. Visual review catches what those cannot see: a surface that is measured correctly and still reads badly, or one that tells a different story on each frontend. It never blocks a merge. What it raises goes to the visual follow-ups issue ([#4071](https://github.com/jsmestad/minga/issues/4071)).

This page is the fixed rubric the reviewer agents and the polish critic apply. The procedure that runs them is in [Run the visual review](../recipes/visual-review.md).

## Boards are structure, never pixels

Each scenario's board in `design/boards/` fixes **structure**: which parts a surface has, their order, their words, the keys it shows, and the glyphs and marks it uses. A board is never compared pixel for pixel with a render, never measured, and never a diff target. Spacing, sizes and colours come from [anatomy.md](anatomy.md), [themes.md](themes.md) and the token scales on both frontends. A render that differs from its board in polish is judged against anatomy, not against the board.

## What a reviewer is given

- the changed scenario ids, from the CI diff (`diff.json` in the `storyboard-page` artifact);
- for each changed scenario, the rendered frames on both frontends in every theme and size: TUI frames as PNGs drawn cell by cell from the Go renderer's text grid and colours (the grid itself is there too, for exact cells), macOS frames as captured;
- the scenario's board, rendered to a PNG with headless Chrome;
- this rubric and [anatomy.md](anatomy.md).

Reviewers never see each other's verdicts, and the critic never sees the reviewers'.

## Structure, against the board

Answer each question for both frontends. A difference the board explains as platform-specific (for example a native control on macOS) is not a concern.

1. **Parts.** Every part the board shows is present, and nothing is present that the board does not show.
2. **Order.** Parts appear in the board's order: left to right, top to bottom, and in the board's grouping.
3. **Words.** Labels, titles, state words and hints use the board's words, in sentence case or the case the board shows. Nothing is abbreviated that the board spells out.
4. **Keys shown.** Every key the board shows on the surface is shown, in the same notation (`SPC f f`, `⌃\ ⌃N`, `esc`).
5. **Glyphs and marks.** States use the shapes in [marks.md](marks.md); a glyph means the same thing everywhere it appears.
6. **One story on both frontends.** Someone who sees only the macOS frame and someone who sees only the TUI frame would describe the same surface, in the same state, with the same next action.

## Polish, against anatomy

1. **Hierarchy.** The eye lands first on what the surface is for: the title or the selected row, then the content, then hints. Weight and colour role carry hierarchy, never size alone in the TUI.
2. **Colour roles.** Every colour is the role [themes.md](themes.md) assigns to that meaning: text, text_muted, group, minga, needs_you and so on. A role is never reused for a different meaning on the same screen. Syntax colours in code read at a glance in every theme.
3. **Spacing rhythm.** Gaps follow the order in anatomy: a key sits closer to its label than one hint sits to the next, and blocks are separated more than rows. Nothing looks cramped or floats loose.
4. **Line metrics.** macOS chrome sets 13 px text on 18 px lines and 24 pt rows; the TUI gives each single-line row one terminal row, about 1.25 times the text height. Text is vertically centred in its row.
5. **Alignment.** One leading edge per panel; labels in a key column start at one edge; right-hand meta is right-aligned.
6. **Truncation and clipping.** Text either fits or ends in `…` at a word boundary where the part allows it. A clipped glyph, half a key or a label cut without `…` is a concern.
7. **Light and dark.** The light theme (Latte) reads as well as the dark ones: nothing washed out, no border that disappears.

## The quality bar

The critic compares changed surfaces with the best current Minga surfaces, which set the bar:

- the editor with highlighted code (`edit.plain`) on both frontends;
- the which-key panel (`edit.whichkey.leader`) on macOS;
- the modeline in Normal and Visual mode (`edit.plain`, `edit.visual`).

and with Apple's Human Interface Guidelines for macOS: [Layout](https://developer.apple.com/design/human-interface-guidelines/layout), [Typography](https://developer.apple.com/design/human-interface-guidelines/typography) and [Color](https://developer.apple.com/design/human-interface-guidelines/color).

## Output

Each reviewer returns one line per changed scenario:

```json
{"scenario": "edit.whichkey.leader", "reviewer": "structure-1", "verdict": "pass", "notes": "..."}
```

`verdict` is `pass` or `concern`. `notes` names the frontend, theme, size and part, and the rubric question it fails ("Structure 3, words"). Each critic round returns a list:

```json
{"scenario": "edit.whichkey.leader", "part": "whichKey.entry", "issue": "...", "suggested": "row pitch 24 pt (anatomy: which-key entry pitch)"}
```

The implementer fixes the items it accepts and records a reason for each it declines. The loop stops after a round with no items, or after three rounds.

## What happens to a concern

Every concern, every disagreement between the reviewers, every critic item left open after the last round, and every matter of taste is appended to [#4071](https://github.com/jsmestad/minga/issues/4071) in its entry format. None of them changes the merge decision.
