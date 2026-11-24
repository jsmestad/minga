# Storyboard

Two frontends drift apart one reasonable local decision at a time. Prose specs and hand-drawn mockups do not stop that, because nothing fails when the code disagrees with them. The plan is to make the design executable: one list of scenarios, drawn by the real renderers on both frontends, with checks for dead ends.

## Two tracks, one scenario list

**1. The design storyboard (now).** An inventory of every screen and state on both frontends, in [`scenarios.toml`](scenarios.toml), each tagged:

- **designed**: a design board exists and follows these rules;
- **existing-only**: the screen exists in the app but has not been redesigned;
- **missing**: no design and no implementation.

Designed scenarios get a design-time flow map: every exit by key and by click. Missing scenarios get design boards, in batches, for both frontends. The boards are committed in [`design/boards/`](../../design/boards/README.md), and the inventory board shows every scenario as a grid, so gaps are visible as empty cells.

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

`inventory.py` draws every scenario as a tile, grouped by journey and coloured by status. `flowmap.py` draws the designed scenarios as a graph: each edge carries its keys, each node lists the keys that return to editing (⤺), and dead ends, scenarios without a mouse path and scenarios without a key path are marked. Both write `.dc.html` boards; `sh design/tools/rebuild_boards.sh` publishes them to `design/boards/` with the rest.

`check.py` also fails when a scenario's `boards` names a file that is not in `design/boards/`, so every designed scenario has an acceptance target an agent can open.

The checker is the design-time version of the flow-graph invariants above. The storyboard factory runs the same rules against the real editor.

## The storyboard factory

The design-time checker trusts the inventory; the factory checks the running editor. It lives in `test/support/storyboard/` (compiled in the test environment, so other suites can call it) and runs as `test/storyboard/`, tagged `:storyboard`, in the **Storyboard (Elixir)** CI job.

```bash
mix test --only storyboard test/storyboard
```

**The registry.** `Minga.Test.Storyboard.Registry` has one entry per scenario id, one module per journey under `test/support/storyboard/scenarios/`. A built entry names its key path from the cold start (`reach`), a recognizer that classifies a semantic model as that scenario, and its design checks. A pending entry names the surface ticket that builds it; the suite prints the pending list and never fails on it. `registry_test.exs` fails when a designed id in `scenarios.toml` has no entry, or when an entry names an id the inventory does not have.

**The cold start.** Until the home buffer lands (#4056), the factory starts every scenario from a headless editor with one Elixir file open in Normal mode, which is `edit.plain`.

**The parser.** Every session runs the real tree-sitter parser, so structural motions, text objects, folds and highlighting behave as they do in the app, and a key that needs the syntax tree is never reported as doing nothing. `test/test_helper.exs` starts one shared `Minga.Parser.Manager` before any test runs (its Port is an OS process, which async tests must not spawn concurrently); each session registers its buffer with it and returns only once the highlights are applied. Build the parser with `mix native.build.support` before running the suite. Each session's buffer edits reach the shared parser through `Minga.Test.Storyboard.ParserRelay`, because every session keeps its own private events registry.

**Design checks.** `Minga.Test.Storyboard.Assertions` asserts against the semantic model by structure and token name, never by pixel: modeline segment order, which-key groups and counts, state words and colour roles from `Minga.Design.Tokens`, keys shown on transient surfaces, the open and focused surface, and the empty-state anatomy. A check that waits on a ticket is written with `Check.pending/3`; the suite runs it anyway and fails when it starts to pass, so the ticket that lands the surface turns it on.

**The flow explorer.** `Minga.Test.Storyboard.Explorer` presses every key the active trie offers from every built scenario (the Vim normal keys and every leader binding from `edit.plain`, every which-key child from a which-key scenario), plus the scenario's designed exits, each from a fresh editor. Keys come from the keymap, so they follow key moves. It classifies where each key lands, checks the way out within three presses of `esc` or `q`, and prints the screens it cannot classify. A random key walk (`key_walk_property_test.exs`) checks the way out and a defined state after every step. Violations that exist today are listed with their issue in `test/fixtures/storyboard/known_violations.tsv`; the list only shrinks.

**Reuse.** The factory is pure data in, semantic model out, so other suites (the frame renderer in #4036) drive the same scenarios and journeys:

```elixir
session = Minga.Test.Storyboard.Registry.drive("edit.whichkey.leader", rendering: :enabled)
model = Minga.Test.Storyboard.Session.model(session)
{:pending, _scenario, _issue, frames} = Minga.Test.Storyboard.Journeys.run(journey)
```

`Session.model/1` returns a `Minga.Test.Storyboard.Model` (the `Minga.RenderModel.UI` plus derived facts); `Journeys.run/2` returns the frames it saw, one per step, as far as the first pending surface.

## Renders and baselines

The factory's semantic checks prove what a frame says. Renders prove what each frontend draws: every built scenario is drawn by the real renderers on both frontends, and those drawings, not the boards, are the baselines a pull request is compared against.

**What renders.** Each built scenario renders in three themes (Catppuccin Frappé, astrodark and Catppuccin Latte), in the terminal at 80x24, 120x40 and 150x38, and on macOS in windows 1440 and 1280 points wide. `Minga.Test.Storyboard.Render` drives the scenario once per frontend, theme and size, tells the editor the capabilities that frontend reports, and records every packet the editor sends. The frontends replay those packets through their production decoders:

- the Go TUI in `go/tui/internal/ui/storyboard_render_test.go` writes a text grid with its style runs (every cell's colours and attributes);
- macOS, in PreviewHost's storyboard mode, hosts the production `ContentView` and Metal editor in a real window and writes a PNG plus an export of every anatomy part the chrome tags with `View.anatomyPart(_:)`: its frame, text and baseline in window points.

The text-grid snapshots of the existing snapshot system (`test/storyboard/render_test.exs`, `docs/SNAPSHOT_TESTING.md`) run in the same suite. Images are for people; the text grids and part exports are the baselines.

**The editor grid on macOS.** The BEAM lays out in the rows and columns the frontend reports (ADR-0001), so each macOS window size has its grid in `test/storyboard/macos_geometry.json`. The macOS renderer measures its own row fit and fails with the measured grid when the file disagrees, for example after a chrome change moves the editor's edges.

**Baselines.** `test/storyboard/baselines/<scenario>/` holds one file per frontend, theme and size, and `promotion.json` records the commit that produced them. CI fails when:

- a render does not match its committed baseline (a stale baseline);
- a built scenario has no baseline, or a baseline has no render (a size, theme or scenario went away);
- a scenario changed against the base branch on one frontend but not the other, unless the scenario's promotion is tagged platform-specific with a reason.

A scenario's first renders become its baseline once they pass the layout audit and visual review. Pending scenarios are listed, never rendered and never failures.

**Running it.** From the repository root, with the pinned Elixir and Go toolchains:

```bash
python3 design/tools/storyboard/renders.py render        # transcripts and TUI frames in _build/storyboard
python3 design/tools/storyboard/renders.py render-macos  # macOS frames (macOS with Xcode only)
python3 design/tools/storyboard/renders.py diff          # against the committed baselines and main
python3 design/tools/storyboard/renders.py page          # _build/storyboard/page/index.html
```

**Accepting a change.** One command updates the baselines:

```bash
gh run download <run-id> -n storyboard-macos -D /tmp/storyboard-macos   # macOS frames from the PR's CI run
python3 design/tools/storyboard/renders.py promote --macos /tmp/storyboard-macos
```

`promote` renders the TUI locally, copies both frontends' renders into the baseline store and records the commit. macOS baselines always come from CI, because the runner's fonts and SDK decide the exact frames; without `--macos` only the TUI baselines move. When a change is meant for one frontend only, add `--platform-specific 'macos:the reason'` (or `tui:`) so the parity check accepts it. `promote` also accepts the scenarios' text-grid snapshots, so one command updates every baseline.

**In CI.** The **Storyboard (Elixir)** job records the transcripts and draws the TUI frames. **Storyboard renders (macOS)** draws the macOS frames on `macos-15` whenever native sources changed, a macOS-only input changed (the renderer's tools, the window grid, the baselines), or the packets for a macOS frame differ from the ones its baseline was promoted from (each promotion records a digest of them). When it is skipped, its frames equal their baselines by construction, so the parity check still applies. **Storyboard renders** compares both with the baselines, checks parity, writes the changed scenarios to the job summary and publishes the generated storyboard page as the `storyboard-page` artifact: scenarios in rows, frontends and sizes in columns, a theme switch, and the journeys below as frame strips. It is part of the CI gate.

## Journey strips

The main journeys run as scripted flow tests that also emit a strip of frames for the storyboard page:

- approve a request;
- review and keep a change;
- recover from a rate limit;
- a test fails, you ask Minga to fix it, then review the fix;
- open a file across a multi-file change;
- peek into a subagent and step through its siblings.

A broken step fails CI; reviewers read the strip frame by frame on both frontends. The journeys are scripted in `Minga.Test.Storyboard.Journeys`, each step a designed exit from `scenarios.toml`, and run in `test/storyboard/journeys_test.exs` up to their first pending surface.

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
