# Storyboard

Two frontends drift apart one reasonable local decision at a time. Prose specs and hand-drawn mockups do not stop that, because nothing fails when the code disagrees with them. The plan is to make the design executable: one list of scenarios, drawn by the real renderers on both frontends, with checks for dead ends.

## Two tracks, one scenario list

**1. The design storyboard (now).** An inventory of every screen and state on both frontends, in [`scenarios.toml`](scenarios.toml), each tagged:

- **designed**: a design board exists and follows these rules;
- **existing-only**: the screen exists in the app but has not been redesigned;
- **missing**: no design and no implementation.

Designed scenarios get a design-time flow map: every exit by key and by click. Missing scenarios get design boards, in batches, for both frontends. The canvas shows the inventory as a grid, so gaps are visible as empty cells.

**2. The storyboard factory (after design tokens).** The same scenario ids become fixtures that build editor state through the BEAM. Each scenario produces the semantic render model once; the macOS harness renders it offscreen, and the Go TUI renders it to ANSI and then to an image. A generated page lays out every scenario in columns (macOS, macOS narrow, TUI, TUI at 16 colours), and CI publishes it on every UI pull request with a visual diff against `main`.

The factory renders today's UI first, as a baseline. Each migration change then switches its scenarios to the new design, with the design board beside the rendered frame as its acceptance target.

## Parity rule

Every scenario renders on both frontends, or is tagged platform-only with a written reason (for example, "Dock badge: macOS only; the TUI uses a desktop-notification escape code").

## The flow graph

Screens are nodes; keys and clicks are edges. The edges are not written by hand: the scope that is active in a scenario already lists every key that can fire there. An explorer starts the headless editor in each scenario, presses every available key, and classifies the resulting state back into a scenario id. A result it cannot classify is reported as an unaccounted-for screen.

These invariants are checked in CI:

1. **Reachable.** Every scenario can be reached from a cold start by keyboard alone, and separately by mouse alone.
2. **Always a way out.** From any scenario, at most three presses of `esc` or `q` return to plain editing with focus restored to the window you came from.
3. **Every state has a next action.** Needs you, waiting, failed and done each offer at least one action wherever they appear; waiting says what it waits for and how long.
4. **Every error names its next step.** The semantic notice type requires a next action, so an error without one cannot be built.
5. **Empty states exist.** Every list surface has a defined zero case; an empty list never renders as blank space.
6. **No orphan keys.** Every key in a scope leads to a defined state, every which-key prefix has at least one child, and no binding is silently a no-op.
7. **Keyboard and mouse parity per edge.** Every transition has a key path and a click path, unless tagged keyboard-only with a reason (operators like `vah`).
8. **Interruptions do not strand you.** When something starts needing you during which-key, a drawer, the composer or the terminal, nothing steals focus, the new state is one step away, and your context survives.

A random key-walk property test runs on top: it presses keys from the current scope and asserts invariants 2 and 6 after every step.

## Running the inventory checks

The inventory lives in [`scenarios.toml`](scenarios.toml). Three scripts in [`design/tools/storyboard/`](../../design/tools/storyboard/) read it. They need Python 3.11 or newer and no packages.

```bash
python3 design/tools/storyboard/check.py
OUT_DIR=/tmp/minga-boards python3 design/tools/storyboard/inventory.py
OUT_DIR=/tmp/minga-boards python3 design/tools/storyboard/flowmap.py
```

### Keyboard first, then the mouse sweep

The storyboard is designed keyboard first: every scenario gets a best-in-class keyboard path before anyone designs its mouse path. Then each scenario gets a mouse sweep, case by case, choosing the click path that suits that screen. The sweep happens inside the storyboard, before a surface is accepted for building, never after it ships (AGENTS.md: mouse is not a follow-up).

`scenarios.toml` records which phase the design is in with `phase = "keyboard"` or `phase = "final"`. In the keyboard phase, `check.py` reports missing click paths (scenarios unreachable by clicks, and transient exits with a key but no click) as "pending mouse sweep" and does not fail on them. Pass `--final`, or set `phase = "final"`, to treat them as violations. Every other invariant fails in both phases.

The mouse sweep is done and the inventory is in the final phase: every scenario is reachable by click from a cold start, and a new screen without a click path fails the checker. The seven patterns are in [surfaces.md](surfaces.md#mouse).

```bash
python3 design/tools/storyboard/check.py           # uses the phase in scenarios.toml (final)
python3 design/tools/storyboard/check.py --final   # everything, including mouse gaps
```

### What the checker reports

`check.py` prints every violation of the flow invariants it can check from the inventory and exits with status 1 if there are any:

- exits that point at a scenario that does not exist;
- scenarios you cannot reach from a cold start by keys, and separately by clicks;
- dead ends: scenarios with no way back to a resting view within 3 presses of `esc` or `q` (or an exit marked `back`, such as `⌃\ ⌃N` in a terminal);
- lists without an empty state;
- transient surfaces with an exit that has a key but no click, or a click but no key, unless the exit says why with `keyboard_only`.

Scenarios that happen to you rather than places you go (errors, notifications, Minga asking a question) set `reached_by` and count as reachable. A list reaches its empty state the same way it is reached.

`inventory.py` draws every scenario as a tile, grouped by journey and coloured by status. `flowmap.py` draws the designed scenarios as a graph: each edge carries its keys, each node lists the keys that return to editing (⤺), and dead ends, scenarios without a mouse path and scenarios without a key path are marked. Both write `.dc.html` boards for the design canvas.

The checker is the design-time version of the flow-graph invariants above. When the storyboard factory exists, the same rules run against the real editor.

## Journey strips

The main journeys run as scripted flow tests that also emit a strip of frames for the storyboard page:

- approve a request;
- review and keep a change;
- recover from a rate limit;
- a test fails, you ask Minga to fix it, then review the fix;
- open a file across a multi-file change;
- peek into a subagent and step through its siblings.

A broken step fails CI; reviewers read the strip frame by frame on both frontends.

## Codifying the vocabulary

The factory depends on the frontends drawing from the same vocabulary, so the vocabulary becomes generated code before the factory exists:

- **Design tokens** in one file, generated by `mix codegen` into Swift, Go and Elixir: colour roles, the six state words and their five shapes (glyph, word, colour, terminal glyph, accessibility label), twist variants, and voice strings. A guardrail test rejects hard-coded colours outside the generated files.
- **Marks** as source assets in [`marks/`](marks/), consumed by the macOS asset catalog and mapped to terminal glyphs in the tokens.
- **Keys** stay in the keymap code. `keys.md` and the which-key layout become generated from the scope tries, with tests for the rules in [keys.md](keys.md#rules).
- **Ordering decisions** move to the semantic model. For example, the BEAM sends modeline segments with priorities, and a frontend only drops the lowest priorities to fit its width, the same split as [ADR-0001](../adr/0001-frontend-owns-row-fit.md).

## Order of work

1. Record the design (ADR-0006 and these files).
2. Build the inventory and the design-time flow map; design the missing scenarios in batches.
3. Design tokens and code generation.
4. The storyboard factory: scenarios on both renderers, then the flow graph, then journey strips.
5. Surface-by-surface migration, each landing with its scenarios.
