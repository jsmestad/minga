# Runs workstream

**Status:** Not started. The design is [docs/design/runs.md](../design/runs.md). The decisions are [ADR-0010](../adr/0010-runs.md) and [ADR-0011](../adr/0011-buffer-drawers.md), both Accepted on 2026-11-28. Epic: [#4385](https://github.com/jsmestad/minga/issues/4385). Filed so far: Spike A [#4386](https://github.com/jsmestad/minga/issues/4386), Spike B [#4387](https://github.com/jsmestad/minga/issues/4387), S0 [#4388](https://github.com/jsmestad/minga/issues/4388), S1 [#4389](https://github.com/jsmestad/minga/issues/4389). S2 to S6 are not ticketed.

This page is the plan: what has to be decided, what has to be proven before code is built on it, and the slices in order. Each slice ships complete. None leaves a foundation the next one has to rework.

## What you get, and when

| After | You get | Can you stop using an outside terminal for tests? |
|---|---|---|
| R | Two edits in different places of a buffer, landing in one frame, re-send only their own rows. [#4397](https://github.com/jsmestad/minga/issues/4397) | n/a |
| S0 | Folded and decorated buffers scroll locally like plain ones | n/a |
| S1 | `:!` and test keys open a drawer under your file with coloured, foldable, stoppable output. Your window is never taken | No: there is no jump from the file to an error |
| S2 | A run segment in the modeline, `SPC c c` to run, `SPC c C` to rerun, a stop list, `SPC ~` to hide the drawer | No |
| S3 | `]q` jumps to the next error from anywhere. The red-green loop is 8 keys | **Yes** |
| S4 | The drawer opens by itself when a check fails and closes when the rerun passes | Yes |
| S5 | Minga's own commands appear in the same buffer, with approvals | Yes |
| S6 | Runs in the switcher, the full act menu, Fix with Minga | Yes |

S1 and S2 alone are a better output buffer and nothing more. Plan S1 to S3 as one run of work with no other project between them.

## Ordering against the Spine

- #4060 slice 1 (Zig 0.17) lands before S1 writes `minga-run`. S1 writes its PTY and process-group code as a module `minga-terminal` can link.
- #4052 (the act menu, PR #4391) merges before S2 or S6 add a target to it. It merged on 2026-11-28.
- S1 defines the block-state and strand fields in the protocol once. #4061 reuses them.
- #4061 depends on S2, for the shared command-block target. S5 depends on nothing from #4060.
- S0 (#4388) changes rendering code Spine tickets share; see its coordination note.

## A prerequisite Spike B found

**R: one range per edit in the resident delta path.** `resident_delta_fetch_range/2` in `lib/minga_editor/render_pipeline/buffer_prefetch.ex` computes one bounding range over every pending edit. Two distant edits in one frame re-send everything between them. This is not specific to runs: an agent editing two places in a file, a multi-site rename and a format that touches the top and the bottom all hit it.

- **Order:** R, then S0, then S1. A folded window keeps up today only because it takes the windowed path. S0 makes it resident, so S0 before R would move `*run*` onto the path that freezes.
- **Done when:** `bench/run_buffer_stream.exs` (branch `spike/run-buffer-throughput-4387`) without `RUN_BENCH_SERIAL` shows every flush carried by a row delta, no frame over 16 ms p95 and the Editor mailbox bounded, for scenarios B and C at 50,000 rows; and frame time is measured on both real frontends, which Spike B did not do.
- **If it cannot be done inside the row-delta path:** one buffer per run, and the design returns to review.
- Ticket: [#4397](https://github.com/jsmestad/minga/issues/4397). It changes rendering code the Spine shares, so it needs the same coordination as S0 ([#4388](https://github.com/jsmestad/minga/issues/4388)).

## Decisions needed before S1

1. **Accept S0 as a prerequisite.** `*run*` folds its blocks and marks dropped output with a virtual row. A window with folds, decoration fold regions, virtual lines or block decorations is not in the resident store today; it uses the windowed path. The resident-scroll workstream lists folded residence as a deferred remnant. Without it, `*run*` would be the one buffer that scrolls the old way.
2. **Accept or change ADR-0010 and ADR-0011. Done: both accepted on 2026-11-28, ADR-0010 with two conditions (#4397 and the row ceiling).** They fix the run record's owner, the shared runner, the PTY helper and how a buffer drawer is laid out.
3. **Head and tail at the cap.** The design keeps the first 2,000 and last 8,000 lines of a run. Confirm, or pick another split.

## Decisions needed before S4

4. **Background completion (principle 7).** The design changes only the modeline and the echo line when a run ends. Whether a long run may post one passive notification when Minga is not frontmost, and show progress on the Dock icon, needs an ADR either way. Without it a ten-minute test run that ends while you are in the browser leaves no trace outside the window.
5. **`esc` closes a drawer that opened by itself. Decided 2026-11-28: it does not.** `esc` never closes an unfocused drawer; `SPC ~` or a click does.
6. **Hover shows the drawer header's hints on macOS.** The tasks drawer does not do this today. If the run drawer does, the tasks drawer should too.

## Prove before building on it

Two assumptions carry the design. Each gets a spike with a written result before the slice that depends on it is ticketed in detail.

### Spike A: the PTY helper (blocks S1)

**Done.** Result and tables: [#4386](https://github.com/jsmestad/minga/issues/4386). Recommendation: build `minga-run` as designed, with the command in a background process group of a session whose controlling terminal is the PTY, and with a settings change ending the run as well as a read. The questions below are kept as the record of what was asked.

Build the smallest `minga-run`: allocate a PTY for stdout and stderr, give the child `/dev/null` as stdin, own the process group, report exit.

Answer, on macOS and Linux:

- Does the child get the PTY as its controlling terminal, and what do `git commit` (no `-m`), `sudo -v` and `ssh host` do in each case: fail fast, hang, or exit on their own?
- Can the helper tell that a process forked by `sh` opened the terminal for input, so the run ends as "needs keyboard input"?
- Do `jest --watch` and `vitest` run without their key listener when stdin is not a terminal?
- What do `docker build`, `cargo build`, `mix test`, `npm install`, `rg` and `ls` print with `TERM=xterm-256color`, a fixed size and the documented environment? Is any of it unreadable as rows with colour and carriage returns?
- What does Minga's agent read from the same commands once colour is stripped, compared with today's pipe?

Done when: a table of those commands with what each printed and how each ended, and a yes or no on the "needs keyboard input" detection. If the answer is no, the design's reason for that failure becomes a plain exit code and the sentence in the design is removed.

### Spike B: an interleaved, folding buffer in the resident store (blocks S1, informs S0)

**Done on the BEAM side; frame time on the real frontends not run.** Result and tables: [#4387](https://github.com/jsmestad/minga/issues/4387). As the store is today, two runs streaming into one buffer freeze the view, because edits that land in one frame are merged into one bounding range. With one frame per edit the same workload costs 2.5 ms and 4 rows per frame. Recommendation: keep one buffer per project, after the resident delta path fetches one range per edit. The questions below are kept as the record of what was asked.

`*run*` is not append-only: an older running block grows above newer ones, and eviction deletes in the middle.

Measure, with two runs streaming at once into one buffer of 50,000 rows with folded blocks: frame time on both frontends, row-delta size per flush, and Editor mailbox depth, at 30 flushes a second per run.

Done when: numbers in the ticket, the bench script under `bench/`, and a yes or no on whether row deltas keep up. If no, the fallback is one buffer per run with the drawer switching between them, which changes the design's "one `*run*`" decision and goes back to review.

## Slices

Each slice lists what it delivers, the main work, and how to tell it is done. Ticket each one from this page when its turn comes; do not ticket S3 onward in detail until spike results are in.

### S0: folded and decorated residence

- **Delivers:** an unwrapped buffer with folds, decoration fold regions, virtual lines or block decorations is resident and scrolls locally on both frontends. A buffer that is both wrapped and folded is a follow-up.
- **Work:** fold-aware promotion in the resident store; fold open and close as a `layout_generation` change or a row splice, whichever the measurement supports; conformance transcripts for folded buffers.
- **Done when:** a 20,000-line file with 50 folds scrolls locally on macOS and the TUI, the windowed path no longer serves folded panes, and the keystroke latency job does not move.

### S1: runs and a minimal drawer

- **Delivers:** `:!cmd` and the test keys start runs. Output opens a bottom drawer at the first output, unfocused. The file keeps its window.
- **Work:**
  - `minga-run` helper (from spike A) and `Minga.Run.Transport`, built from the agent shell tool's process-group and bounded-output code.
  - `Minga.Run` (pure record, tagged states, transitions with table tests), `Minga.Run.Worker` per run, `Minga.Run.Log` per project root. `:run_changed` replaces `:command_done`.
  - `Minga.Buffer.Blocks`: block ranges committed in the same call as the text.
  - `*run*` as a buffer: header row decorations, folds, colour spans, caps with head and tail, the dropped-lines marker as a virtual row.
  - The run drawer as a drawer kind, laid out in rows inside the grid (ADR-0011). Minimal reveal: you started it, Normal mode, no prompt open, slot free, 8 rows kept.
  - Keys in the focused buffer: `q`, `esc`, `x`, `r`, `]]`, `[[`, `za`. `SPC c o`. Links with `↩`, `go` and ⌘-click through the generic `path:line` matcher. `SPC m t o` becomes an alias.
  - `:{range}!cmd` as a filter and `:r !cmd` as an insert.
  - Delete `Minga.CommandOutput`; fix the "Building Minga" notification copy by removing those notifications.
- **Done when:**
  - `:!seq 1 3000` shows its output in the drawer with the file still focused, on both frontends.
  - `:!sleep 300` then `x` ends the OS process group; the block reads "Stopped".
  - `:!yes` for ten seconds leaves the Editor responsive and the buffer at its cap.
  - A second `:!` of a different command runs beside the first; a rerun of the same command replaces it.
  - `:'<,'>!sort` sorts the selection in one undo step and opens no drawer.
  - Quitting stops running runs, and the quit prompt lists them.

### S2: the segment and the run keys

- **Delivers:** the modeline shows what is running and what failed. `SPC c c`, `SPC c C`, `SPC p c`, `SPC c s`, `SPC ~`, `SPC w p`.
- **Work:** the run segment (quantized summary, update rate, drop order, hover); the Run prompt drawer with history and the project default; the Running list for stop; `SPC ~` for the last drawer; a first act menu with Stop, Rerun and the copy rows; tsv rows for every new key; `docs/design/keys.md`, `surfaces.md` and `docs/AGENTIC-KEYMAP.md` in the same pull request; the site copy if it names these keys.
- **Done when:** `SPC c c ↩` reruns the last run and never a `:!`; `SPC c C` after `:!git status` reruns the tests, not `git status`; the segment changes at most once a minute while a run is working; `SPC ~` hides and shows the drawer without moving focus; the key grammar test passes with no baseline rows added.

### S3: errors and the quickfix core

- **Delivers:** `]q` and `[q` from any window, the `:c*` commands, entry marks, the error stepper, watch cycles, progress.
- **Work:** `Minga.Run.Matcher` and its registry with built-ins for the languages that have test runners; extending the existing `MingaEditor.Quickfix` (`lib/minga_editor/quickfix.ex`; `]q` / `[q` are already bound) with runs as a source, a list stack and the missing `:c*` commands; entry anchoring through buffer change deltas; which run takes the list (seen, superseded, unvisited entries); the `→` and severity marks in the sign column.
- **Done when:** a failing `mix test` then `]q` lands on the assertion line with the drawer cursor following; typing ten lines above an error and pressing `]q` still lands on it; a passing rerun leaves `]q` saying "No errors"; `npm test` in watch mode replaces its list each cycle; the loop "run, first error, fix, rerun, green" is 8 keys.

### S4: the reveal

- **Delivers:** `:run_drawer_for_checks` with `on_failure` as the default.
- **Work:** the pending reveal with its settle and expiry; the frontend's facts (gesture in progress, pointer enter and leave on the drawer, scrolled away) as protocol messages; opened-by, touched and seen; self-close; no-flap; resize rules.
- **Done when:** a check that fails while you type in Insert mode does not move the layout; the same failure in idle Normal mode opens the drawer within half a second without moving the cursor row; the rerun passing closes it; a drawer you clicked stays; a check started by a save hook never opens it.

### S5: Minga's commands

**Owner agreed (2026-11-28):** `Minga.Run` owns agent command execution, and agent commands use the PTY by default with a pipe for stdout as a per-command fallback. First step of this slice: run the agent's most common commands both ways and compare what the model receives, including the untested pipe-with-controlling-terminal case. The agent's Session keeps the approval decision and the run buffer only shows it, and command-block actions are one act-menu target with a run source (S2) and a terminal source (#4061).

- **Delivers:** the agent's shell commands are runs in the same buffer, with the minga strand, the word "Minga", and approvals as pending blocks. `SPC a w`.
- **Work:** `MingaAgent.Tools.Shell` becomes a client of `Minga.Run` (colour stripped from what the model reads); approval routing from the Editor to the agent; the ⌘. order; the ADR-0008 amendment; delete `minga-shell-output-reader` and the hook runner's shell mode.
- **Done when:** an agent run and your run appear as blocks with different strands; your keys cannot stop Minga's run; an approval answered in the drawer and one answered in the conversation agree; the agent's reading of `mix test`, `git diff`, `rg` and `ls` is compared with today's pipe, and each difference is either covered by the tool's description or removed by the pipe option. Spike A already shows `rg` and `ls` differ.

### S6: the rest

- **Delivers:** the switcher's "Runs" section, which-key sections, the full act menu, Fix with Minga, Copy as report.
- **Done when:** every row of the navigation map in the design has a working key and a working click.

## Documents to change, and when

| Document | Change | With |
|---|---|---|
| `docs/design/terminal.md`, ADR-0008 | Done on acceptance (2026-11-28): `*minga-shell*` withdrawn. Still to do: the terminal reuses the run helper's PTY code and the block value | S5 |
| `docs/design/keys.md`, `docs/AGENTIC-KEYMAP.md`, `doom_conventions.tsv` | The run keys and a "Run buffer" table | S1 and S2 |
| `docs/design/surfaces.md` | The run segment in the modeline order; switcher and which-key sections | S2, S6 |
| `docs/design/marks.md`, `themes.md`, `anatomy.md` | Strand in a block buffer, entry marks, Working takes its author's role, in-buffer button height | S1 |
| `docs/design/scenarios.toml` and boards | Scenarios for each drawn frame, through the board generator | The slice that builds each |
| ADR-0006 | A tenth modeline segment | S2 |

## Open questions from the post-merge review

Carried from the review of #4384. None is settled.

- **⌘. order.** The design gives ⌘. three targets in order. Key-grammar rule 5 allows a platform key only as an alias of one binding without a modifier.
- **`x` and ⌘. on a block Minga ran.** The design says your keys never stop Minga's run; say what the key does instead on such a block.
- **Approval keys.** The design's act-menu text lists `y` and `n` only. The existing approval target has `y` once, `a` this session, `t` this turn, `n` deny, and `esc` defers. Use that set.
- **Row ceiling.** Running runs are never evicted, so seven running runs at their caps exceed the resident store's 65,536 rows.
- **Window label row. Settled 2026-11-28:** ADR-0009 decision 5 is amended, and a drawer with its own header has no label and does not count as a second buffer window. The earlier question was: ADR-0009 gives a buffer drawer a label while labels are showing. The drawer's minimum and the Room test do not count that row, and nothing says whether a drawer plus one file counts as two buffer windows.
- **Where block state is drawn.** `terminal.md` uses a gutter column; the runs design uses the header row. Settle before #4061 starts.
- **`SPC ~`** against "closing a drawer returns to the one it replaced" in `surfaces.md`.

## Open questions from the review of the accepted ADRs

Four independent reviews on 2026-11-28. What they settled is in ADR-0010 ("Owner and failure", "Security rules", "Conditions on decision 6") and ADR-0009 decision 5. These remain open.

- **Follow** beyond appends: see the open note in `runs.md` section 7. Before S1.
- **Author without colour.** In the terminal frontend the strand has no stated form, and the word "Minga" comes after the command, where a long command clips it. Before S5: put the author before the command and pair the colour with a shape.
- **Header counts and steppers** mix your runs with Minga's. Before S5: count yours, show Minga's separately, and say whether `]]` crosses authors.
- **`SPC a w` and a pending approval.** It scrolls to Minga's newest block, which can be past an older pending approval. Before S5.
- **Retention of Minga's blocks.** Five finished blocks per author drops most of what an agent did. Before S5.
- **Row fit of the 24 pt header.** Where the leftover points go when the header rounds up to two rows, the drawer's width under a vertical split, and a worked 80 by 24 example. Before S1.
- **`x` stops with no confirmation,** including on a long run. Before S2.
- **Mouse paths** missing for resize by keyboard, open-at-file in the terminal frontend, and the stop list. Before S2.

## Not verified

- `SPC w p` and `]q` in Doom. The other Doom meanings were read from Doom's own bindings file.
- The frames were rendered from hand-drawn HTML, not from Minga.
- The Go frontend's single modeline was inferred from the shared layout module, not read from its source.
